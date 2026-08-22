import { Search, X, PackageOpen, CircleAlert } from "lucide-react"
import { useCallback, useEffect, useMemo, useState } from "react"
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
    inventory: InventoryView
    onMove: (from: InventoryView, fromSlot: number, to: InventoryView, toSlot: number) => void
    onUse: (inventory: InventoryView, item: InventoryItem) => void
    selected: boolean
    onSelect: (item?: InventoryItem) => void
}

function InventorySlot({ item, index, inventory, onMove, onUse, selected, onSelect }: SlotProps) {
    return <button
        className={`slot${item ? " slot-filled" : ""}${selected ? " slot-selected" : ""}`}
        draggable={Boolean(item)}
        aria-label={item ? `${item.label ?? item.name}, slot ${index}` : `Empty slot ${index}`}
        onClick={() => onSelect(item)}
        onDoubleClick={() => item && onUse(inventory, item)}
        onDragStart={(event) => item && event.dataTransfer.setData("application/qbinventory-slot", JSON.stringify({ inventory: inventory.id, slot: item.slot }))}
        onDragOver={(event) => event.preventDefault()}
        onDrop={(event) => {
            event.preventDefault()
            const raw = event.dataTransfer.getData("application/qbinventory-slot")
            try {
                const source = JSON.parse(raw) as { inventory: string; slot: number }
                if (source.inventory === inventory.id && source.slot === index) return
                onMove({ ...inventory, id: source.inventory }, source.slot, inventory, index)
            } catch { /* only native drops are ignored */ }
        }}
    >
        <span className="slot-number">{index}</span>
        {item && <>
            <span className="item-art" aria-hidden="true">{(item.label ?? item.name).slice(0, 1)}</span>
            <span className="item-label">{item.label ?? item.name}</span>
            <span className="item-amount">×{item.amount}</span>
            {typeof item.durability === "number" && <span className="durability"><i style={{ width: `${Math.max(0, Math.min(100, item.durability))}%` }} /></span>}
        </>}
    </button>
}

function InventoryPanel({ inventory, selected, onSelect, onMove, onUse }: {
    inventory: InventoryView; selected?: InventoryItem; onSelect: (item?: InventoryItem) => void; onMove: SlotProps["onMove"]; onUse: SlotProps["onUse"]
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
            {Array.from({ length: inventory.slots }, (_, offset) => <InventorySlot key={offset + 1} index={offset + 1} item={bySlot.get(offset + 1)} inventory={inventory} selected={selected?.slot === offset + 1} onSelect={onSelect} onMove={onMove} onUse={onUse} />)}
        </div>
    </section>
}

function App() {
    const [session, setSession] = useState<SessionSnapshot | null>(null)
    const [selected, setSelected] = useState<InventoryItem | undefined>()
    const [query, setQuery] = useState("")
    const [error, setError] = useState<string>()

    useNuiEvent<ThemeTokens>("qbinventory:nui:theme", (tokens) => {
        for (const [key, value] of Object.entries(tokens ?? {})) document.documentElement.style.setProperty(`--${key}`, value)
    })
    useNuiEvent<SessionSnapshot>("qbinventory:nui:sessionOpened", (snapshot) => { setSession(snapshot); setSelected(undefined); setError(undefined) })
    useNuiEvent<SessionPatch>("qbinventory:nui:sessionPatched", (patch) => setSession((current) => current && current.sessionId === patch.sessionId ? applyPatch(current, patch) : current))
    useNuiEvent<{ sessionId: string; reason?: string }>("qbinventory:nui:sessionClosed", ({ sessionId }) => setSession((current) => current?.sessionId === sessionId ? null : current))

    const submit = useCallback(async (intent: Parameters<typeof sendIntent>[0]["intent"], payload: Record<string, unknown> = {}) => {
        if (!session) return
        try {
            const response = await sendIntent({ sessionId: session.sessionId, token: session.token, intent, payload })
            if (!response.ok) setError(response.error ?? "Action rejected by inventory")
        } catch { setError("Inventory connection interrupted") }
    }, [session])

    const move = useCallback((from: InventoryView, fromSlot: number, to: InventoryView, toSlot: number) => submit("move", { fromInventory: from.id, fromSlot, toInventory: to.id, toSlot, revision: session?.revision, secondaryRevision: session?.secondaryRevision }), [session, submit])
    const use = useCallback((inventory: InventoryView, item: InventoryItem) => submit("use", { inventory: inventory.id, slot: item.slot, revision: session?.revision }), [session, submit])
    const close = useCallback(() => { if (session) void closeSession(session.sessionId, session.token) }, [session])

    useEffect(() => {
        const onKey = (event: KeyboardEvent) => {
            if (event.key === "Escape") close()
            if (event.key === "Enter" && selected) void submit("use", { inventory: session?.player.id, slot: selected.slot })
        }
        window.addEventListener("keydown", onKey)
        return () => window.removeEventListener("keydown", onKey)
    }, [close, selected, session, submit])

    const filteredSelected = useMemo(() => selected && (selected.label ?? selected.name).toLowerCase().includes(query.toLowerCase()) ? selected : undefined, [query, selected])
    if (!session) return import.meta.env.DEV ? <button className="dev-launch" onClick={openDevHarness}>Open inventory UI harness</button> : null

    return <main className="inventory-shell">
        <header className="inventory-topbar"><div className="brand"><PackageOpen size={20} /><span>INVENTORY</span><em>LIVE</em></div><label className="search"><Search size={16} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search selected item" /></label><button className="close" onClick={close} aria-label="Close inventory"><X size={20} /></button></header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
        <div className="inventory-layout">
            <InventoryPanel inventory={session.player} selected={selected} onSelect={setSelected} onMove={move} onUse={use} />
            <aside className="item-detail">{filteredSelected ? <><div className="detail-art">{(filteredSelected.label ?? filteredSelected.name).slice(0, 1)}</div><p className="eyebrow">slot {filteredSelected.slot}</p><h1>{filteredSelected.label ?? filteredSelected.name}</h1><p>{filteredSelected.description ?? "No item description available."}</p><dl><dt>Amount</dt><dd>×{filteredSelected.amount}</dd><dt>Weight</dt><dd>{filteredSelected.weight ?? 0} g</dd></dl><button className="primary-action" onClick={() => void use(session.player, filteredSelected)}>Use item</button><button className="quiet-action" onClick={() => void submit("drop", { inventory: session.player.id, slot: filteredSelected.slot, amount: 1 })}>Drop one</button></> : <div className="empty-detail"><PackageOpen size={30} /><h1>Item details</h1><p>Select an item to inspect it, then use, move, or drop it.</p></div>}</aside>
            {session.secondary ? <InventoryPanel inventory={session.secondary} selected={selected} onSelect={setSelected} onMove={move} onUse={use} /> : <section className="inventory-panel secondary-empty"><PackageOpen size={28} /><h2>No secondary inventory</h2><p>Open a stash, shop, container, or another player to use this panel.</p></section>}
        </div>
        <footer className="shortcut-bar"><span><kbd>Esc</kbd> Close</span><span><kbd>↵</kbd> Use selected</span><span><kbd>Drag</kbd> Move or stack</span><span>Revision {session.revision ?? 0}</span></footer>
    </main>
}

export default App
