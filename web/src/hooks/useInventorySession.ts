import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { DEFAULT_UI_CONFIG, type ResolvedUiConfig } from "@/context"
import type { ActiveItemBox } from "@/components/ItemBoxStack"
import { sanitizeHotbarQuick, type HotbarState } from "@/components/HotbarHud"
import type { MenuTarget } from "@/components/ItemContextMenu"
import { closeSession, pinQuickSlot, sendIntent } from "@/lib/nui"
import { applyPatch, findInventory, findItem, type DragSlot, type Selection, type SlotTarget } from "@/lib/inventory"
import { isLayoutId } from "@/lib/layoutIds"
import type { HotbarQuickEntry, InventoryItem, InventoryView, ItemBoxReceipt, QuickSlotsMessage, SessionPatch, SessionSnapshot, UiConfig } from "@/lib/types"
import { useNuiEvent } from "@/lib/useNuiEvent"
import { predictBuy, predictMove, refreshedInventories, restoreInventories, type Prediction } from "@/lib/optimistic"
import { createIntentResults } from "@/lib/intentResults"
import { createMoveQueue, isNoopMove, type MoveJob, type MoveQueue } from "@/lib/moveQueue"
import { useLocale } from "@/lib/locales"
import { modifierDragAmount } from "@/lib/modifierDrag"
import { pickTransferSlot } from "@/lib/quickTransfer"
import { copyText, itemCopyText } from "@/lib/clipboard"
import { clampGiveAmount } from "@/lib/giveAmount"
import { findCombination, mergeCombine, type CombineRecipe } from "@/lib/combine"
import { canOpenBag, openBagPayload } from "@/lib/search"
import { isAmmoCompatible, mergeAmmoInfo, resolveRightClick } from "@/lib/ammo"
import { mergeDecayConfig } from "@/lib/decay"
import { EMPTY_QUICK_SLOTS, normalizeQuickSlots, type QuickSlotsState } from "@/lib/quickSlots"
import type { SlotUi } from "@/slotUi"

// Drags that may wait behind an unanswered request before further ones are refused.
const MAX_QUEUED_MOVES = 8

/** Only booleans are taken from the pushed `layouts` table; the rest keeps its default. */
function mergeLayouts(current: ResolvedUiConfig["layouts"], pushed: UiConfig["layouts"]): ResolvedUiConfig["layouts"] {
    if (!pushed || typeof pushed !== "object") return current
    const next = { ...current }
    for (const [id, allowed] of Object.entries(pushed)) {
        if (isLayoutId(id) && typeof allowed === "boolean") next[id] = allowed
    }
    return next
}

function mergeWeightWarnings(current: ResolvedUiConfig["weightWarnings"], pushed: UiConfig["weightWarnings"]): ResolvedUiConfig["weightWarnings"] {
    if (!pushed || typeof pushed !== "object") return current
    const ratio = (value: unknown, fallback: number) => Number.isFinite(value) && Number(value) > 0 ? Number(value) : fallback
    return { enabled: pushed.enabled ?? current.enabled, warnAt: ratio(pushed.warnAt, current.warnAt), dangerAt: ratio(pushed.dangerAt, current.dangerAt) }
}

function mergeOrganize(current: ResolvedUiConfig["organize"], pushed: UiConfig["organize"]): ResolvedUiConfig["organize"] {
    if (!pushed || typeof pushed !== "object") return current
    return {
        enabled: typeof pushed.enabled === "boolean" ? pushed.enabled : current.enabled,
        sort: typeof pushed.sort === "boolean" ? pushed.sort : current.sort,
        stack: typeof pushed.stack === "boolean" ? pushed.stack : current.stack,
        panelSearch: typeof pushed.panelSearch === "boolean" ? pushed.panelSearch : current.panelSearch,
    }
}

function mergeTips(current: ResolvedUiConfig["tips"], pushed: UiConfig["tips"]): ResolvedUiConfig["tips"] {
    if (!pushed || typeof pushed !== "object") return current
    return {
        enabled: typeof pushed.enabled === "boolean" ? pushed.enabled : current.enabled,
        maxShows: Number.isFinite(pushed.maxShows) && Number(pushed.maxShows) >= 1 ? Math.floor(Number(pushed.maxShows)) : current.maxShows,
    }
}

/**
 * Session state, selection, the optimistic move queue and every intent the
 * window can send. Presentation (which layout renders it) lives elsewhere; this
 * hook owns what the browser knows and asks of the server.
 */
export function useInventorySession() {
    const t = useLocale()
    const [session, setSession] = useState<SessionSnapshot | null>(null)
    const [selected, setSelected] = useState<Selection | undefined>()
    const [query, setQuery] = useState("")
    const [error, setError] = useState<string>()
    const [giveAvailable, setGiveAvailable] = useState(false)
    const [movePending, setMovePending] = useState(false)
    const [itemBoxes, setItemBoxes] = useState<ActiveItemBox[]>([])
    const [selectedAmount, setSelectedAmount] = useState(1)
    const [splitTarget, setSplitTarget] = useState<Selection | undefined>()
    // A drop onto an item a recipe pairs it with, waiting for Combine / Cancel.
    const [combineTarget, setCombineTarget] = useState<{ recipe: CombineRecipe; fromSlot: number; toSlot: number; fromItem: InventoryItem; toItem: InventoryItem } | undefined>()
    const [uiConfig, setUiConfig] = useState(DEFAULT_UI_CONFIG)
    const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle")
    const [quickSlots, setQuickSlots] = useState<QuickSlotsState>(EMPTY_QUICK_SLOTS)
    // A real player slot to pulse after a quick slot click; the nonce lets the same slot flash again.
    const [flash, setFlash] = useState<SlotUi["flash"]>()
    const flashNonce = useRef(0)
    const flashTimeout = useRef<number>()
    const [menu, setMenu] = useState<MenuTarget | undefined>()
    // With instant moves the inventory never locks behind the server: a drag made
    // while a move is in flight is queued and sent when that move settles.
    const unlocked = uiConfig.optimisticMoves && uiConfig.queueMoves
    const locked = movePending && !unlocked
    const selectedMax = Math.max(1, Math.floor(selected?.item.amount ?? 1))
    const selectedCount = Math.min(Math.max(1, selectedAmount), selectedMax)
    const nextItemBoxId = useRef(1)
    const [hotbar, setHotbar] = useState<HotbarState | null>(null)
    const hotbarTimeout = useRef<number>()
    // The views the in-flight optimistic move replaced, restored if it fails.
    const optimistic = useRef<Map<string, InventoryView> | undefined>()
    // Latest session and config for requests that start later, when their turn comes.
    // Every session change goes through updateSession, which moves the ref in the
    // same tick: a queued request that starts before React has re-rendered must
    // still see the rollback or patch that just landed, not the state before it.
    const sessionRef = useRef<SessionSnapshot | null>(null)
    const updateSession = useCallback((change: (current: SessionSnapshot | null) => SessionSnapshot | null) => {
        const next = change(sessionRef.current)
        sessionRef.current = next
        setSession(next)
    }, [])
    const configRef = useRef(uiConfig)
    configRef.current = uiConfig
    const resyncing = useRef(false)
    // Verdicts the Lua bridge delivers after it has acknowledged an intent's fetch.
    const results = useRef(createIntentResults())
    const nextRequestId = useRef(1)

    // Asks the server to re-send the authoritative state. Used after a move that
    // was refused, errored or never answered, when the browser cannot know what
    // the server really did. The answer arrives as ordinary patches.
    const resync = useCallback(() => {
        const current = sessionRef.current
        if (!current || resyncing.current) return
        resyncing.current = true
        sendIntent({ sessionId: current.sessionId, token: current.token, intent: "sync", payload: {} })
            .catch(() => undefined)
            .finally(() => { resyncing.current = false })
    }, [])
    // Drags made while a request is in flight wait here and are sent in order;
    // see lib/moveQueue.ts for the settle-exactly-once guarantee.
    const queueRef = useRef<MoveQueue>()
    if (!queueRef.current) {
        queueRef.current = createMoveQueue({
            maxQueued: MAX_QUEUED_MOVES,
            onPending: (pending) => {
                setMovePending(pending)
                // Nothing in flight any more: drop the prediction bookkeeping so a settled
                // move cannot leave a stale snapshot (or a drag lock) behind.
                if (!pending) optimistic.current = undefined
            },
            onFailure: resync,
            onUnconfirmed: resync,
        })
    }
    const queue = queueRef.current
    const clearPendingMove = useCallback(() => {
        queue.reset()
        results.current.reset()
        optimistic.current = undefined
    }, [queue])

    // Merged onto the defaults rather than replacing them, so a config table
    // that omits a key keeps the shipped behaviour for it instead of dropping to
    // `undefined` and rendering as "off".
    useNuiEvent<UiConfig>("kora_inventory:nui:config", (config) => {
        if (!config || typeof config !== "object") return
        setUiConfig((current) => ({
            ...current,
            ...config,
            hotbarSlots: Number.isFinite(config.hotbarSlots) ? Number(config.hotbarSlots) : current.hotbarSlots,
            centreWhenSolo: config.centreWhenSolo ?? current.centreWhenSolo,
            showHotbar: config.showHotbar ?? current.showHotbar,
            rightClickSplit: config.rightClickSplit ?? current.rightClickSplit,
            rightClick: resolveRightClick(config, current.rightClick),
            ammoInfo: mergeAmmoInfo(current.ammoInfo, config.ammoInfo),
            optimisticMoves: config.optimisticMoves ?? current.optimisticMoves,
            queueMoves: config.queueMoves ?? current.queueMoves,
            directTransport: config.directTransport ?? current.directTransport,
            moveTimeoutMs: Number.isFinite(config.moveTimeoutMs) && Number(config.moveTimeoutMs) > 0 ? Number(config.moveTimeoutMs) : current.moveTimeoutMs,
            inspectorDecimals: Number.isFinite(config.inspectorDecimals) ? Number(config.inspectorDecimals) : current.inspectorDecimals,
            inspectorCopy: config.inspectorCopy ?? current.inspectorCopy,
            scale: Number.isFinite(config.scale) && Number(config.scale) > 0 ? Number(config.scale) : current.scale,
            images: { ...current.images, ...(config.images ?? {}) },
            layout: isLayoutId(config.layout) ? config.layout : current.layout,
            layouts: mergeLayouts(current.layouts, config.layouts),
            playerLayoutChoice: typeof config.playerLayoutChoice === "boolean" ? config.playerLayoutChoice : current.playerLayoutChoice,
            quickTransfer: config.quickTransfer ?? current.quickTransfer,
            modifierDrag: config.modifierDrag ?? current.modifierDrag,
            quickAmounts: config.quickAmounts ?? current.quickAmounts,
            filters: config.filters ?? current.filters,
            tooltips: config.tooltips ?? current.tooltips,
            weightWarnings: mergeWeightWarnings(current.weightWarnings, config.weightWarnings),
            organize: mergeOrganize(current.organize, config.organize),
            tips: mergeTips(current.tips, config.tips),
            combine: mergeCombine(current.combine, config.combine),
            decay: mergeDecayConfig(current.decay, config.decay),
        }))
    })
    useNuiEvent<{ slots?: HotbarState["slots"]; seconds?: number; bottom?: number; quick?: HotbarQuickEntry[] }>("kora_inventory:nui:hotbar", ({ slots, seconds, bottom, quick }) => {
        if (!Array.isArray(slots) || !(Number(seconds) > 0)) return
        window.clearTimeout(hotbarTimeout.current)
        setHotbar({ id: Date.now(), slots, bottom: Number.isFinite(bottom) ? Number(bottom) : undefined, quick: sanitizeHotbarQuick(quick) })
        hotbarTimeout.current = window.setTimeout(() => setHotbar(null), Number(seconds) * 1000)
    })
    useNuiEvent<QuickSlotsMessage>("kora_inventory:nui:quickSlots", (data) => setQuickSlots(normalizeQuickSlots(data)))
    useNuiEvent<{ bottom?: number }>("kora_inventory:nui:hotbarPosition", ({ bottom }) => {
        if (!Number.isFinite(bottom)) return
        setHotbar((current) => current ? { ...current, bottom: Number(bottom) } : current)
    })
    useNuiEvent<SessionSnapshot>("kora_inventory:nui:sessionOpened", (snapshot) => {
        window.clearTimeout(hotbarTimeout.current); setHotbar(null)
        clearPendingMove(); updateSession(() => snapshot); setSelected(undefined); setGiveAvailable(false); setError(undefined); setCombineTarget(undefined)
    })
    useNuiEvent<SessionPatch>("kora_inventory:nui:sessionPatched", (patch) => {
        // The server's items win over any prediction for the inventories they cover.
        if (optimistic.current) for (const id of refreshedInventories(patch)) optimistic.current.delete(id)
        queue.patched(patch.snapshot
            ? [patch.snapshot.player.id, patch.snapshot.secondary?.id ?? ""]
            : [patch.player?.id ?? "", patch.secondary?.id ?? ""])
        updateSession((current) => current && current.sessionId === patch.sessionId ? applyPatch(current, patch) : current)
        setSelected(undefined)
        setMenu(undefined)
    })
    useNuiEvent<{ sessionId: string; reason?: string }>("kora_inventory:nui:sessionClosed", ({ sessionId }) => {
        clearPendingMove()
        setCombineTarget(undefined)
        updateSession((current) => current?.sessionId === sessionId ? null : current)
    })
    useNuiEvent<{ reason?: string }>("kora_inventory:nui:rejected", ({ reason }) => {
        const message = reason ?? t("ui.action_rejected")
        // Settles the request in flight (once); with nothing in flight it is only a notice.
        if (queue.pending) queue.reject(message)
        else setError(message)
    })
    useNuiEvent<{ requestId?: number; ok?: boolean; error?: string }>("kora_inventory:nui:intentResult", ({ requestId, ok, error }) => {
        if (typeof requestId !== "number") return
        results.current.deliver(requestId, ok === true ? { ok: true } : { ok: false, error: error === "timeout" ? t("ui.inventory_timeout") : error })
    })
    useNuiEvent<{ available?: boolean }>("kora_inventory:nui:giveAvailability", ({ available }) => setGiveAvailable(available === true))
    useNuiEvent<ItemBoxReceipt>("kora_inventory:nui:itemBox", (receipt) => {
        if (!receipt || typeof receipt.name !== "string" || !Number.isFinite(receipt.amount) || receipt.amount < 1) return
        const id = nextItemBoxId.current++
        setItemBoxes((current) => [...current.slice(-3), { ...receipt, id }])
        window.setTimeout(() => setItemBoxes((current) => current.filter((box) => box.id !== id)), Math.max(750, receipt.duration ?? 2600))
    })

    // `build` runs when the request's turn comes, against the session as it is
    // then, so a queued drag never sends revisions or slots from before the moves
    // in front of it. It returns the request, or a message when it cannot run.
    type Built = { intent: Parameters<typeof sendIntent>[0]["intent"]; payload: Record<string, unknown>; awaiting?: string[]; prediction?: Prediction }
    const enqueueRequest = useCallback((build: (current: SessionSnapshot) => Built | string | undefined) => {
        const config = configRef.current
        const unlockedNow = config.optimisticMoves && config.queueMoves
        if (queue.pending && !unlockedNow) return
        const outcome = queue.enqueue((): MoveJob | undefined => {
            const current = sessionRef.current
            const built = current && build(current)
            if (!current || !built) return undefined
            if (typeof built === "string") { setError(built); return undefined }
            const { intent, payload, awaiting, prediction } = built
            const before = prediction ? new Map(prediction.before) : undefined
            optimistic.current = before
            if (prediction) {
                setSelected(undefined)
                updateSession(() => prediction.session)
            }
            return {
                send: async () => {
                    const requestId = nextRequestId.current++
                    const response = await sendIntent({ sessionId: current.sessionId, token: current.token, intent, payload, requestId })
                    // The Vite harness has no Lua authority to send a patch back. Keep
                    // it usable without weakening the runtime's authoritative lock.
                    if (import.meta.env.DEV && awaiting?.length) queue.patched(awaiting)
                    // Acknowledged only: the server's verdict follows as intentResult.
                    return response?.pending ? results.current.wait(requestId) : response
                },
                // A patch that refreshed an inventory dropped it from `before`, so
                // only what the server has not corrected since is put back.
                rollback: (message) => {
                    if (before?.size) updateSession((latest) => latest && restoreInventories(latest, before))
                    if (optimistic.current === before) optimistic.current = undefined
                    setSelected(undefined)
                    setError(message)
                },
                // Use and combine can legitimately run long (progress bar), everything else gets a deadline.
                timeoutMs: intent === "use" || intent === "combine" || intent === "openTargetContainer" ? undefined : config.moveTimeoutMs,
                // The server sends its patches before it answers, so with queued
                // moves the answer alone settles; waiting for a patch as well would
                // hold every later drag behind an inventory the server did not re-send.
                awaiting: unlockedNow ? undefined : awaiting,
            }
        })
        if (outcome === "full") setError(t("ui.too_many_moves"))
    }, [queue, t, updateSession])
    const submit = useCallback((intent: Built["intent"], payload: Record<string, unknown> = {}, awaiting?: string[]) => {
        enqueueRequest(() => ({ intent, payload, awaiting }))
    }, [enqueueRequest])
    const move = useCallback((fromId: string, fromSlot: number, toId: string, toSlot: number, requestedAmount?: number) => {
        enqueueRequest((current) => {
            const from = findInventory(current, fromId)
            const to = findInventory(current, toId)
            const item = findItem(from, fromSlot)
            if (!from || !to || !item || !Number.isFinite(item.amount) || item.amount < 1) return t("ui.item_unavailable")
            // Dropped back on its own slot: nothing to ask the server, nothing to lock.
            if (isNoopMove({ id: from.id, slot: fromSlot }, { id: to.id, slot: toSlot })) return undefined
            if (from.type === "shop") {
                if (current.player.id !== to.id) return t("ui.shop_player_only")
                const prediction = configRef.current.optimisticMoves ? predictBuy(current, { shopInventory: from.id, slot: fromSlot, amount: 1 }) : undefined
                return { intent: "buy", payload: { inventory: from.id, slot: fromSlot, amount: 1 }, // The omnipack list is sent once and never re-patched, so only the player's patch is awaited.
                awaiting: from.omnipack ? [to.id] : [from.id, to.id], prediction }
            }
            if (to.type === "shop") return t("ui.shop_read_only")
            const amount = requestedAmount ?? item.amount
            const prediction = configRef.current.optimisticMoves ? predictMove(current, { fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, amount }) : undefined
            return {
                intent: "move",
                payload: { fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, amount, revision: current.revision, secondaryRevision: current.secondaryRevision },
                awaiting: [from.id, to.id],
                prediction,
            }
        })
    }, [enqueueRequest, t])

    const canDropSlot = useCallback((source: DragSlot, target: SlotTarget) => {
        if (!source || !session || locked || isNoopMove({ id: source.inventoryId, slot: source.slot }, { id: target.inventoryId, slot: target.slot })) return false
        const sourceInventory = findInventory(session, source.inventoryId)
        const targetInventory = findInventory(session, target.inventoryId)
        if (!findItem(sourceInventory, source.slot) || !targetInventory) return false
        if (sourceInventory?.type === "shop") return targetInventory.id === session.player.id
        return targetInventory.type !== "shop"
    }, [locked, session])
    const dropSlot = useCallback((source: DragSlot, target: SlotTarget) => {
        if (!source || !session || !canDropSlot(source, target)) return
        const sourceInventory = findInventory(session, source.inventoryId)
        const targetInventory = findInventory(session, target.inventoryId)
        const sourceItem = findItem(sourceInventory, source.slot)
        const modified = configRef.current.modifierDrag && sourceItem ? modifierDragAmount(source.modifiers, sourceItem.amount) : undefined
        // Two different items in the player's own inventory that a recipe pairs:
        // ask instead of swapping. No recipe (or combining off) falls through to
        // the ordinary move/swap/stack below, exactly as before.
        if (sourceInventory && targetInventory && sourceItem && sourceInventory.id === session.player.id && targetInventory.id === session.player.id) {
            const targetItem = findItem(targetInventory, target.slot)
            const recipe = findCombination(sourceItem, targetItem, configRef.current.combine)
            if (recipe && targetItem) {
                setSelected(undefined)
                setCombineTarget({ recipe, fromSlot: source.slot, toSlot: target.slot, fromItem: sourceItem, toItem: targetItem })
                return
            }
        }
        const amount = modified ?? (selected?.inventory.id === source.inventoryId && selected.item.slot === source.slot ? selectedCount : undefined)
        if (sourceInventory && targetInventory) move(sourceInventory.id, source.slot, targetInventory.id, target.slot, amount)
    }, [canDropSlot, move, selected, selectedCount, session])

    // Combine / Cancel on the popover. Only the two slots and the revision go to
    // the server, which finds the recipe in its own registry and re-reads both
    // slots; nothing the browser knows about the recipe is sent.
    const confirmCombine = useCallback(() => {
        const pending = combineTarget
        setCombineTarget(undefined)
        if (!pending) return
        enqueueRequest((current) => {
            const player = current.player
            const from = findItem(player, pending.fromSlot)
            const to = findItem(player, pending.toSlot)
            if (!from || !to || findCombination(from, to, configRef.current.combine) === null) return t("ui.item_unavailable")
            return { intent: "combine", payload: { inventory: player.id, fromSlot: pending.fromSlot, toSlot: pending.toSlot, revision: current.revision }, awaiting: [player.id] }
        })
    }, [combineTarget, enqueueRequest, t])
    const cancelCombine = useCallback(() => setCombineTarget(undefined), [])

    useEffect(() => {
        const handleDragBuy = (event: Event) => {
            const detail = (event as CustomEvent<{item: string; accepted: boolean; error: string}>).detail
            const shop = session?.secondary
            const item = Object.values(shop?.items ?? {}).find(entry => entry?.name === detail.item)
            const target = session?.player
            if (!shop || shop.type !== "shop" || !item || !target || locked) {
                detail.error = t("ui.shop_item_unavailable")
                return
            }
            const destination = Object.values(target.items).find(entry => entry?.name === item.name)?.slot ??
                Array.from({ length: target.slots }, (_, index) => index + 1).find(slot => !Object.values(target.items).some(entry => entry?.slot === slot))
            if (!destination) { detail.error = t("ui.no_destination_slot"); return }
            const source = { inventoryId: shop.id, slot: item.slot }
            const dest = { inventoryId: target.id, slot: destination }
            if (!canDropSlot(source, dest)) { detail.error = t("ui.player_slot_rejects_shop_item"); return }
            dropSlot(source, dest)
            detail.accepted = true
        }
        window.addEventListener('fft:dragBuy', handleDragBuy)
        return () => window.removeEventListener('fft:dragBuy', handleDragBuy)
    }, [session, locked, canDropSlot, dropSlot, t])

    // A single click inspects, and only inspects. Moving is drag-only (drag onto
    // a slot to move/stack, drag outside the window to drop), so a click on an
    // empty slot can no longer fling the previous selection into it.
    const selectSlot = useCallback((inventory: InventoryView, item: InventoryItem | undefined, slot: number) => {
        if (locked) return
        setSelected((current) => {
            if (!item) return undefined
            if (current && current.inventory.id === inventory.id && current.item.slot === slot) return undefined
            return { inventory, item }
        })
    }, [locked])

    // Shift+click: the whole stack to the other open inventory. From a shop it is
    // a buy of one, exactly like dragging out of a shop; a shop is never a target.
    const quickTransfer = useCallback((inventory: InventoryView, item: InventoryItem) => {
        const current = sessionRef.current
        if (!configRef.current.quickTransfer || !current) return
        const from = findInventory(current, inventory.id)
        const stack = findItem(from, item.slot)
        if (!from || !stack) return
        const other = from.id === current.player.id ? current.secondary : current.player
        if (!other) { setError(t("ui.no_other_inventory")); return }
        if (other.type === "shop") { setError(t("ui.shop_read_only")); return }
        const slot = pickTransferSlot(other, stack)
        if (!slot) { setError(t("ui.no_room_other")); return }
        move(from.id, stack.slot, other.id, slot)
    }, [move, t])

    const dropOut = useCallback((source: DragSlot) => {
        if (source.inventoryId !== sessionRef.current?.player.id) return
        enqueueRequest((current) => {
            const item = findItem(current.player, source.slot)
            if (!item || !Number.isFinite(item.amount) || item.amount < 1) return t("ui.item_unavailable")
            setSelected(undefined)
            return { intent: "drop", payload: { inventory: source.inventoryId, slot: source.slot, amount: item.amount } }
        })
    }, [enqueueRequest, t])
    // Sort / Stack all for one panel. The server plans and commits it (same
    // validation as a move); the browser sends only which panel and which mode,
    // plus the revisions it is looking at. The refreshed inventory arrives as a patch.
    const organize = useCallback((inventory: InventoryView, mode: "sort" | "stack") => {
        const settings = configRef.current.organize
        if (!settings.enabled || !settings[mode] || inventory.type === "shop") return
        enqueueRequest((current) => {
            if (!findInventory(current, inventory.id)) return t("ui.item_unavailable")
            setSelected(undefined)
            return {
                intent: "organize",
                payload: { inventory: inventory.id, mode, revision: current.revision, secondaryRevision: current.secondaryRevision },
                awaiting: [inventory.id],
            }
        })
    }, [enqueueRequest, t])
    const split = useCallback((inventory: InventoryView, item: InventoryItem, requestedAmount?: number) => {
        if (!session || inventory.type === "shop" || item.amount < 2) return
        const amount = Math.floor(requestedAmount ?? selectedCount)
        const emptySlot = Array.from({ length: inventory.slots }, (_, index) => index + 1).find((slot) => !findItem(inventory, slot))
        if (!Number.isFinite(amount) || amount < 1 || amount >= item.amount) { setError(t("ui.choose_split_amount", { amount: item.amount - 1 })); return }
        if (!emptySlot) { setError(t("ui.no_empty_slot")); return }
        move(inventory.id, item.slot, inventory.id, emptySlot, amount)
    }, [move, selectedCount, session, t])
    // The split dialog itself, whichever gesture asked for it (right-click or the menu's Split).
    const openSplit = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.type === "shop" || item.amount < 2) return
        setSplitTarget({ inventory, item })
    }, [])
    // Right-click in `split` mode. `menu` mode never reaches this (the slot opens the menu) and `none` does nothing.
    const promptSplit = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (uiConfig.rightClick !== "split") return
        openSplit(inventory, item)
    }, [openSplit, uiConfig.rightClick])
    const confirmSplit = useCallback((amount: number) => {
        const target = splitTarget
        setSplitTarget(undefined)
        if (!target) return
        setSelected(target)
        setSelectedAmount(amount)
        split(target.inventory, target.item, amount)
    }, [split, splitTarget])
    // The dialog never outlives its session, and any server patch dismisses it
    // so it can never act on a stack that changed underneath it.
    useEffect(() => { setSplitTarget(undefined); setMenu(undefined) }, [session?.sessionId, session?.revision, session?.secondaryRevision])

    const use = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) { setError(t("ui.use_player_item_only")); return }
        void submit("use", { inventory: inventory.id, slot: item.slot })
    }, [session, submit, t])
    // Search: open a bag in the searched player's inventory. Only the inventory id
    // and slot are sent; it may wait on the searcher's progress bar, so no deadline.
    const openBag = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (!session || !canOpenBag(inventory, item, session.player.id)) return
        void submit("openTargetContainer", openBagPayload(inventory, item))
    }, [session, submit])
    const buy = useCallback((inventory: InventoryView, item: InventoryItem, amount = 1) => {
        if (inventory.type !== "shop" || !session) return
        const stock = Math.max(1, Math.floor(item.amount))
        const count = Math.min(Math.max(1, Math.floor(amount)), stock)
        enqueueRequest((current) => {
            const prediction = configRef.current.optimisticMoves ? predictBuy(current, { shopInventory: inventory.id, slot: item.slot, amount: count }) : undefined
            return { intent: "buy", payload: { inventory: inventory.id, slot: item.slot, amount: count }, awaiting: inventory.omnipack ? [current.player.id] : [inventory.id, current.player.id], prediction }
        })
    }, [enqueueRequest, session])
    // Shared by the Enter-key shortcut on a selected item and the slot
    // grid's double-click handler below -- both just trigger whatever the
    // detail panel's own primary-action button would (buy in a shop, use
    // otherwise), rather than each re-deciding it themselves.
    const activateItem = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.type === "shop") buy(inventory, item)
        else if (session && canOpenBag(inventory, item, session.player.id)) openBag(inventory, item)
        else use(inventory, item)
    }, [buy, openBag, session, use])
    const openMenu = useCallback((point: { x: number; y: number }, inventory: InventoryView, item: InventoryItem) => {
        if (locked) return
        setMenu({ ...point, inventory, item })
    }, [locked])
    const closeMenu = useCallback(() => setMenu(undefined), [])
    // Menu actions send the whole stack, like dragging it out of the window or onto a player.
    const dropItem = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) return
        submit("drop", { inventory: inventory.id, slot: item.slot, amount: item.amount })
    }, [session?.player.id, submit])
    const giveItem = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) return
        submit("give", { inventory: inventory.id, slot: item.slot, amount: clampGiveAmount(item.amount, item.amount) })
    }, [session?.player.id, submit])
    const copyItem = useCallback((inventory: InventoryView, item: InventoryItem) => { void copyText(itemCopyText(inventory, item)) }, [])
    // Quick slots: pins are a local preference answered by the Lua client; the
    // refreshed `quickSlots` message is what changes the bar.
    const pinQuick = useCallback((id: string, slot: number | null) => {
        void pinQuickSlot(id, slot).then((result) => { if (!result.ok) setError(result.error ?? t("ui.quick_slot_pin_failed")) })
    }, [t])
    const flashSlot = useCallback((slot: number) => {
        const inventoryId = sessionRef.current?.player.id
        if (!inventoryId) return
        window.clearTimeout(flashTimeout.current)
        setFlash({ inventoryId, slot, nonce: ++flashNonce.current })
        flashTimeout.current = window.setTimeout(() => setFlash(undefined), 900)
    }, [])
    useEffect(() => () => window.clearTimeout(flashTimeout.current), [])
    const activateSelected = useCallback((selection: Selection) => activateItem(selection.inventory, selection.item), [activateItem])
    const close = useCallback(() => { if (session) void closeSession(session.sessionId, session.token) }, [session])

    useEffect(() => {
        const onKey = (event: KeyboardEvent) => {
            if (event.key === "Escape" && splitTarget) { setSplitTarget(undefined); return }
            if (event.key === "Escape" && combineTarget) { setCombineTarget(undefined); return }
            if (event.key === "Escape" && menu) return
            if (event.key === "Escape" || event.key === "Tab") close()
            if (event.key === "Enter" && selected && !locked && !movePending && !combineTarget) activateSelected(selected)
        }
        window.addEventListener("keydown", onKey)
        return () => window.removeEventListener("keydown", onKey)
    }, [activateSelected, close, combineTarget, locked, menu, movePending, selected, splitTarget])

    // A refusal notice is information, not a state: let it go once it has been read.
    useEffect(() => {
        if (!error) return
        const timer = window.setTimeout(() => setError(undefined), 6000)
        return () => window.clearTimeout(timer)
    }, [error])

    // Read by styles.css for text and slot sizes; 1 leaves every size as authored.
    useEffect(() => { document.documentElement.style.setProperty("--ui-scale", String(uiConfig.scale)) }, [uiConfig.scale])
    // Config.Slots.borderWidth (client/ui.lua pushes slotBorderWidth). This was
    // in the served web/build but missing from web/src; restored here so a
    // rebuild from source keeps the configured slot border.
    useEffect(() => { document.documentElement.style.setProperty("--slot-border-width", `${typeof (uiConfig as UiConfig).slotBorderWidth === "number" ? (uiConfig as UiConfig).slotBorderWidth : 1}px`) }, [(uiConfig as UiConfig).slotBorderWidth])

    const solo = Boolean(session && uiConfig.centreWhenSolo && !session.secondary)
    // Search belongs to the three-column transfer view. It is intentionally
    // hidden in compact solo mode, so a query left over from another session
    // must never hide the newly selected drawer contents.
    const inspected = useMemo(() => selected && (solo || (selected.item.label ?? selected.item.name).toLowerCase().includes(query.toLowerCase())) ? selected : undefined, [query, selected, solo])
    // A fresh selection always starts at one, so a large slider value can never
    // carry over onto a different stack or shop stock row.
    useEffect(() => { setSelectedAmount(1) }, [selected?.inventory.id, selected?.item.slot])
    // Inspector "Copy" (Config.Inspector.allowCopy): the button shows the result
    // briefly, and a new selection starts from the plain label again.
    useEffect(() => { setCopyState("idle") }, [selected?.inventory.id, selected?.item.slot])
    useEffect(() => {
        if (copyState === "idle") return
        const timer = window.setTimeout(() => setCopyState("idle"), 1500)
        return () => window.clearTimeout(timer)
    }, [copyState])
    const copySelected = useCallback(async (selection: Selection) => {
        setCopyState(await copyText(itemCopyText(selection.inventory, selection.item)) ? "copied" : "failed")
    }, [])

    // What every slot needs beyond its own props: the flash, the weapon/ammo ring for the selection, the menu.
    const slotUi = useMemo<SlotUi>(() => {
        const wanted = uiConfig.ammoInfo.enabled ? selected?.item : undefined
        return {
            flash,
            isCompatible: (item) => Boolean(wanted && item && isAmmoCompatible(wanted, item)),
            openMenu: uiConfig.rightClick === "menu" ? openMenu : undefined,
        }
    }, [flash, openMenu, selected, uiConfig.ammoInfo.enabled, uiConfig.rightClick])

    return {
        slotUi, quickSlots, pinQuick, flashSlot, menu, closeMenu, dropItem, giveItem, copyItem, openSplit,
        session, uiConfig, selected, inspected, solo, locked, movePending, error, giveAvailable,
        query, setQuery, itemBoxes, hotbar,
        selectedMax, selectedCount, setSelectedAmount, copyState, copySelected,
        splitTarget, confirmSplit, cancelSplit: () => setSplitTarget(undefined),
        combineTarget, confirmCombine, cancelCombine,
        canDropSlot, dropSlot, dropOut, organize, quickTransfer, selectSlot, promptSplit, activateItem,
        split, use, openBag, buy, submit, close, clearSelection: () => setSelected(undefined),
    }
}
