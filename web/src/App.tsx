import { SplitDialog } from "./SplitDialog"
import { Check, CircleAlert, ClipboardCopy, PackageOpen, Search, X } from "lucide-react"
import { Fragment, createContext, useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { DndProvider, useDrag, useDragDropManager, useDragLayer, useDrop } from "react-dnd"
import { TouchBackend } from "react-dnd-touch-backend"
import { closeSession, sendIntent } from "@/lib/nui"
import { openDevHarness } from "@/lib/dev"
import { watchDragRelease } from "@/lib/dragReset"
import { clampGiveAmount } from "@/lib/giveAmount"
import type { InventoryItem, InventoryView, ItemBoxReceipt, SessionPatch, SessionSnapshot, UiConfig } from "@/lib/types"
import { useNuiEvent } from "@/lib/useNuiEvent"
import { predictBuy, predictMove, refreshedInventories, restoreInventories, type Prediction } from "@/lib/optimistic"
import { createIntentResults } from "@/lib/intentResults"
import { createMoveQueue, isNoopMove, type MoveJob, type MoveQueue } from "@/lib/moveQueue"
import { formatMetaValue } from "@/lib/format"
import { copyText, itemCopyText } from "@/lib/clipboard"
import { DEFAULT_PLAYER_LAYOUT, layoutOffsetPx, normalizePlayerLayout, onScreenNudge, type PlayerLayout } from "@/lib/playerLayout"

/** Same factor main.tsx scales the root by. */
function rootScale() {
    return Math.min(2, Math.max(0.5, Math.min(window.innerWidth / 1920, window.innerHeight / 1080)))
}

const SLOT_DRAG_TYPE = "kora_inventory/slot"

// Drags that may wait behind an unanswered request before further ones are refused.
const MAX_QUEUED_MOVES = 8

/**
 * Presentation config from `Config.kora_inventory.ui`, pushed on
 * `kora_inventory:nui:config`.
 *
 * The defaults here are what renders in the window between the UI mounting and
 * that message arriving (and in the dev harness, which sends no config at all),
 * so they mirror the shipped config rather than being "off".
 */
const DEFAULT_UI_CONFIG: Required<Pick<UiConfig, "hotbarSlots" | "centreWhenSolo" | "showHotbar" | "scale" | "rightClickSplit" | "optimisticMoves" | "queueMoves" | "directTransport" | "moveTimeoutMs" | "inspectorDecimals" | "inspectorCopy">> & { images: NonNullable<UiConfig["images"]> } = {
    hotbarSlots: 5,
    centreWhenSolo: true,
    showHotbar: true,
    rightClickSplit: true,
    optimisticMoves: true,
    queueMoves: true,
    directTransport: true,
    // A move that gets no answer would otherwise stay pending for good. Generous
    // because nothing blocks while it waits: a lag spike must not look like a
    // failure and snap the item back (config.lua: ui.moveTimeoutMs).
    moveTimeoutMs: 6000,
    inspectorDecimals: 1,
    inspectorCopy: true,
    scale: 1,
    images: {
        localPath: "nui://kora_inventory/images",
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
function artworkCandidates(item: Pick<InventoryItem, "name" | "label" | "image" | "imageUrl" | "imageOverride">, images: NonNullable<UiConfig["images"]>) {
    const out: string[] = []

    // Only https:// remote artwork. The scheme allowlist is the point: an item
    // definition is data from another resource, and a `javascript:` or `data:`
    // value in `imageUrl` must never reach an `src`.
    const remote = images.allowRemote !== false && item.imageUrl?.startsWith("https://") ? item.imageUrl : undefined

    if (remote && (item.imageOverride || !images.preferLocal)) out.push(remote)

    // kora_core's legacy `image` field is a bare filename ('water_bottle.png'),
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

    if (remote && !item.imageOverride && images.preferLocal) out.push(remote)

    return out
}

function ItemArtwork({ item, className }: { item: Pick<InventoryItem, "name" | "label" | "image" | "imageUrl" | "imageOverride">; className: string }) {
    const { images } = useContext(UiConfigContext)
    const candidates = useMemo(() => artworkCandidates(item, images), [item.name, item.image, item.imageUrl, item.imageOverride, images])
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

// One stable reference: an inline arrow is a new useDrag dependency every render.
const noop = () => undefined

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
    onSplit: (inventory: InventoryView, item: InventoryItem) => void
    /** Part of the hotbar range, so it carries the accent outline. */
    hotbar?: boolean
    /** The last slot of that range, which closes the outline on the right. */
    lastHotbar?: boolean
}

/** React DnD's TouchBackend uses global CEF input listeners for both touch and
 * mouse. Unlike HTML5 DnD or source pointer-capture, it resolves the actual
 * destination slot after the cursor leaves the source element. */
function InventorySlot({ item, index, inventory, selected, busy, hotbar, lastHotbar, canDropSlot, onDrop, onDragEnd, onSelect, onActivate, onSplit }: SlotProps) {
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
        inventory.type === "shop" && "slot-priced",
        // Painted ahead of the server and not confirmed yet: dimmed until its patch lands.
        item?.pending && "slot-pending",
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
        data-fft-kind={inventory.type === "shop" ? "shop-item" : inventory.type === "player" ? "player-slot" : undefined}
        data-fft-item={item?.name}
        aria-label={item ? `${item.label ?? item.name}, slot ${index}` : `Empty slot ${index}`}
        aria-pressed={selected || undefined}
        aria-disabled={busy || undefined}
        data-pending={item?.pending || undefined}
        // A new gesture starts clean: a drag that ended without a click (released
        // on another slot, or outside the window) must not swallow the next real click.
        onMouseDown={() => { suppressClick.current = false }}
        onClick={() => {
            if (suppressClick.current) { suppressClick.current = false; return }
            if (!busy) onSelect(item)
        }}
        onDoubleClick={() => {
            // Same use-item action as the detail panel's Use/Buy button and
            // the Enter-key shortcut on a selected item -- see activateItem.
            if (!busy && item) onActivate(item)
        }}
        onContextMenu={(event) => {
            if (!item || busy) return
            event.preventDefault()
            onSplit(inventory, item)
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
            <span className="item-footer">
                <span className="item-label" title={item.label ?? item.name}>{item.label ?? item.name}</span>
                {inventory.type === "shop" && typeof item.price === "number" && <span className="item-price">${item.price.toLocaleString()}</span>}
            </span>
            <span className="item-amount">×{item.amount}</span>
            {typeof item.durability === "number" && <span className="durability"><i style={{ width: `${Math.max(0, Math.min(100, item.durability))}%` }} /></span>}
        </>}
    </button>
}

function InventoryPanel({ inventory, selected, busy, isPlayer, canDropSlot, onDrop, onDragEnd, onSelect, onActivate, onSplit }: {
    inventory: InventoryView
    selected?: Selection
    busy: boolean
    canDropSlot: (source: DragSlot, target: SlotTarget) => boolean
    onDrop: (source: DragSlot, target: SlotTarget) => void
    onDragEnd: () => void
    onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void
    onActivate: (inventory: InventoryView, item: InventoryItem) => void
    onSplit: (inventory: InventoryView, item: InventoryItem) => void
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

    return <section className={`inventory-panel${isPlayer ? " inventory-panel-player" : ""}`} aria-label={inventory.label ?? inventory.id} aria-busy={busy || undefined}>
        <header className="panel-header">
            <div><p className="eyebrow">{inventory.type ?? "inventory"}</p><h2>{inventory.label ?? inventory.id}</h2></div>
            <div className="weight"><span>{(inventory.weight ?? 0).toLocaleString()} / {(inventory.maxWeight ?? 0).toLocaleString()} g</span><i><b style={{ width: `${percentage}%` }} /></i></div>
        </header>
        <div className="slot-grid">
            {Array.from({ length: inventory.slots }, (_, offset) => {
                const slot = offset + 1
                const item = bySlot.get(slot)
                return <InventorySlot key={slot} index={slot} inventory={inventory} item={item} selected={selected?.inventory.id === inventory.id && selected.item.slot === slot} busy={busy} hotbar={slot <= hotbarCount} lastHotbar={slot === hotbarCount} canDropSlot={canDropSlot} onDrop={onDrop} onDragEnd={onDragEnd} onSelect={(slotItem) => onSelect(inventory, slotItem, slot)} onActivate={(slotItem) => onActivate(inventory, slotItem)} onSplit={onSplit} />
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
    // The NUI root is scaled to provide a consistent layout across game
    // resolutions. Render the preview outside that transformed subtree so the
    // DnD backend's viewport coordinates can be used directly. Keeping the
    // preview in #root makes fixed positioning browser-dependent in CEF and
    // can produce a large horizontal offset at lower resolutions.
    return createPortal(<div className={`inventory-drag-preview slot slot-filled${source.type === "shop" ? " slot-priced" : ""}`} style={{ left: clientOffset.x, top: clientOffset.y }} aria-hidden="true">
        <span className="slot-number">{draggedItem.slot}</span>
        <ItemArtwork item={draggedItem} className="item-art" />
        <span className="item-footer">
            <span className="item-label">{draggedItem.label ?? draggedItem.name}</span>
            {source.type === "shop" && typeof draggedItem.price === "number" && <span className="item-price">${draggedItem.price.toLocaleString()}</span>}
        </span>
        <span className="item-amount">×{draggedItem.amount}</span>
        {typeof draggedItem.durability === "number" && <span className="durability"><i style={{ width: `${Math.max(0, Math.min(100, draggedItem.durability))}%` }} /></span>}
    </div>, document.body)
}

interface ActiveItemBox extends ItemBoxReceipt { id: number }

const ITEM_BOX_ACTIONS = {
    add: { eyebrow: "Received", sign: "+", tone: "gain" },
    purchase: { eyebrow: "Purchased", sign: "+", tone: "gain" },
    remove: { eyebrow: "Removed", sign: "-", tone: "loss" },
    use: { eyebrow: "Used", sign: "-", tone: "loss" },
} as const

function ItemBoxStack({ boxes }: { boxes: ActiveItemBox[] }) {
    if (!boxes.length) return null
    return <aside className="item-box-stack" aria-live="polite" aria-label="Item receipts">
        {boxes.map((box) => {
            // A receipt for an action this build does not know about still
            // reads correctly as an unsigned change rather than a false gain. A signed
            // receipt shows +1 / -1 only; the x multiplier is for unsigned ones.
            const action = ITEM_BOX_ACTIONS[box.action] ?? { eyebrow: "Updated", sign: "", tone: "neutral" }
            return <div className={`item-box item-box-${action.tone}`} key={box.id}>
                <ItemArtwork item={box} className="item-box-art" />
                <div><p>{action.eyebrow}</p><strong>{box.label ?? box.name}</strong></div>
                <b>{action.sign ? `${action.sign}${box.amount}` : `×${box.amount}`}</b>
            </div>
        })}
    </aside>
}

interface HotbarState { id: number; bottom?: number; slots: Array<Partial<InventoryItem> & { slot: number }> }

function HotbarHud({ hotbar }: { hotbar: HotbarState }) {
    return <aside className="hotbar-hud" aria-label="Hotbar" style={Number.isFinite(hotbar.bottom) ? { bottom: `${hotbar.bottom}px` } : undefined}>
        {hotbar.slots.map((item) => <div className={`hotbar-slot${item.name ? "" : " hotbar-slot-empty"}`} key={item.slot}>
            <kbd>{item.slot}</kbd>
            {item.name ? <>
                <ItemArtwork item={item as InventoryItem} className="hotbar-art" />
                <strong>{item.label ?? item.name}</strong>
                {(item.amount ?? 1) > 1 && <b>×{item.amount}</b>}
            </> : null}
        </div>)}
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

/** Ends a drag the backend missed (release outside the window, focus loss,
 * Escape) and when the inventory closes mid-drag. Renders nothing. */
function DragGuard({ open }: { open: boolean }) {
    const manager = useDragDropManager()
    useEffect(() => {
        const monitor = manager.getMonitor()
        const cancel = () => manager.getActions().endDrag()
        if (!open && monitor.isDragging()) cancel()
        return watchDragRelease(window, () => monitor.isDragging(), cancel)
    }, [manager, open])
    return null
}

function InventoryApp() {
    const [session, setSession] = useState<SessionSnapshot | null>(null)
    const [selected, setSelected] = useState<Selection | undefined>()
    const [query, setQuery] = useState("")
    const [error, setError] = useState<string>()
    const [giveAvailable, setGiveAvailable] = useState(false)
    const [movePending, setMovePending] = useState(false)
    const [itemBoxes, setItemBoxes] = useState<ActiveItemBox[]>([])
    const [selectedAmount, setSelectedAmount] = useState(1)
    const [splitTarget, setSplitTarget] = useState<Selection | undefined>()
    const [uiConfig, setUiConfig] = useState(DEFAULT_UI_CONFIG)
    const [copyState, setCopyState] = useState<"idle" | "copied" | "failed">("idle")
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
            optimisticMoves: config.optimisticMoves ?? current.optimisticMoves,
            queueMoves: config.queueMoves ?? current.queueMoves,
            directTransport: config.directTransport ?? current.directTransport,
            moveTimeoutMs: Number.isFinite(config.moveTimeoutMs) && Number(config.moveTimeoutMs) > 0 ? Number(config.moveTimeoutMs) : current.moveTimeoutMs,
            inspectorDecimals: Number.isFinite(config.inspectorDecimals) ? Number(config.inspectorDecimals) : current.inspectorDecimals,
            inspectorCopy: config.inspectorCopy ?? current.inspectorCopy,
            scale: Number.isFinite(config.scale) && Number(config.scale) > 0 ? Number(config.scale) : current.scale,
            images: { ...current.images, ...(config.images ?? {}) },
        }))
    })
    useNuiEvent<{ slots?: HotbarState["slots"]; seconds?: number; bottom?: number }>("kora_inventory:nui:hotbar", ({ slots, seconds, bottom }) => {
        if (!Array.isArray(slots) || !(Number(seconds) > 0)) return
        window.clearTimeout(hotbarTimeout.current)
        setHotbar({ id: Date.now(), slots, bottom: Number.isFinite(bottom) ? Number(bottom) : undefined })
        hotbarTimeout.current = window.setTimeout(() => setHotbar(null), Number(seconds) * 1000)
    })
    useNuiEvent<{ bottom?: number }>("kora_inventory:nui:hotbarPosition", ({ bottom }) => {
        if (!Number.isFinite(bottom)) return
        setHotbar((current) => current ? { ...current, bottom: Number(bottom) } : current)
    })
    useNuiEvent<SessionSnapshot>("kora_inventory:nui:sessionOpened", (snapshot) => {
        window.clearTimeout(hotbarTimeout.current); setHotbar(null)
        clearPendingMove(); updateSession(() => snapshot); setSelected(undefined); setGiveAvailable(false); setError(undefined)
    })
    useNuiEvent<SessionPatch>("kora_inventory:nui:sessionPatched", (patch) => {
        // The server's items win over any prediction for the inventories they cover.
        if (optimistic.current) for (const id of refreshedInventories(patch)) optimistic.current.delete(id)
        queue.patched(patch.snapshot
            ? [patch.snapshot.player.id, patch.snapshot.secondary?.id ?? ""]
            : [patch.player?.id ?? "", patch.secondary?.id ?? ""])
        updateSession((current) => current && current.sessionId === patch.sessionId ? applyPatch(current, patch) : current)
        setSelected(undefined)
    })
    useNuiEvent<{ sessionId: string; reason?: string }>("kora_inventory:nui:sessionClosed", ({ sessionId }) => {
        clearPendingMove()
        updateSession((current) => current?.sessionId === sessionId ? null : current)
    })
    useNuiEvent<{ reason?: string }>("kora_inventory:nui:rejected", ({ reason }) => {
        const message = reason ?? "Action rejected by inventory"
        // Settles the request in flight (once); with nothing in flight it is only a notice.
        if (queue.pending) queue.reject(message)
        else setError(message)
    })
    useNuiEvent<{ requestId?: number; ok?: boolean; error?: string }>("kora_inventory:nui:intentResult", ({ requestId, ok, error }) => {
        if (typeof requestId !== "number") return
        results.current.deliver(requestId, ok === true ? { ok: true } : { ok: false, error: error === "timeout" ? "Inventory did not respond" : error })
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
                // Use can legitimately run long (progress bar), everything else gets a deadline.
                timeoutMs: intent === "use" ? undefined : config.moveTimeoutMs,
                // The server sends its patches before it answers, so with queued
                // moves the answer alone settles; waiting for a patch as well would
                // hold every later drag behind an inventory the server did not re-send.
                awaiting: unlockedNow ? undefined : awaiting,
            }
        })
        if (outcome === "full") setError("Too many moves waiting for the server")
    }, [queue, updateSession])
    const submit = useCallback((intent: Built["intent"], payload: Record<string, unknown> = {}, awaiting?: string[]) => {
        enqueueRequest(() => ({ intent, payload, awaiting }))
    }, [enqueueRequest])
    const move = useCallback((fromId: string, fromSlot: number, toId: string, toSlot: number, requestedAmount?: number) => {
        enqueueRequest((current) => {
            const from = findInventory(current, fromId)
            const to = findInventory(current, toId)
            const item = findItem(from, fromSlot)
            if (!from || !to || !item || !Number.isFinite(item.amount) || item.amount < 1) return "That item is no longer available"
            // Dropped back on its own slot: nothing to ask the server, nothing to lock.
            if (isNoopMove({ id: from.id, slot: fromSlot }, { id: to.id, slot: toSlot })) return undefined
            if (from.type === "shop") {
                if (current.player.id !== to.id) return "Shop items can only be purchased into your inventory"
                const prediction = configRef.current.optimisticMoves ? predictBuy(current, { shopInventory: from.id, slot: fromSlot, amount: 1 }) : undefined
                return { intent: "buy", payload: { inventory: from.id, slot: fromSlot, amount: 1 }, awaiting: [from.id, to.id], prediction }
            }
            if (to.type === "shop") return "Shop inventory is read only"
            const amount = requestedAmount ?? item.amount
            const prediction = configRef.current.optimisticMoves ? predictMove(current, { fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, amount }) : undefined
            return {
                intent: "move",
                payload: { fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, amount, revision: current.revision, secondaryRevision: current.secondaryRevision },
                awaiting: [from.id, to.id],
                prediction,
            }
        })
    }, [enqueueRequest])

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
        const amount = selected?.inventory.id === source.inventoryId && selected.item.slot === source.slot ? selectedCount : undefined
        if (sourceInventory && targetInventory) move(sourceInventory.id, source.slot, targetInventory.id, target.slot, amount)
    }, [canDropSlot, move, selected, selectedCount, session])

    useEffect(() => {
        const handleDragBuy = (event: Event) => {
            const detail = (event as CustomEvent<{item: string; accepted: boolean; error: string}>).detail
            const shop = session?.secondary
            const item = Object.values(shop?.items ?? {}).find(entry => entry?.name === detail.item)
            const target = session?.player
            if (!shop || shop.type !== "shop" || !item || !target || locked) {
                detail.error = 'Shop item or player inventory is unavailable'
                return
            }
            const destination = Object.values(target.items).find(entry => entry?.name === item.name)?.slot ??
                Array.from({ length: target.slots }, (_, index) => index + 1).find(slot => !Object.values(target.items).some(entry => entry?.slot === slot))
            if (!destination) { detail.error = 'No destination slot available'; return }
            const source = { inventoryId: shop.id, slot: item.slot }
            const dest = { inventoryId: target.id, slot: destination }
            if (!canDropSlot(source, dest)) { detail.error = 'Player slot cannot accept the shop item'; return }
            dropSlot(source, dest)
            detail.accepted = true
        }
        window.addEventListener('fft:dragBuy', handleDragBuy)
        return () => window.removeEventListener('fft:dragBuy', handleDragBuy)
    }, [session, locked, canDropSlot, dropSlot])

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

    const dropOut = useCallback((source: DragSlot) => {
        if (source.inventoryId !== sessionRef.current?.player.id) return
        enqueueRequest((current) => {
            const item = findItem(current.player, source.slot)
            if (!item || !Number.isFinite(item.amount) || item.amount < 1) return "That item is no longer available"
            setSelected(undefined)
            return { intent: "drop", payload: { inventory: source.inventoryId, slot: source.slot, amount: item.amount } }
        })
    }, [enqueueRequest])
    const split = useCallback((inventory: InventoryView, item: InventoryItem, requestedAmount?: number) => {
        if (!session || inventory.type === "shop" || item.amount < 2) return
        const amount = Math.floor(requestedAmount ?? selectedCount)
        const emptySlot = Array.from({ length: inventory.slots }, (_, index) => index + 1).find((slot) => !findItem(inventory, slot))
        if (!Number.isFinite(amount) || amount < 1 || amount >= item.amount) { setError(`Choose an amount from 1 to ${item.amount - 1}`); return }
        if (!emptySlot) { setError("No empty slot available to split this stack"); return }
        move(inventory.id, item.slot, inventory.id, emptySlot, amount)
    }, [move, selectedCount, session])
    const promptSplit = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (!uiConfig.rightClickSplit || inventory.type === "shop" || item.amount < 2) return
        setSplitTarget({ inventory, item })
    }, [uiConfig.rightClickSplit])
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
    useEffect(() => { setSplitTarget(undefined) }, [session?.sessionId, session?.revision, session?.secondaryRevision])

    const use = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) { setError("Only items in your inventory can be used"); return }
        void submit("use", { inventory: inventory.id, slot: item.slot })
    }, [session, submit])
    const buy = useCallback((inventory: InventoryView, item: InventoryItem, amount = 1) => {
        if (inventory.type !== "shop" || !session) return
        const stock = Math.max(1, Math.floor(item.amount))
        const count = Math.min(Math.max(1, Math.floor(amount)), stock)
        enqueueRequest((current) => {
            const prediction = configRef.current.optimisticMoves ? predictBuy(current, { shopInventory: inventory.id, slot: item.slot, amount: count }) : undefined
            return { intent: "buy", payload: { inventory: inventory.id, slot: item.slot, amount: count }, awaiting: [inventory.id, current.player.id], prediction }
        })
    }, [enqueueRequest, session])
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
            if (event.key === "Escape" && splitTarget) { setSplitTarget(undefined); return }
            if (event.key === "Escape" || event.key === "Tab") close()
            if (event.key === "Enter" && selected && !locked && !movePending) activateSelected(selected)
        }
        window.addEventListener("keydown", onKey)
        return () => window.removeEventListener("keydown", onKey)
    }, [activateSelected, close, locked, movePending, selected, splitTarget])

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

    // Per-player position/size/side from kora_hud's /ui editor (client/ui.lua
    // relays it). Defaults render exactly the shipped layout.
    const [playerLayout, setPlayerLayout] = useState<PlayerLayout>(DEFAULT_PLAYER_LAYOUT)
    useNuiEvent<unknown>("kora_inventory:nui:layout", (raw) => setPlayerLayout(normalizePlayerLayout(raw)))
    const [viewport, setViewport] = useState({ width: window.innerWidth, height: window.innerHeight })
    useEffect(() => {
        const onResize = () => setViewport({ width: window.innerWidth, height: window.innerHeight })
        window.addEventListener("resize", onResize)
        return () => window.removeEventListener("resize", onResize)
    }, [])
    const shellRef = useRef<HTMLElement>(null)
    const [nudge, setNudge] = useState({ x: 0, y: 0 })
    const transferView = Boolean(session?.secondary)
    const offsetPx = layoutOffsetPx(playerLayout, transferView, { width: viewport.width / rootScale(), height: viewport.height / rootScale() })
    // Keep the window on screen after a resolution/aspect change or a large
    // scale: measured once per layout/resize/view change, never persisted.
    useLayoutEffect(() => {
        const shell = shellRef.current
        if (!shell) return
        const next = onScreenNudge(shell.getBoundingClientRect(), nudge, viewport, rootScale())
        if (Math.abs(next.x - nudge.x) > 0.5 || Math.abs(next.y - nudge.y) > 0.5) setNudge(next)
    }, [nudge, offsetPx.x, offsetPx.y, playerLayout.scale, transferView, viewport, Boolean(session)])
    const shellStyle = {
        "--layout-x": `${offsetPx.x + nudge.x}px`,
        "--layout-y": `${offsetPx.y + nudge.y}px`,
        "--layout-scale": String(playerLayout.scale),
    } as React.CSSProperties

    const solo = Boolean(session && uiConfig.centreWhenSolo && !session.secondary)
    // Search belongs to the three-column transfer view. It is intentionally
    // hidden in compact solo mode, so a query left over from another session
    // must never hide the newly selected drawer contents.
    const filteredSelected = useMemo(() => selected && (solo || (selected.item.label ?? selected.item.name).toLowerCase().includes(query.toLowerCase())) ? selected : undefined, [query, selected, solo])
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
    if (!session) return <UiConfigContext.Provider value={uiConfig}><DragGuard open={false} />{hotbar && <HotbarHud hotbar={hotbar} />}<ItemBoxStack boxes={itemBoxes} />{import.meta.env.DEV ? <button className="dev-launch" onClick={openDevHarness}>Open inventory UI harness</button> : null}</UiConfigContext.Provider>

    // Solo layout starts as the player's inventory alone. Its inspector is a
    // drawer, mounted only after selection, so an idle personal inventory does
    // not reserve a permanently empty actions column.
    return <UiConfigContext.Provider value={uiConfig}><ItemBoxStack boxes={itemBoxes} /><DragGuard open /><WorldDropZone session={session} busy={locked} onDropOut={dropOut} />{splitTarget && <SplitDialog label={splitTarget.item.label ?? splitTarget.item.name} stack={splitTarget.item.amount} onConfirm={confirmSplit} onCancel={() => setSplitTarget(undefined)} />}<main ref={shellRef} style={shellStyle} className={`inventory-shell${solo ? " inventory-shell-solo" : ""}${solo && offsetPx.x > 0 ? " inventory-shell-drawer-left" : ""}`}>
        <DragPreview session={session} />
        <div className="inventory-heading">
            <header className="inventory-topbar">
                <div className="brand"><span className="brand-mark"><PackageOpen size={18} /></span><span>INVENTORY</span><em><i />LIVE</em></div>
                <label className="search"><Search size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Filter the selected item" /></label>
                <div className="topbar-actions"><span className="session-state">{session.secondary ? "Transfer open" : "Personal inventory"}</span><button className="close" onClick={close} aria-label="Close inventory"><X size={18} /></button></div>
            </header>
            {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
        </div>
        <div className={`inventory-layout${solo ? " inventory-layout-solo" : ""}${!solo && playerLayout.playerSide === "right" ? " inventory-layout-swapped" : ""}`}>
            <section className="inventory-stage inventory-stage-player">
                <InventoryPanel inventory={session.player} isPlayer selected={selected} busy={locked} canDropSlot={canDropSlot} onDrop={dropSlot} onDragEnd={noop} onSelect={selectSlot} onActivate={activateItem} onSplit={promptSplit} />
            </section>
            {(!solo || selected) && <aside className={`item-detail${solo ? " item-detail-drawer" : ""}${filteredSelected ? "" : " item-detail-empty"}${filteredSelected && uiConfig.inspectorCopy ? " item-detail-copyable" : ""}`} aria-label="Selected item actions">
                <header className="detail-header"><span>Item inspector</span><span className="detail-header-actions"><em>{filteredSelected ? "Selected" : "Select an item"}</em>{filteredSelected && uiConfig.inspectorCopy && <button className={`detail-copy${copyState === "idle" ? "" : ` detail-copy-${copyState}`}`} onClick={() => void copySelected(filteredSelected)} aria-label="Copy item details and metadata" title="Copy item details and metadata (JSON)">{copyState === "copied" ? <Check size={12} /> : <ClipboardCopy size={12} />}<span>{copyState === "copied" ? "Copied" : copyState === "failed" ? "Copy failed" : "Copy"}</span></button>}{solo && <button className="detail-close" onClick={() => setSelected(undefined)} aria-label="Close item drawer"><X size={14} /></button>}</span></header>
                {filteredSelected ? <>
                <ItemArtwork item={filteredSelected.item} className="detail-art" />
                <p className="eyebrow">{filteredSelected.inventory.type === "shop" ? "shop item" : `slot ${filteredSelected.item.slot}`}</p>
                <h1>{filteredSelected.item.label ?? filteredSelected.item.name}</h1>
                <p>{filteredSelected.item.description ?? "No item description available."}</p>
                <dl><dt>Amount</dt><dd>×{filteredSelected.item.amount}</dd><dt>Weight</dt><dd>{filteredSelected.item.weight ?? 0} g</dd>{filteredSelected.item.displayMeta?.map((meta, index) => <Fragment key={index}><dt>{meta.label}</dt><dd>{formatMetaValue(meta.value, uiConfig.inspectorDecimals)}</dd></Fragment>)}{filteredSelected.inventory.type === "shop" && <><dt>Price</dt><dd>${(filteredSelected.item.price ?? 0).toLocaleString()}</dd></>}</dl>
                {filteredSelected.inventory.type === "shop" ? <div className="amount-action">
                    {selectedMax > 1 && <input data-fft-kind="quantity" className="amount-slider" type="range" min={1} max={selectedMax} step={1} value={selectedCount} disabled={movePending} aria-label={`Quantity to buy, 1 to ${selectedMax}`} onChange={(event) => setSelectedAmount(Number(event.target.value))} />}
                    <button data-fft-kind="buy" data-fft-item={filteredSelected.item.name} data-fft-quantity={selectedCount} className="primary-action" disabled={movePending} onClick={() => buy(filteredSelected.inventory, filteredSelected.item, selectedCount)}>Buy {selectedCount} · ${((filteredSelected.item.price ?? 0) * selectedCount).toLocaleString()}</button>
                </div> : <>
                    {(filteredSelected.item.useable || filteredSelected.item.container) && <button className="primary-action" disabled={movePending} onClick={() => use(filteredSelected.inventory, filteredSelected.item)}>{filteredSelected.item.container ? `Open ${filteredSelected.item.label ?? "container"}` : "Use item"}</button>}
                    {selectedMax > 1 && <div className="amount-picker"><input className="amount-slider" type="range" min={1} max={selectedMax} step={1} value={selectedCount} disabled={movePending} aria-label={`Amount to move, 1 to ${selectedMax}`} onChange={(event) => setSelectedAmount(Number(event.target.value))} /><input className="amount-input" type="number" min={1} max={selectedMax} value={selectedCount} disabled={movePending} aria-label="Amount to move" onChange={(event) => setSelectedAmount(Number(event.target.value))} /></div>}
                    {selectedMax > 1 && <button className="quiet-action" disabled={movePending} onClick={() => split(filteredSelected.inventory, filteredSelected.item)}>Split {selectedCount} / {selectedMax - selectedCount}</button>}
                    {filteredSelected.inventory.id === session.player.id && <>
                        <div className="amount-action">
                            <button className="quiet-action" disabled={movePending} onClick={() => void submit("drop", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: selectedCount })}>Drop {selectedCount}</button>
                        </div>
                        {giveAvailable && <button className="quiet-action" disabled={movePending} onClick={() => void submit("give", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: clampGiveAmount(selectedCount, filteredSelected.item.amount) })}>Give {selectedCount}</button>}
                    </>}
                </>}
            </> : <div className="empty-detail"><span className="empty-detail-icon"><PackageOpen size={30} /></span><h1>Inspect an item</h1><p>{selected ? `${(selected.item.label ?? selected.item.name)} is hidden by the current search.` : "Select an item to see its details. Drag it between slots to move or stack it, or drag it outside the window to drop it."}</p></div>}</aside>}
            {session.secondary
                ? <section className="inventory-stage inventory-stage-secondary"><InventoryPanel inventory={session.secondary} selected={selected} busy={locked} canDropSlot={canDropSlot} onDrop={dropSlot} onDragEnd={noop} onSelect={selectSlot} onActivate={activateItem} onSplit={promptSplit} /></section>
                : solo ? null : <section className="inventory-stage inventory-stage-secondary"><section className="inventory-panel secondary-empty"><PackageOpen size={28} /><h2>No secondary inventory</h2><p>Open a stash, shop, container, or another player to use this panel.</p></section></section>}
        </div>
        <footer className="shortcut-bar"><span><kbd>Esc</kbd> Close</span><span><kbd>↵</kbd> Use selected</span><span><kbd>Drag</kbd> Move or stack</span><span><kbd>Drag out</kbd> Drop</span><span>{movePending ? "Updating inventory…" : `Revision ${session.revision ?? 0}`}</span></footer>
    </main></UiConfigContext.Provider>
}

export default function App() {
    return <DndProvider backend={TouchBackend} options={{ enableMouseEvents: true }}><InventoryApp /></DndProvider>
}
