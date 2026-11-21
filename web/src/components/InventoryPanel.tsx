import { useContext, useEffect, useState } from "react"
import { ArrowDownWideNarrow, Layers, Search } from "lucide-react"
import { UiConfigContext } from "@/context"
import { asSlots, type DragSlot, type Selection, type SlotTarget } from "@/lib/inventory"
import type { InventoryItem, InventoryView } from "@/lib/types"
import { CATEGORY_FILTERS, isDimmed, matchesQuery, type CategoryFilter } from "@/lib/categories"
import { useLocale } from "@/lib/locales"
import { weightLevel } from "@/lib/weightLevel"
import { InventorySlot } from "./InventorySlot"

export function InventoryPanel({ inventory, selected, busy, isPlayer, canDropSlot, onDrop, onDragEnd, onSelect, onActivate, onSplit, onQuickTransfer, onOrganize, pending, query }: {
    inventory: InventoryView
    selected?: Selection
    busy: boolean
    canDropSlot: (source: DragSlot, target: SlotTarget) => boolean
    onDrop: (source: DragSlot, target: SlotTarget) => void
    onDragEnd: () => void
    onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void
    onActivate: (inventory: InventoryView, item: InventoryItem) => void
    onSplit: (inventory: InventoryView, item: InventoryItem) => void
    onQuickTransfer?: (inventory: InventoryView, item: InventoryItem) => void
    /** Sort / Stack all for this panel; the server does the work. */
    onOrganize?: (inventory: InventoryView, mode: "sort" | "stack") => void
    /** A request is in flight: the organize buttons wait for it. */
    pending?: boolean
    /** Search text that dims non-matching slots (player panel only). */
    query?: string
    /** True for the player's own inventory -- the only one with a hotbar. */
    isPlayer?: boolean
}) {
    const { hotbarSlots, showHotbar, filters, weightWarnings, organize } = useContext(UiConfigContext)
    const t = useLocale()
    const [category, setCategory] = useState<CategoryFilter>("all")
    // This panel's own search; the top bar's `query` still dims the player panel too.
    const [panelQuery, setPanelQuery] = useState("")
    useEffect(() => setPanelQuery(""), [inventory.id])
    // Shops are read only and are bought from, not tidied.
    const tidy = inventory.type !== "shop"
    const showSearch = organize.panelSearch && tidy
    const showSort = organize.enabled && organize.sort && tidy && Boolean(onOrganize)
    const showStack = organize.enabled && organize.stack && tidy && Boolean(onOrganize)
    const organizeDisabled = busy || Boolean(pending)
    const level = weightWarnings.enabled ? weightLevel(inventory.weight ?? 0, inventory.maxWeight ?? 0, weightWarnings.warnAt, weightWarnings.dangerAt) : "ok"
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
            <div className={`weight${level === "ok" ? "" : ` weight-${level}`}`}><span>{(inventory.weight ?? 0).toLocaleString()} / {(inventory.maxWeight ?? 0).toLocaleString()} g</span><i><b style={{ width: `${percentage}%` }} /></i></div>
            {(showSearch || showSort || showStack) && <div className="panel-tools">
                {showSearch && <label className="panel-search"><Search size={13} aria-hidden="true" /><input type="search" value={panelQuery} onChange={(event) => setPanelQuery(event.target.value)} placeholder={t("ui.panel_search_placeholder")} aria-label={t("ui.panel_search")} title={t("ui.panel_search")} /></label>}
                {showSort && <button type="button" className="panel-tool" title={t("ui.sort_panel")} aria-label={t("ui.sort_panel")} disabled={organizeDisabled} onClick={() => onOrganize?.(inventory, "sort")}><ArrowDownWideNarrow size={15} aria-hidden="true" /></button>}
                {showStack && <button type="button" className="panel-tool" title={t("ui.stack_panel")} aria-label={t("ui.stack_panel")} disabled={organizeDisabled} onClick={() => onOrganize?.(inventory, "stack")}><Layers size={15} aria-hidden="true" /></button>}
            </div>}
        </header>
        {filters && <div className="category-chips" role="group" aria-label={t("ui.filter_items")}>
            {CATEGORY_FILTERS.map((id) => <button key={id} type="button" className={`category-chip${category === id ? " category-chip-active" : ""}`} aria-pressed={category === id} onClick={() => setCategory(id)}>{t(`ui.filter_${id}`)}</button>)}
        </div>}
        <div className="slot-grid">
            {Array.from({ length: inventory.slots }, (_, offset) => {
                const slot = offset + 1
                const item = bySlot.get(slot)
                return <InventorySlot key={slot} index={slot} inventory={inventory} item={item} selected={selected?.inventory.id === inventory.id && selected.item.slot === slot} busy={busy} hotbar={slot <= hotbarCount} lastHotbar={slot === hotbarCount} canDropSlot={canDropSlot} onDrop={onDrop} onDragEnd={onDragEnd} onSelect={(slotItem) => onSelect(inventory, slotItem, slot)} onActivate={(slotItem) => onActivate(inventory, slotItem)} onSplit={onSplit} onQuickTransfer={onQuickTransfer} dimmed={(filters && isDimmed(item, category, query ?? "")) || (showSearch && Boolean(item) && !matchesQuery(item!, panelQuery))} />
            })}
        </div>
    </section>
}
