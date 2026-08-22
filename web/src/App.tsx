import { CircleAlert, PackageOpen, Search, X } from "lucide-react"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { DndProvider, useDrag, useDragLayer, useDrop } from "react-dnd"
import { TouchBackend } from "react-dnd-touch-backend"
import { closeSession, sendIntent } from "@/lib/nui"
import { openDevHarness } from "@/lib/dev"
import type { InventoryItem, InventoryView, SessionPatch, SessionSnapshot, ThemeTokens } from "@/lib/types"
import { useNuiEvent } from "@/lib/useNuiEvent"

const SLOT_DRAG_TYPE = "qbinventory/slot"

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

function ItemArtwork({ item, className }: { item: InventoryItem; className: string }) {
    const [failed, setFailed] = useState(false)
    const source = !failed && item.imageUrl?.startsWith("https://") ? item.imageUrl : undefined
    return <span className={className}>{source ? <img src={source} alt="" onError={() => setFailed(true)} /> : (item.label ?? item.name).slice(0, 1)}</span>
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
}

/** React DnD's TouchBackend uses global CEF input listeners for both touch and
 * mouse. Unlike HTML5 DnD or source pointer-capture, it resolves the actual
 * destination slot after the cursor leaves the source element. */
function InventorySlot({ item, index, inventory, selected, busy, canDropSlot, onDrop, onDragEnd, onSelect }: SlotProps) {
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

function InventoryPanel({ inventory, selected, busy, canDropSlot, onDrop, onDragEnd, onSelect }: {
    inventory: InventoryView
    selected?: Selection
    busy: boolean
    canDropSlot: (source: DragSlot, target: SlotTarget) => boolean
    onDrop: (source: DragSlot, target: SlotTarget) => void
    onDragEnd: () => void
    onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void
}) {
    const items = asSlots(inventory.items)
    const bySlot = new Map(items.map((item) => [item.slot, item]))
    const percentage = inventory.maxWeight ? Math.min(100, Math.round(((inventory.weight ?? 0) / inventory.maxWeight) * 100)) : 0
    return <section className="inventory-panel" aria-label={inventory.label ?? inventory.id} aria-busy={busy || undefined}>
        <header className="panel-header">
            <div><p className="eyebrow">{inventory.type ?? "inventory"}</p><h2>{inventory.label ?? inventory.id}</h2></div>
            <div className="weight"><span>{(inventory.weight ?? 0).toLocaleString()} / {(inventory.maxWeight ?? 0).toLocaleString()} g</span><i><b style={{ width: `${percentage}%` }} /></i></div>
        </header>
        <div className="slot-grid">
            {Array.from({ length: inventory.slots }, (_, offset) => {
                const slot = offset + 1
                const item = bySlot.get(slot)
                return <InventorySlot key={slot} index={slot} inventory={inventory} item={item} selected={selected?.inventory.id === inventory.id && selected.item.slot === slot} busy={busy} canDropSlot={canDropSlot} onDrop={onDrop} onDragEnd={onDragEnd} onSelect={(slotItem) => onSelect(inventory, slotItem, slot)} />
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
    return <div className="inventory-drag-preview" style={{ transform: `translate3d(${clientOffset.x + 14}px, ${clientOffset.y + 14}px, 0)` }} aria-hidden="true">
        <ItemArtwork item={draggedItem} className="drag-preview-art" />
        <span>{draggedItem.label ?? draggedItem.name}</span>
        <b>×{draggedItem.amount}</b>
    </div>
}

function InventoryApp() {
    const [session, setSession] = useState<SessionSnapshot | null>(null)
    const [selected, setSelected] = useState<Selection | undefined>()
    const [query, setQuery] = useState("")
    const [error, setError] = useState<string>()
    const [giveAvailable, setGiveAvailable] = useState(false)
    const [movePending, setMovePending] = useState(false)
    const pendingInventories = useRef<Set<string> | undefined>()

    const clearPendingMove = useCallback(() => {
        pendingInventories.current = undefined
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

    const submit = useCallback(async (intent: Parameters<typeof sendIntent>[0]["intent"], payload: Record<string, unknown> = {}, awaitInventories?: string[]) => {
        if (!session || movePending) return false
        if (awaitInventories?.length) {
            pendingInventories.current = new Set(awaitInventories)
            setMovePending(true)
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

    const selectSlot = useCallback((inventory: InventoryView, item: InventoryItem | undefined, slot: number) => {
        if (movePending) return
        if (selected) {
            if (selected.inventory.type === "shop" && inventory.id === selected.inventory.id) { setSelected(item ? { inventory, item } : undefined); return }
            if (selected.inventory.id === inventory.id && selected.item.slot === slot) { setSelected(undefined); return }
            if (item) setSelected({ inventory, item })
            else { move(selected.inventory, selected.item.slot, inventory, slot); setSelected(undefined) }
            return
        }
        if (item) setSelected({ inventory, item })
    }, [move, movePending, selected])

    const use = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) { setError("Only items in your inventory can be used"); return }
        void submit("use", { inventory: inventory.id, slot: item.slot })
    }, [session, submit])
    const buy = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.type === "shop" && session) void submit("buy", { inventory: inventory.id, slot: item.slot, amount: 1 }, [inventory.id, session.player.id])
    }, [session, submit])
    const activateSelected = useCallback((selection: Selection) => {
        if (selection.inventory.type === "shop") buy(selection.inventory, selection.item)
        else use(selection.inventory, selection.item)
    }, [buy, use])
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
    if (!session) return import.meta.env.DEV ? <button className="dev-launch" onClick={openDevHarness}>Open inventory UI harness</button> : null

    return <main className="inventory-shell">
        <DragPreview session={session} />
        <header className="inventory-topbar"><div className="brand"><PackageOpen size={20} /><span>INVENTORY</span><em>LIVE</em></div><label className="search"><Search size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search selected item" /></label><button className="close" onClick={close} aria-label="Close inventory"><X size={20} /></button></header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
        <div className="inventory-layout">
            <InventoryPanel inventory={session.player} selected={selected} busy={movePending} canDropSlot={canDropSlot} onDrop={dropSlot} onDragEnd={() => undefined} onSelect={selectSlot} />
            <aside className={`item-detail${filteredSelected ? "" : " item-detail-empty"}`}>{filteredSelected ? <>
                <ItemArtwork item={filteredSelected.item} className="detail-art" />
                <p className="eyebrow">{filteredSelected.inventory.type === "shop" ? "shop item" : `slot ${filteredSelected.item.slot}`}</p>
                <h1>{filteredSelected.item.label ?? filteredSelected.item.name}</h1>
                <p>{filteredSelected.item.description ?? "No item description available."}</p>
                <dl><dt>Amount</dt><dd>×{filteredSelected.item.amount}</dd><dt>Weight</dt><dd>{filteredSelected.item.weight ?? 0} g</dd>{filteredSelected.inventory.type === "shop" && <><dt>Price</dt><dd>${(filteredSelected.item.price ?? 0).toLocaleString()}</dd></>}</dl>
                {filteredSelected.inventory.type === "shop" ? <button className="primary-action" disabled={movePending} onClick={() => buy(filteredSelected.inventory, filteredSelected.item)}>Buy one · ${(filteredSelected.item.price ?? 0).toLocaleString()}</button> : <>
                    {(filteredSelected.item.useable || filteredSelected.item.container) && <button className="primary-action" disabled={movePending} onClick={() => use(filteredSelected.inventory, filteredSelected.item)}>{filteredSelected.item.container ? `Open ${filteredSelected.item.label ?? "container"}` : "Use item"}</button>}
                    {filteredSelected.inventory.id === session.player.id && <>
                        <button className="quiet-action" disabled={movePending} onClick={() => void submit("drop", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: 1 })}>Drop one</button>
                        {giveAvailable && <button className="quiet-action" disabled={movePending} onClick={() => void submit("give", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: 1 })}>Give one</button>}
                    </>}
                </>}
            </> : <div className="empty-detail"><PackageOpen size={30} /><h1>Item details</h1><p>{selected ? `Choose a destination for ${(selected.item.label ?? selected.item.name)}.` : "Select an item to inspect it, then use, move, or drop it."}</p></div>}</aside>
            {session.secondary ? <InventoryPanel inventory={session.secondary} selected={selected} busy={movePending} canDropSlot={canDropSlot} onDrop={dropSlot} onDragEnd={() => undefined} onSelect={selectSlot} /> : <section className="inventory-panel secondary-empty"><PackageOpen size={28} /><h2>No secondary inventory</h2><p>Open a stash, shop, container, or another player to use this panel.</p></section>}
        </div>
        <footer className="shortcut-bar"><span><kbd>Esc</kbd> Close</span><span><kbd>↵</kbd> Use selected</span><span><kbd>Drag</kbd> Move or stack</span><span>{movePending ? "Updating inventory…" : `Revision ${session.revision ?? 0}`}</span></footer>
    </main>
}

export default function App() {
    return <DndProvider backend={TouchBackend} options={{ enableMouseEvents: true }}><InventoryApp /></DndProvider>
}
