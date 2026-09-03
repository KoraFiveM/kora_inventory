import { CircleAlert, PackageOpen, Search, X } from "lucide-react"
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react"
import { DndProvider, useDrag, useDragLayer, useDrop } from "react-dnd"
import { TouchBackend } from "react-dnd-touch-backend"
import { closeSession, sendIntent } from "@/lib/nui"
import { openDevHarness } from "@/lib/dev"
import type { InventoryItem, InventoryView, ItemBoxReceipt, SessionPatch, SessionSnapshot, ThemeTokens, UiConfig } from "@/lib/types"
import { useNuiEvent } from "@/lib/useNuiEvent"

const SLOT_DRAG_TYPE = "qbinventory/slot"

/**
 * Presentation config from `Config.qbinventory.ui`, pushed on
 * `qbinventory:nui:config`.
 *
 * The defaults here are what renders in the window between the UI mounting and
 * that message arriving (and in the dev harness, which sends no config at all),
 * so they mirror the shipped config rather than being "off".
 */
const DEFAULT_UI_CONFIG: Required<Pick<UiConfig, "hotbarSlots" | "centreWhenSolo" | "showHotbar">> & { images: NonNullable<UiConfig["images"]> } = {
    hotbarSlots: 5,
    centreWhenSolo: true,
    showHotbar: true,
    images: {
        localPath: "nui://qbinventory/images",
        extensions: ["webp", "png", "gif", "jpg"],
        preferLocal: false,
        allowRemote: true,
    },
}

const UiConfigContext = createContext(DEFAULT_UI_CONFIG)

interface DragSlot { inventoryId: string; slot: number }
interface SlotTarget { inventoryId: string; slot: number }
interface Selection { inventory: InventoryView; item: InventoryItem }

function asSlots(items: InventoryView["items"]): InventoryItem[] {
    // FiveM JSON serialises a sparse Lua slot table as an array with `null`
    // holes (e.g. item in slot 1, nothing in slots 2-4, item in slot 5).
    // Never let an empty slot enter a render/map pass that reads `.slot`.
    const values = Array.isArray(items) ? items : Object.values(items ?? {})
    return values.filter((item): item is InventoryItem =>
        item !== null && typeof item === "object" && Number.isInteger(item.slot) && item.slot > 0,
    )
}

function mergeInventory(current: InventoryView | undefined, patch: Partial<InventoryView> | null | undefined) {
    if (patch === null) return undefined
    if (patch === undefined) return current
    if (!current) return patch as InventoryView | undefined
    return { ...current, ...patch, items: patch.items ?? current.items }
}

function applyPatch(current: SessionSnapshot, patch: SessionPatch): SessionSnapshot {
    if (patch.snapshot) return patch.snapshot
    return {
        ...current,
        revision: patch.revision ?? current.revision,
        secondaryRevision: patch.secondaryRevision ?? current.secondaryRevision,
        player: mergeInventory(current.player, patch.player) ?? current.player,
        secondary: mergeInventory(current.secondary, patch.secondary),
    }
}

function findInventory(session: SessionSnapshot, id: string) {
    if (session.player.id === id) return session.player
    if (session.secondary?.id === id) return session.secondary
}

function findItem(inventory: InventoryView | undefined, slot: number) {
    return inventory && asSlots(inventory.items).find((item) => item.slot === slot)
}

/**
 * Item name -> a safe `nui://` URL, or undefined.
 *
 * Item records reach the browser from shared item definitions any resource can
 * extend, so a name is untrusted text on the way into an `src`. Anything but a
 * plain identifier is rejected outright rather than escaped -- item names are
 * already constrained to that shape, so there is nothing legitimate to lose.
 */
function localImageUrl(base: string | undefined, name: string, extension: string) {
    if (!base) return undefined
    if (!/^[a-z0-9_-]+$/i.test(name)) return undefined
    if (!/^[a-z0-9]+$/i.test(extension)) return undefined
    return `${base.replace(/\/+$/, "")}/${name}.${extension}`
}

/**
 * Every URL worth trying for one item's artwork, best first.
 *
 * Ordered rather than probed: there is no way to ask whether a `nui://` file
 * exists without requesting it, and an `<img onError>` chain gets that for free
 * with no HEAD requests and no manifest to keep in sync.
 */
function artworkCandidates(item: Pick<InventoryItem, "name" | "label" | "image" | "imageUrl">, images: NonNullable<UiConfig["images"]>) {
    const out: string[] = []

    // Only https:// remote artwork. The scheme allowlist is the point: an item
    // definition is data from another resource, and a `javascript:` or `data:`
    // value in `imageUrl` must never reach an `src`.
    const remote = images.allowRemote !== false && item.imageUrl?.startsWith("https://") ? item.imageUrl : undefined

    if (remote && !images.preferLocal) out.push(remote)

    // qbcore's legacy `image` field is a bare filename ('water_bottle.png'),
    // which is the one case where the extension is already chosen for us.
    const named = typeof item.image === "string" ? item.image.replace(/\.[a-z0-9]+$/i, "") : undefined
    const explicit = typeof item.image === "string" ? /\.([a-z0-9]+)$/i.exec(item.image)?.[1] : undefined
    if (named && explicit) {
        const url = localImageUrl(images.localPath, named, explicit)
        if (url) out.push(url)
    }

    for (const extension of images.extensions ?? []) {
        const url = localImageUrl(images.localPath, item.name, extension)
        if (url && !out.includes(url)) out.push(url)
    }

    if (remote && images.preferLocal) out.push(remote)

    return out
}

function ItemArtwork({ item, className }: { item: Pick<InventoryItem, "name" | "label" | "image" | "imageUrl">; className: string }) {
    const { images } = useContext(UiConfigContext)
    const candidates = useMemo(() => artworkCandidates(item, images), [item.name, item.image, item.imageUrl, images])
    const [attempt, setAttempt] = useState(0)

    // A different item in the same slot is a different candidate list, so the
    // attempt counter has to go back to the start or the new item inherits the
    // old one's failures and shows the letter placeholder.
    useEffect(() => { setAttempt(0) }, [candidates])

    const source = candidates[attempt]

    return <span className={className}>{source
        ? <img key={source} src={source} alt="" onError={() => setAttempt((current) => current + 1)} />
        : (item.label ?? item.name).slice(0, 1)}</span>
}

interface SlotProps {
    item?: InventoryItem
    index: number
    inventory: InventoryView
    selected: boolean
    busy: boolean
    canDropSlot: (source: DragSlot, target: SlotTarget) => boolean
    onDrop: (source: DragSlot, target: SlotTarget) => void
    onDragEnd: () => void
    onSelect: (item?: InventoryItem) => void
    onActivate: (item: InventoryItem) => void
    /** Part of the hotbar range, so it carries the accent outline. */
    hotbar?: boolean
    /** The last slot of that range, which closes the outline on the right. */
    lastHotbar?: boolean
}

/** React DnD's TouchBackend uses global CEF input listeners for both touch and
 * mouse. Unlike HTML5 DnD or source pointer-capture, it resolves the actual
 * destination slot after the cursor leaves the source element. */
function InventorySlot({ item, index, inventory, selected, busy, hotbar, lastHotbar, canDropSlot, onDrop, onDragEnd, onSelect, onActivate }: SlotProps) {
    const target = useMemo<SlotTarget>(() => ({ inventoryId: inventory.id, slot: index }), [index, inventory.id])
    const suppressClick = useRef(false)
    const [{ isDragging }, dragRef] = useDrag<DragSlot, SlotTarget, { isDragging: boolean }>(() => ({
        type: SLOT_DRAG_TYPE,
        item: { inventoryId: inventory.id, slot: index },
        canDrag: Boolean(item) && !busy,
        end: () => {
            // CEF emits a click after mouse-up. A drag must not become a
            // second select/move action once the backend has ended it.
            suppressClick.current = true
            onDragEnd()
        },
        collect: (monitor) => ({ isDragging: monitor.isDragging() }),
    }), [busy, index, inventory.id, item, onDragEnd])
    const [{ isOver, canDrop }, dropRef] = useDrop<DragSlot, SlotTarget, { isOver: boolean; canDrop: boolean }>(() => ({
        accept: SLOT_DRAG_TYPE,
        canDrop: (source) => Boolean(source) && !busy && canDropSlot(source, target),
        drop: (source) => {
            if (!source) return undefined
            onDrop(source, target)
            return target
        },
        collect: (monitor) => ({ isOver: monitor.isOver({ shallow: true }), canDrop: monitor.canDrop() }),
    }), [busy, canDropSlot, onDrop, target])
    const setSlotRef = useCallback((node: HTMLButtonElement | null) => {
        dragRef(node)
        dropRef(node)
    }, [dragRef, dropRef])
    const classes = [
        "slot", item && "slot-filled", selected && "slot-selected", isDragging && "slot-drag-source",
        // A shop slot puts a price where the label would otherwise end, so the
        // label reserves that room only where a price is actually rendered.
        inventory.type === "shop" && "slot-priced",
        // Accent outline on the hotbar range. `hotbar` is decided by the panel,
        // not here: the range only means anything on the player's own
        // inventory, and a stash's first five slots are not bound to anything.
        hotbar && "slot-hotbar",
        hotbar && index === 1 && "slot-hotbar-first",
        hotbar && lastHotbar && "slot-hotbar-last",
        isOver && canDrop && "slot-move-target", isOver && !canDrop && "slot-drop-invalid",
    ].filter(Boolean).join(" ")

    return <button
        ref={setSlotRef}
        className={classes}
        aria-label={item ? `${item.label ?? item.name}, slot ${index}` : `Empty slot ${index}`}
        aria-pressed={selected || undefined}
        aria-disabled={busy || undefined}
        onClick={() => {
            if (suppressClick.current) { suppressClick.current = false; return }
            if (!busy) onSelect(item)
        }}
        onDoubleClick={() => {
            // Same use-item action as the detail panel's Use/Buy button and
            // the Enter-key shortcut on a selected item -- see activateItem.
            if (!busy && item) onActivate(item)
        }}
        onKeyDown={(event) => {
            if (event.key !== "Enter" && event.key !== " ") return
            event.preventDefault()
            if (!busy) onSelect(item)
        }}
    >
        <span className="slot-number">{index}</span>
        {item && <>
            <ItemArtwork item={item} className="item-art" />
            <span className="item-label">{item.label ?? item.name}</span>
            <span className="item-amount">×{item.amount}</span>
            {inventory.type === "shop" && typeof item.price === "number" && <span className="item-price">${item.price.toLocaleString()}</span>}
            {typeof item.durability === "number" && <span className="durability"><i style={{ width: `${Math.max(0, Math.min(100, item.durability))}%` }} /></span>}
        </>}
    </button>
}

function InventoryPanel({ inventory, selected, busy, isPlayer, canDropSlot, onDrop, onDragEnd, onSelect, onActivate }: {
    inventory: InventoryView
    selected?: Selection
    busy: boolean
    canDropSlot: (source: DragSlot, target: SlotTarget) => boolean
    onDrop: (source: DragSlot, target: SlotTarget) => void
    onDragEnd: () => void
    onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void
    onActivate: (inventory: InventoryView, item: InventoryItem) => void
    /** True for the player's own inventory -- the only one with a hotbar. */
    isPlayer?: boolean
}) {
    const { hotbarSlots, showHotbar } = useContext(UiConfigContext)
    const items = asSlots(inventory.items)
    const bySlot = new Map(items.map((item) => [item.slot, item]))
    const percentage = inventory.maxWeight ? Math.min(100, Math.round(((inventory.weight ?? 0) / inventory.maxWeight) * 100)) : 0

    // Only the player's own inventory has a hotbar. The number keys act on the
    // player's slots 1-5 wherever the cursor is, so outlining a stash's or a
    // shop's first five slots would advertise a binding that does not exist
    // there.
    const hotbarCount = showHotbar && isPlayer ? Math.max(0, Math.min(hotbarSlots ?? 0, inventory.slots)) : 0

    return <section className="inventory-panel" aria-label={inventory.label ?? inventory.id} aria-busy={busy || undefined}>
        <header className="panel-header">
            <div><p className="eyebrow">{inventory.type ?? "inventory"}</p><h2>{inventory.label ?? inventory.id}</h2></div>
            <div className="weight"><span>{(inventory.weight ?? 0).toLocaleString()} / {(inventory.maxWeight ?? 0).toLocaleString()} g</span><i><b style={{ width: `${percentage}%` }} /></i></div>
        </header>
        <div className="slot-grid">
            {Array.from({ length: inventory.slots }, (_, offset) => {
                const slot = offset + 1
                const item = bySlot.get(slot)
                return <InventorySlot key={slot} index={slot} inventory={inventory} item={item} selected={selected?.inventory.id === inventory.id && selected.item.slot === slot} busy={busy} hotbar={slot <= hotbarCount} lastHotbar={slot === hotbarCount} canDropSlot={canDropSlot} onDrop={onDrop} onDragEnd={onDragEnd} onSelect={(slotItem) => onSelect(inventory, slotItem, slot)} onActivate={(slotItem) => onActivate(inventory, slotItem)} />
            })}
        </div>
    </section>
}

function DragPreview({ session }: { session: SessionSnapshot | null }) {
    const { isDragging, item, clientOffset } = useDragLayer((monitor) => ({
        isDragging: monitor.isDragging(),
        item: monitor.getItem<DragSlot>(),
        clientOffset: monitor.getClientOffset(),
    }))
    if (!isDragging || !item || !clientOffset || !session) return null
    const source = findInventory(session, item.inventoryId)
    const draggedItem = findItem(source, item.slot)
    if (!source || !draggedItem) return null
    // Positioned exactly on the cursor. The centring is done in CSS
    // (`translate(-50%, -50%)` on the element) rather than by subtracting half
    // the size here, because the preview's width is a `min()` of the viewport
    // and is not known to JS. The old fixed `+14, +14` nudge put the preview
    // below and right of the pointer, which reads as lag on the way to a slot
    // and makes it unclear which slot is actually being targeted.
    return <div className="inventory-drag-preview" style={{ transform: `translate3d(${clientOffset.x}px, ${clientOffset.y}px, 0)` }} aria-hidden="true">
        <ItemArtwork item={draggedItem} className="drag-preview-art" />
        <span>{draggedItem.label ?? draggedItem.name}</span>
        <b>×{draggedItem.amount}</b>
    </div>
}

interface ActiveItemBox extends ItemBoxReceipt { id: number }

const ITEM_BOX_ACTIONS = {
    add: { eyebrow: "Received", sign: "+", tone: "gain" },
    purchase: { eyebrow: "Purchased", sign: "+", tone: "gain" },
    remove: { eyebrow: "Removed", sign: "−", tone: "loss" },
    use: { eyebrow: "Used", sign: "−", tone: "loss" },
} as const

function ItemBoxStack({ boxes }: { boxes: ActiveItemBox[] }) {
    if (!boxes.length) return null
    return <aside className="item-box-stack" aria-live="polite" aria-label="Item receipts">
        {boxes.map((box) => {
            // A receipt for an action this build does not know about still
            // reads correctly as an unsigned change rather than a false gain.
            const action = ITEM_BOX_ACTIONS[box.action] ?? { eyebrow: "Updated", sign: "", tone: "neutral" }
            return <div className={`item-box item-box-${action.tone}`} key={box.id}>
                <ItemArtwork item={box} className="item-box-art" />
                <div><p>{action.eyebrow}</p><strong>{box.label ?? box.name}</strong></div>
                <b>{action.sign}×{box.amount}</b>
            </div>
        })}
    </aside>
}

/** Dragging a stack out of the window drops it in the world. The zone is only
 * mounted while a drag is running, so it never captures a click, and it sits
 * behind the shell (z-index) so a slot under the cursor always wins the drop.
 * `didDrop()` is belt-and-braces for the same reason. */
function WorldDropZone({ session, busy, onDropOut }: { session: SessionSnapshot; busy: boolean; onDropOut: (source: DragSlot) => void }) {
    const dragging = useDragLayer((monitor) => monitor.isDragging())
    const [{ isOver, canDrop }, dropRef] = useDrop<DragSlot, undefined, { isOver: boolean; canDrop: boolean }>(() => ({
        accept: SLOT_DRAG_TYPE,
        // Only the player's own items can hit the floor. A stash, container or
        // shop slot dragged out is a no-op, matching the server's drop intent.
        canDrop: (source) => Boolean(source) && !busy && source.inventoryId === session.player.id,
        drop: (source, monitor) => {
            if (source && !monitor.didDrop()) onDropOut(source)
            return undefined
        },
        collect: (monitor) => ({ isOver: monitor.isOver({ shallow: true }), canDrop: monitor.canDrop() }),
    }), [busy, onDropOut, session.player.id])
    if (!dragging) return null
    const armed = isOver && canDrop
    return <>
        <div ref={dropRef} className={`world-drop-zone${armed ? " world-drop-zone-armed" : ""}`} aria-hidden="true" />
        <p className={`world-drop-hint${armed ? " world-drop-hint-armed" : ""}`} role="status">{canDrop ? (armed ? "Release to drop on the ground" : "Drag outside the window to drop") : busy ? "Updating inventory…" : "This item cannot be dropped"}</p>
    </>
}

function InventoryApp() {
    const [session, setSession] = useState<SessionSnapshot | null>(null)
    const [selected, setSelected] = useState<Selection | undefined>()
    const [query, setQuery] = useState("")
    const [error, setError] = useState<string>()
    const [giveAvailable, setGiveAvailable] = useState(false)
    const [movePending, setMovePending] = useState(false)
    const [itemBoxes, setItemBoxes] = useState<ActiveItemBox[]>([])
    const [dropAmount, setDropAmount] = useState(1)
    const [uiConfig, setUiConfig] = useState(DEFAULT_UI_CONFIG)
    const pendingInventories = useRef<Set<string> | undefined>()
    const requestPending = useRef(false)
    const nextItemBoxId = useRef(1)

    const clearPendingMove = useCallback(() => {
        pendingInventories.current = undefined
        requestPending.current = false
        setMovePending(false)
    }, [])
    const settlePatchedInventories = useCallback((patch: SessionPatch) => {
        const pending = pendingInventories.current
        if (!pending) return
        const changed = patch.snapshot
            ? [patch.snapshot.player.id, patch.snapshot.secondary?.id]
            : [patch.player?.id, patch.secondary?.id]
        for (const id of changed) if (id) pending.delete(id)
        if (pending.size === 0) clearPendingMove()
    }, [clearPendingMove])

    // Merged onto the defaults rather than replacing them, so a config table
    // that omits a key keeps the shipped behaviour for it instead of dropping to
    // `undefined` and rendering as "off".
    useNuiEvent<UiConfig>("qbinventory:nui:config", (config) => {
        if (!config || typeof config !== "object") return
        setUiConfig((current) => ({
            ...current,
            ...config,
            hotbarSlots: Number.isFinite(config.hotbarSlots) ? Number(config.hotbarSlots) : current.hotbarSlots,
            centreWhenSolo: config.centreWhenSolo ?? current.centreWhenSolo,
            showHotbar: config.showHotbar ?? current.showHotbar,
            images: { ...current.images, ...(config.images ?? {}) },
        }))
    })
    useNuiEvent<ThemeTokens>("qbinventory:nui:theme", (tokens) => {
        for (const [key, value] of Object.entries(tokens ?? {})) document.documentElement.style.setProperty(`--${key}`, value)
    })
    useNuiEvent<SessionSnapshot>("qbinventory:nui:sessionOpened", (snapshot) => {
        clearPendingMove(); setSession(snapshot); setSelected(undefined); setGiveAvailable(false); setError(undefined)
    })
    useNuiEvent<SessionPatch>("qbinventory:nui:sessionPatched", (patch) => {
        settlePatchedInventories(patch)
        setSession((current) => current && current.sessionId === patch.sessionId ? applyPatch(current, patch) : current)
        setSelected(undefined)
    })
    useNuiEvent<{ sessionId: string; reason?: string }>("qbinventory:nui:sessionClosed", ({ sessionId }) => {
        clearPendingMove()
        setSession((current) => current?.sessionId === sessionId ? null : current)
    })
    useNuiEvent<{ reason?: string }>("qbinventory:nui:rejected", ({ reason }) => {
        clearPendingMove()
        setError(reason ?? "Action rejected by inventory")
    })
    useNuiEvent<{ available?: boolean }>("qbinventory:nui:giveAvailability", ({ available }) => setGiveAvailable(available === true))
    useNuiEvent<ItemBoxReceipt>("qbinventory:nui:itemBox", (receipt) => {
        if (!receipt || typeof receipt.name !== "string" || !Number.isFinite(receipt.amount) || receipt.amount < 1) return
        const id = nextItemBoxId.current++
        setItemBoxes((current) => [...current.slice(-3), { ...receipt, id }])
        window.setTimeout(() => setItemBoxes((current) => current.filter((box) => box.id !== id)), Math.max(750, receipt.duration ?? 2600))
    })

    const submit = useCallback(async (intent: Parameters<typeof sendIntent>[0]["intent"], payload: Record<string, unknown> = {}, awaitInventories?: string[]) => {
        if (!session || requestPending.current) return false
        requestPending.current = true
        setMovePending(true)
        if (awaitInventories?.length) {
            pendingInventories.current = new Set(awaitInventories)
        }
        try {
            const response = await sendIntent({ sessionId: session.sessionId, token: session.token, intent, payload })
            if (!response.ok) {
                clearPendingMove()
                setError(response.error ?? "Action rejected by inventory")
                return false
            }
            // The Vite harness has no Lua authority to send a patch back. Keep
            // it usable without weakening the runtime's authoritative lock.
            if (import.meta.env.DEV && awaitInventories?.length) queueMicrotask(clearPendingMove)
            if (!awaitInventories?.length) clearPendingMove()
            return true
        } catch {
            clearPendingMove()
            setError("Inventory connection interrupted")
            return false
        }
    }, [clearPendingMove, movePending, session])

    const move = useCallback((from: InventoryView, fromSlot: number, to: InventoryView, toSlot: number) => {
        const item = findItem(from, fromSlot)
        if (!item || !Number.isFinite(item.amount) || item.amount < 1) {
            setError("That item is no longer available")
            return
        }
        if (from.type === "shop") {
            if (session?.player.id !== to.id) { setError("Shop items can only be purchased into your inventory"); return }
            void submit("buy", { inventory: from.id, slot: fromSlot, amount: 1 }, [from.id, to.id])
            return
        }
        if (to.type === "shop") { setError("Shop inventory is read only"); return }
        void submit("move", {
            fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, amount: item.amount,
            revision: session?.revision, secondaryRevision: session?.secondaryRevision,
        }, [from.id, to.id])
    }, [session, submit])

    const canDropSlot = useCallback((source: DragSlot, target: SlotTarget) => {
        if (!source || !session || movePending || (source.inventoryId === target.inventoryId && source.slot === target.slot)) return false
        const sourceInventory = findInventory(session, source.inventoryId)
        const targetInventory = findInventory(session, target.inventoryId)
        if (!findItem(sourceInventory, source.slot) || !targetInventory) return false
        if (sourceInventory?.type === "shop") return targetInventory.id === session.player.id
        return targetInventory.type !== "shop"
    }, [movePending, session])
    const dropSlot = useCallback((source: DragSlot, target: SlotTarget) => {
        if (!source || !session || !canDropSlot(source, target)) return
        const sourceInventory = findInventory(session, source.inventoryId)
        const targetInventory = findInventory(session, target.inventoryId)
        if (sourceInventory && targetInventory) move(sourceInventory, source.slot, targetInventory, target.slot)
    }, [canDropSlot, move, session])

    // A single click inspects, and only inspects. Moving is drag-only (drag onto
    // a slot to move/stack, drag outside the window to drop), so a click on an
    // empty slot can no longer fling the previous selection into it.
    const selectSlot = useCallback((inventory: InventoryView, item: InventoryItem | undefined, slot: number) => {
        if (movePending) return
        setSelected((current) => {
            if (!item) return undefined
            if (current && current.inventory.id === inventory.id && current.item.slot === slot) return undefined
            return { inventory, item }
        })
    }, [movePending])

    const dropOut = useCallback((source: DragSlot) => {
        if (!session || source.inventoryId !== session.player.id) return
        const item = findItem(session.player, source.slot)
        if (!item || !Number.isFinite(item.amount) || item.amount < 1) { setError("That item is no longer available"); return }
        setSelected(undefined)
        void submit("drop", { inventory: source.inventoryId, slot: source.slot, amount: item.amount })
    }, [session, submit])

    const use = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) { setError("Only items in your inventory can be used"); return }
        void submit("use", { inventory: inventory.id, slot: item.slot })
    }, [session, submit])
    const buy = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.type === "shop" && session) void submit("buy", { inventory: inventory.id, slot: item.slot, amount: 1 }, [inventory.id, session.player.id])
    }, [session, submit])
    // Shared by the Enter-key shortcut on a selected item and the slot
    // grid's double-click handler below -- both just trigger whatever the
    // detail panel's own primary-action button would (buy in a shop, use
    // otherwise), rather than each re-deciding it themselves.
    const activateItem = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.type === "shop") buy(inventory, item)
        else use(inventory, item)
    }, [buy, use])
    const activateSelected = useCallback((selection: Selection) => activateItem(selection.inventory, selection.item), [activateItem])
    const close = useCallback(() => { if (session) void closeSession(session.sessionId, session.token) }, [session])

    useEffect(() => {
        const onKey = (event: KeyboardEvent) => {
            if (event.key === "Escape") close()
            if (event.key === "Enter" && selected && !movePending) activateSelected(selected)
        }
        window.addEventListener("keydown", onKey)
        return () => window.removeEventListener("keydown", onKey)
    }, [activateSelected, close, movePending, selected])

    const filteredSelected = useMemo(() => selected && (selected.item.label ?? selected.item.name).toLowerCase().includes(query.toLowerCase()) ? selected : undefined, [query, selected])
    // A fresh selection always starts at one, so a large slider value can never
    // carry over onto a different (or smaller) stack.
    useEffect(() => { setDropAmount(1) }, [selected?.inventory.id, selected?.item.slot])
    const dropMax = Math.max(1, Math.floor(filteredSelected?.item.amount ?? 1))
    const dropCount = Math.min(Math.max(1, dropAmount), dropMax)
    if (!session) return <UiConfigContext.Provider value={uiConfig}><ItemBoxStack boxes={itemBoxes} />{import.meta.env.DEV ? <button className="dev-launch" onClick={openDevHarness}>Open inventory UI harness</button> : null}</UiConfigContext.Provider>

    // Solo layout: with nothing open beside the player's inventory, drop the
    // third column entirely rather than filling it with a panel whose only
    // content is a sentence explaining that it is empty.
    const solo = uiConfig.centreWhenSolo && !session.secondary

    return <UiConfigContext.Provider value={uiConfig}><ItemBoxStack boxes={itemBoxes} /><WorldDropZone session={session} busy={movePending} onDropOut={dropOut} /><main className="inventory-shell">
        <DragPreview session={session} />
        <header className="inventory-topbar"><div className="brand"><PackageOpen size={20} /><span>INVENTORY</span><em>LIVE</em></div><label className="search"><Search size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search selected item" /></label><button className="close" onClick={close} aria-label="Close inventory"><X size={20} /></button></header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
        <div className={`inventory-layout${solo ? " inventory-layout-solo" : ""}`}>
            <InventoryPanel inventory={session.player} isPlayer selected={selected} busy={movePending} canDropSlot={canDropSlot} onDrop={dropSlot} onDragEnd={() => undefined} onSelect={selectSlot} onActivate={activateItem} />
            <aside className={`item-detail${filteredSelected ? "" : " item-detail-empty"}`}>{filteredSelected ? <>
                <ItemArtwork item={filteredSelected.item} className="detail-art" />
                <p className="eyebrow">{filteredSelected.inventory.type === "shop" ? "shop item" : `slot ${filteredSelected.item.slot}`}</p>
                <h1>{filteredSelected.item.label ?? filteredSelected.item.name}</h1>
                <p>{filteredSelected.item.description ?? "No item description available."}</p>
                <dl><dt>Amount</dt><dd>×{filteredSelected.item.amount}</dd><dt>Weight</dt><dd>{filteredSelected.item.weight ?? 0} g</dd>{filteredSelected.inventory.type === "shop" && <><dt>Price</dt><dd>${(filteredSelected.item.price ?? 0).toLocaleString()}</dd></>}</dl>
                {filteredSelected.inventory.type === "shop" ? <button className="primary-action" disabled={movePending} onClick={() => buy(filteredSelected.inventory, filteredSelected.item)}>Buy one · ${(filteredSelected.item.price ?? 0).toLocaleString()}</button> : <>
                    {(filteredSelected.item.useable || filteredSelected.item.container) && <button className="primary-action" disabled={movePending} onClick={() => use(filteredSelected.inventory, filteredSelected.item)}>{filteredSelected.item.container ? `Open ${filteredSelected.item.label ?? "container"}` : "Use item"}</button>}
                    {filteredSelected.inventory.id === session.player.id && <>
                        <div className="amount-action">
                            {dropMax > 1 && <input className="amount-slider" type="range" min={1} max={dropMax} step={1} value={dropCount} disabled={movePending} aria-label={`Amount to drop, 1 to ${dropMax}`} onChange={(event) => setDropAmount(Number(event.target.value))} />}
                            <button className="quiet-action" disabled={movePending} onClick={() => void submit("drop", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: dropCount })}>Drop {dropCount}</button>
                        </div>
                        {giveAvailable && <button className="quiet-action" disabled={movePending} onClick={() => void submit("give", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: 1 })}>Give one</button>}
                    </>}
                </>}
            </> : <div className="empty-detail"><PackageOpen size={30} /><h1>Item details</h1><p>{selected ? `${(selected.item.label ?? selected.item.name)} is hidden by the current search.` : "Click an item to inspect it. Drag it to move or stack it, or drag it outside the window to drop it."}</p></div>}</aside>
            {session.secondary
                ? <InventoryPanel inventory={session.secondary} selected={selected} busy={movePending} canDropSlot={canDropSlot} onDrop={dropSlot} onDragEnd={() => undefined} onSelect={selectSlot} onActivate={activateItem} />
                : solo ? null : <section className="inventory-panel secondary-empty"><PackageOpen size={28} /><h2>No secondary inventory</h2><p>Open a stash, shop, container, or another player to use this panel.</p></section>}
        </div>
        <footer className="shortcut-bar"><span><kbd>Esc</kbd> Close</span><span><kbd>↵</kbd> Use selected</span><span><kbd>Drag</kbd> Move or stack</span><span><kbd>Drag out</kbd> Drop</span><span>{movePending ? "Updating inventory…" : `Revision ${session.revision ?? 0}`}</span></footer>
    </main></UiConfigContext.Provider>
}

export default function App() {
    return <DndProvider backend={TouchBackend} options={{ enableMouseEvents: true }}><InventoryApp /></DndProvider>
}
