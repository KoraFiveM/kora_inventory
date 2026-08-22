import { Search, X, PackageOpen, CircleAlert } from "lucide-react"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { closeSession, sendIntent } from "@/lib/nui"
import { openDevHarness } from "@/lib/dev"
import type { InventoryItem, InventoryView, SessionPatch, SessionSnapshot, ThemeTokens } from "@/lib/types"
import { useNuiEvent } from "@/lib/useNuiEvent"

function asSlots(items: InventoryView["items"]): InventoryItem[] {
    return Array.isArray(items) ? items : Object.values(items ?? {})
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

interface SlotProps {
    item?: InventoryItem
    index: number
    selected: boolean
    moveTarget: boolean
    showPrice: boolean
    onSelect: (item?: InventoryItem) => void
    onPointerStart: (item: InventoryItem | undefined, pointerId: number) => void
    onPointerEnd: (item: InventoryItem | undefined, pointerId: number) => void
    onTarget: () => void
    onClearTarget: () => void
}

interface Selection {
    inventory: InventoryView
    item: InventoryItem
}

function InventorySlot({ item, index, selected, moveTarget, showPrice, onSelect, onPointerStart, onPointerEnd, onTarget, onClearTarget }: SlotProps) {
    return <button
        className={`slot${item ? " slot-filled" : ""}${selected ? " slot-selected" : ""}${moveTarget ? " slot-move-target" : ""}`}
        aria-label={item ? `${item.label ?? item.name}, slot ${index}` : `Empty slot ${index}`}
        aria-pressed={selected || undefined}
        onPointerDown={(event) => {
            if (event.pointerType === "mouse" && event.button !== 0) return
            onPointerStart(item, event.pointerId)
        }}
        onPointerUp={(event) => {
            if (event.pointerType === "mouse" && event.button !== 0) return
            event.preventDefault()
            onPointerEnd(item, event.pointerId)
        }}
        onPointerEnter={onTarget}
        onPointerLeave={onClearTarget}
        onKeyDown={(event) => {
            if (event.key !== "Enter" && event.key !== " ") return
            event.preventDefault()
            event.stopPropagation()
            onSelect(item)
        }}
    >
        <span className="slot-number">{index}</span>
        {item && <>
            <span className="item-art" aria-hidden="true">{(item.label ?? item.name).slice(0, 1)}</span>
            <span className="item-label">{item.label ?? item.name}</span>
            <span className="item-amount">×{item.amount}</span>
            {showPrice && typeof item.price === "number" && <span className="item-price">${item.price.toLocaleString()}</span>}
            {typeof item.durability === "number" && <span className="durability"><i style={{ width: `${Math.max(0, Math.min(100, item.durability))}%` }} /></span>}
        </>}
    </button>
}

function InventoryPanel({ inventory, selected, moveTarget, onSelect, onPointerStart, onPointerEnd, onTarget, onClearTarget }: {
    inventory: InventoryView; selected?: Selection; moveTarget?: SlotTarget; onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void; onPointerStart: (inventory: InventoryView, item: InventoryItem | undefined, pointerId: number) => void; onPointerEnd: (inventory: InventoryView, item: InventoryItem | undefined, slot: number, pointerId: number) => void; onTarget: (inventory: InventoryView, slot: number) => void; onClearTarget: () => void
}) {
    const items = asSlots(inventory.items)
    const bySlot = new Map(items.map((item) => [item.slot, item]))
    const percentage = inventory.maxWeight ? Math.min(100, Math.round(((inventory.weight ?? 0) / inventory.maxWeight) * 100)) : 0
    return <section className="inventory-panel" aria-label={inventory.label ?? inventory.id}>
        <header className="panel-header">
            <div><p className="eyebrow">{inventory.type ?? "inventory"}</p><h2>{inventory.label ?? inventory.id}</h2></div>
            <div className="weight"><span>{(inventory.weight ?? 0).toLocaleString()} / {(inventory.maxWeight ?? 0).toLocaleString()} g</span><i><b style={{ width: `${percentage}%` }} /></i></div>
        </header>
        <div className="slot-grid">
            {Array.from({ length: inventory.slots }, (_, offset) => {
                const slot = offset + 1
                return <InventorySlot key={slot} index={slot} item={bySlot.get(slot)} selected={selected?.inventory.id === inventory.id && selected.item.slot === slot} moveTarget={moveTarget?.inventory.id === inventory.id && moveTarget.slot === slot} showPrice={inventory.type === "shop"} onSelect={(item) => onSelect(inventory, item, slot)} onPointerStart={(item, pointerId) => onPointerStart(inventory, item, pointerId)} onPointerEnd={(item, pointerId) => onPointerEnd(inventory, item, slot, pointerId)} onTarget={() => onTarget(inventory, slot)} onClearTarget={onClearTarget} />
            })}
        </div>
    </section>
}

interface SlotTarget {
    inventory: InventoryView
    slot: number
}

interface PointerSource {
    pointerId: number
    selection: Selection
}

function App() {
    const [session, setSession] = useState<SessionSnapshot | null>(null)
    const [selected, setSelected] = useState<Selection | undefined>()
    const [moveTarget, setMoveTarget] = useState<SlotTarget | undefined>()
    const pointerSource = useRef<PointerSource | undefined>()
    const [query, setQuery] = useState("")
    const [error, setError] = useState<string>()
    const [giveAvailable, setGiveAvailable] = useState(false)

    useNuiEvent<ThemeTokens>("qbinventory:nui:theme", (tokens) => {
        for (const [key, value] of Object.entries(tokens ?? {})) document.documentElement.style.setProperty(`--${key}`, value)
    })
    useNuiEvent<SessionSnapshot>("qbinventory:nui:sessionOpened", (snapshot) => { pointerSource.current = undefined; setSession(snapshot); setSelected(undefined); setMoveTarget(undefined); setGiveAvailable(false); setError(undefined) })
    useNuiEvent<SessionPatch>("qbinventory:nui:sessionPatched", (patch) => setSession((current) => current && current.sessionId === patch.sessionId ? applyPatch(current, patch) : current))
    useNuiEvent<{ sessionId: string; reason?: string }>("qbinventory:nui:sessionClosed", ({ sessionId }) => setSession((current) => current?.sessionId === sessionId ? null : current))
    useNuiEvent<{ reason?: string }>("qbinventory:nui:rejected", ({ reason }) => setError(reason ?? "Action rejected by inventory"))
    useNuiEvent<{ available?: boolean }>("qbinventory:nui:giveAvailability", ({ available }) => setGiveAvailable(available === true))

    const submit = useCallback(async (intent: Parameters<typeof sendIntent>[0]["intent"], payload: Record<string, unknown> = {}) => {
        if (!session) return
        try {
            const response = await sendIntent({ sessionId: session.sessionId, token: session.token, intent, payload })
            if (!response.ok) setError(response.error ?? "Action rejected by inventory")
        } catch { setError("Inventory connection interrupted") }
    }, [session])

    const move = useCallback((from: InventoryView, fromSlot: number, to: InventoryView, toSlot: number) => {
        if (from.type === "shop") {
            if (to.id !== session?.player.id) { setError("Shop items can only be purchased into your inventory"); return }
            void submit("buy", { inventory: from.id, slot: fromSlot, amount: 1 })
            return
        }
        if (to.type === "shop") { setError("Shop inventory is read only"); return }
        void submit("move", { fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, revision: session?.revision, secondaryRevision: session?.secondaryRevision })
    }, [session, submit])
    const selectSlot = useCallback((inventory: InventoryView, item: InventoryItem | undefined, slot: number) => {
        if (selected) {
            if (selected.inventory.id === inventory.id && selected.item.slot === slot) {
                setSelected(undefined)
                setMoveTarget(undefined)
                return
            }
            move(selected.inventory, selected.item.slot, inventory, slot)
            setSelected(undefined)
            setMoveTarget(undefined)
            return
        }
        if (item) setSelected({ inventory, item })
    }, [move, selected])
    const startPointer = useCallback((inventory: InventoryView, item: InventoryItem | undefined, pointerId: number) => {
        if (!item || selected) return
        const selection = { inventory, item }
        pointerSource.current = { pointerId, selection }
        setSelected(selection)
        setMoveTarget(undefined)
    }, [selected])
    const finishPointer = useCallback((inventory: InventoryView, item: InventoryItem | undefined, slot: number, pointerId: number) => {
        const source = pointerSource.current
        if (source?.pointerId === pointerId) pointerSource.current = undefined
        if (source && (source.selection.inventory.id !== inventory.id || source.selection.item.slot !== slot)) {
            move(source.selection.inventory, source.selection.item.slot, inventory, slot)
            setSelected(undefined)
            setMoveTarget(undefined)
            return
        }
        if (source) return
        selectSlot(inventory, item, slot)
    }, [move, selectSlot])
    const setTarget = useCallback((inventory: InventoryView, slot: number) => {
        const source = selected ?? pointerSource.current?.selection
        if (!source || (source.inventory.id === inventory.id && source.item.slot === slot)) return
        setMoveTarget({ inventory, slot })
    }, [selected])
    const clearTarget = useCallback(() => setMoveTarget(undefined), [])
    const use = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.id !== session?.player.id) { setError("Only items in your inventory can be used"); return }
        void submit("use", { inventory: inventory.id, slot: item.slot })
    }, [session, submit])
    const buy = useCallback((inventory: InventoryView, item: InventoryItem) => {
        if (inventory.type !== "shop") return
        void submit("buy", { inventory: inventory.id, slot: item.slot, amount: 1 })
    }, [submit])
    const activateSelected = useCallback((selection: Selection) => {
        if (selection.inventory.type === "shop") buy(selection.inventory, selection.item)
        else use(selection.inventory, selection.item)
    }, [buy, use])
    const close = useCallback(() => { if (session) void closeSession(session.sessionId, session.token) }, [session])

    useEffect(() => {
        const onKey = (event: KeyboardEvent) => {
            if (event.key === "Escape") close()
            if (event.key === "Enter" && selected) activateSelected(selected)
        }
        window.addEventListener("keydown", onKey)
        return () => window.removeEventListener("keydown", onKey)
    }, [activateSelected, close, selected])

    const filteredSelected = useMemo(() => selected && (selected.item.label ?? selected.item.name).toLowerCase().includes(query.toLowerCase()) ? selected : undefined, [query, selected])
    if (!session) return import.meta.env.DEV ? <button className="dev-launch" onClick={openDevHarness}>Open inventory UI harness</button> : null

    return <main className="inventory-shell">
        <header className="inventory-topbar"><div className="brand"><PackageOpen size={20} /><span>INVENTORY</span><em>LIVE</em></div><label className="search"><Search size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search selected item" /></label><button className="close" onClick={close} aria-label="Close inventory"><X size={20} /></button></header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
        <div className="inventory-layout">
            <InventoryPanel inventory={session.player} selected={selected} moveTarget={moveTarget} onSelect={selectSlot} onPointerStart={startPointer} onPointerEnd={finishPointer} onTarget={setTarget} onClearTarget={clearTarget} />
            <aside className={`item-detail${filteredSelected ? "" : " item-detail-empty"}`}>{filteredSelected ? <>
                <div className="detail-art">{(filteredSelected.item.label ?? filteredSelected.item.name).slice(0, 1)}</div>
                <p className="eyebrow">{filteredSelected.inventory.type === "shop" ? "shop item" : `slot ${filteredSelected.item.slot}`}</p>
                <h1>{filteredSelected.item.label ?? filteredSelected.item.name}</h1>
                <p>{filteredSelected.item.description ?? "No item description available."}</p>
                <dl><dt>Amount</dt><dd>×{filteredSelected.item.amount}</dd><dt>Weight</dt><dd>{filteredSelected.item.weight ?? 0} g</dd>{filteredSelected.inventory.type === "shop" && <><dt>Price</dt><dd>${(filteredSelected.item.price ?? 0).toLocaleString()}</dd></>}</dl>
                {filteredSelected.inventory.type === "shop" ? <button className="primary-action" onClick={() => buy(filteredSelected.inventory, filteredSelected.item)}>Buy one · ${(filteredSelected.item.price ?? 0).toLocaleString()}</button> : <>
                    <button className="primary-action" onClick={() => use(filteredSelected.inventory, filteredSelected.item)}>Use item</button>
                    {filteredSelected.inventory.id === session.player.id && <>
                        <button className="quiet-action" onClick={() => void submit("drop", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: 1 })}>Drop one</button>
                        {giveAvailable && <button className="quiet-action" onClick={() => void submit("give", { inventory: filteredSelected.inventory.id, slot: filteredSelected.item.slot, amount: 1 })}>Give one</button>}
                    </>}
                </>}
            </> : <div className="empty-detail"><PackageOpen size={30} /><h1>Item details</h1><p>{selected ? `Choose a destination for ${(selected.item.label ?? selected.item.name)}.` : "Select an item to inspect it, then use, move, or drop it."}</p></div>}</aside>
            {session.secondary ? <InventoryPanel inventory={session.secondary} selected={selected} moveTarget={moveTarget} onSelect={selectSlot} onPointerStart={startPointer} onPointerEnd={finishPointer} onTarget={setTarget} onClearTarget={clearTarget} /> : <section className="inventory-panel secondary-empty"><PackageOpen size={28} /><h2>No secondary inventory</h2><p>Open a stash, shop, container, or another player to use this panel.</p></section>}
        </div>
        <footer className="shortcut-bar"><span><kbd>Esc</kbd> Close</span><span><kbd>↵</kbd> Use selected</span><span><kbd>Click</kbd> Select, then destination</span><span>Revision {session.revision ?? 0}</span></footer>
    </main>
}

export default App
