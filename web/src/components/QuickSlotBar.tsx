import { ChevronLeft, ChevronRight, Pin } from "lucide-react"
import { useCallback, useMemo, useRef, useState, type ReactNode } from "react"
import { useDrag, useDrop } from "react-dnd"
import { useLocale } from "@/lib/locales"
import type { DragSlot, Selection } from "@/lib/inventory"
import { buildQuickTiles, tileCount, type QuickSlotsState, type QuickTile } from "@/lib/quickSlots"
import type { InventoryItem, InventoryView } from "@/lib/types"
import { ItemArtwork } from "./ItemArtwork"
import { SLOT_DRAG_TYPE } from "./dnd"

export type QuickSlotPosition = "side" | "top" | "bottom" | "drawer" | "panel"
export type QuickSlotSide = "left" | "right"

/** localStorage key of the player's own drawer choice; it wins over `quickSlots.drawer.startCollapsed`. */
const DRAWER_COLLAPSED_KEY = "kora_inventory:quickDrawerCollapsed"

function readCollapsed(fallback: boolean): boolean {
    try {
        const stored = window.localStorage.getItem(DRAWER_COLLAPSED_KEY)
        if (stored === "1") return true
        if (stored === "0") return false
    } catch { /* storage can be unavailable in the NUI; the config default applies */ }
    return fallback
}

function writeCollapsed(collapsed: boolean) {
    try { window.localStorage.setItem(DRAWER_COLLAPSED_KEY, collapsed ? "1" : "0") } catch { /* not persisted */ }
}

export interface QuickSlotBarProps {
    position: QuickSlotPosition
    /** Drawer only: the edge of the window it prefers. Defaults to the left edge. */
    side?: QuickSlotSide
    /** Drawer only: the window had no room on `side`, so the drawer sits on the opposite edge. */
    flipped?: boolean
    state: QuickSlotsState
    /** The player's own inventory: every tile points at one of its real slots. */
    player: InventoryView
    busy: boolean
    selected?: Selection
    onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void
    onActivate: (inventory: InventoryView, item: InventoryItem) => void
    /** Pin a quick slot to a real player slot, or unpin it with `null`. */
    onPin: (id: string, slot: number | null) => void
    /** Pulse the real slot in the grid. */
    onFlash: (slot: number) => void
}

/** A player slot can be pinned to a tile unless the tile is linked (ammo) or the window is busy. */
function canPinTo(tile: Pick<QuickTile, "linked">, source: DragSlot | undefined, playerId: string, busy: boolean): boolean {
    return Boolean(source) && !busy && !tile.linked && source!.inventoryId === playerId
}

type TileProps = Pick<QuickSlotBarProps, "player" | "busy" | "onSelect" | "onActivate" | "onPin" | "onFlash"> & {
    tile: QuickTile
    showKeyHints: boolean
    selected: boolean
    /** A square tile (strip, drawer) or a full-width row (loadout panel). */
    variant?: "tile" | "row"
}

/** The right-hand figure of a panel row: ammo magazines, rounds loaded in the weapon, or the stack amount. */
function rowFigures(tile: QuickTile, t: (key: string, params?: Record<string, string | number>) => string): string[] {
    const figures: string[] = []
    if (tile.total !== null) figures.push(t("ui.quick_slot_mags", { count: tile.total }))
    else if (tile.item && tile.item.amount > 1) figures.push(`×${tile.item.amount}`)
    const loaded = tile.item?.ammo?.loaded
    if (typeof loaded === "number" && Number.isFinite(loaded)) figures.push(t("ui.quick_slot_loaded", { count: loaded }))
    return figures
}

function QuickTileView({ tile, player, busy, selected, showKeyHints, variant = "tile", onSelect, onActivate, onPin, onFlash }: TileProps) {
    const t = useLocale()
    const { item, slot } = tile
    const suppressClick = useRef(false)
    const [{ isDragging }, dragRef] = useDrag<DragSlot, unknown, { isDragging: boolean }>(() => ({
        type: SLOT_DRAG_TYPE,
        // Dragging a tile drags the real item: it lands on a grid slot, or outside the window, as a normal move/drop.
        item: { inventoryId: player.id, slot: slot ?? 0 },
        canDrag: Boolean(item) && slot !== null && !busy,
        end: () => { suppressClick.current = true },
        collect: (monitor) => ({ isDragging: monitor.isDragging() }),
    }), [busy, item, player.id, slot])
    const [{ isOver, canDrop }, dropRef] = useDrop<DragSlot, { quickSlot: string }, { isOver: boolean; canDrop: boolean }>(() => ({
        accept: SLOT_DRAG_TYPE,
        canDrop: (source) => canPinTo(tile, source, player.id, busy),
        drop: (source) => {
            if (!canPinTo(tile, source, player.id, busy)) return undefined
            onPin(tile.id, source.slot)
            // Returning a result marks the drop handled, so it is not also a drop on the ground.
            return { quickSlot: tile.id }
        },
        collect: (monitor) => ({ isOver: monitor.isOver({ shallow: true }), canDrop: monitor.canDrop() }),
    }), [busy, onPin, player.id, tile])
    const setRef = useCallback((node: HTMLButtonElement | null) => { dragRef(node); dropRef(node) }, [dragRef, dropRef])

    const count = tileCount(tile)
    const name = item ? (item.label ?? item.name) : undefined
    const row = variant === "row"
    const classes = [
        "quickslot", row && "quickslot-row", item ? "quickslot-filled" : "quickslot-empty", selected && "quickslot-selected",
        tile.pinned && "quickslot-pinned", isDragging && "quickslot-drag-source",
        isOver && canDrop && "quickslot-drop-target", isOver && !canDrop && "quickslot-drop-invalid",
    ].filter(Boolean).join(" ")

    return <button
        ref={setRef}
        type="button"
        className={classes}
        data-quickslot={tile.id}
        aria-label={name && slot !== null ? t("ui.quick_slot_item", { slot: tile.label, item: name, inventory: slot }) : t("ui.quick_slot_empty", { slot: tile.label })}
        aria-pressed={selected || undefined}
        aria-disabled={busy || !item || undefined}
        title={tile.pinned ? `${tile.label} · ${t("ui.quick_slot_unpin")}` : tile.label}
        onMouseDown={() => { suppressClick.current = false }}
        onClick={() => {
            if (suppressClick.current) { suppressClick.current = false; return }
            if (busy || !item || slot === null) return
            onSelect(player, item, slot)
            onFlash(slot)
        }}
        onDoubleClick={() => { if (!busy && item) onActivate(player, item) }}
        onContextMenu={(event) => {
            event.preventDefault()
            if (!busy && tile.pinned) onPin(tile.id, null)
        }}
    >
        {item ? <ItemArtwork item={item} className="quickslot-art" /> : <span className="quickslot-art quickslot-art-empty" aria-hidden="true" />}
        {row ? <>
            <span className="quickslot-row-text">
                <span className="quickslot-row-eyebrow">{tile.label}{tile.pinned && <Pin className="quickslot-pin-inline" size={9} aria-label={t("ui.quick_slot_pinned")} />}</span>
                <span className="quickslot-row-name">{name ?? "—"}</span>
            </span>
            <span className="quickslot-row-meta">
                {rowFigures(tile, t).map((figure) => <span key={figure} className="quickslot-row-figure">{figure}</span>)}
                {showKeyHints && tile.key !== "" && <kbd className="quickslot-key quickslot-key-row">{tile.key}</kbd>}
            </span>
        </> : <>
            <span className="quickslot-label">{tile.label}</span>
            {count !== undefined && <span className="quickslot-count">×{count}</span>}
            {showKeyHints && tile.key !== "" && <kbd className="quickslot-key">{tile.key}</kbd>}
            {tile.pinned && <Pin className="quickslot-pin" size={10} aria-label={t("ui.quick_slot_pinned")} />}
        </>}
    </button>
}

/** The drawer on the window's edge: tiles stacked vertically plus a handle that folds it into a slim strip. */
function QuickDrawer({ side, flipped, startCollapsed, label, busy, children }: {
    side: QuickSlotSide
    flipped: boolean
    startCollapsed: boolean
    label: string
    busy: boolean
    children: ReactNode
}) {
    const t = useLocale()
    const [collapsed, setCollapsed] = useState(() => readCollapsed(startCollapsed))
    const actual: QuickSlotSide = flipped ? (side === "left" ? "right" : "left") : side
    const toggle = () => setCollapsed((current) => { writeCollapsed(!current); return !current })
    // The chevron points where the drawer will move: towards the window to fold it, away from it to pull it out.
    const towardsWindow = actual === "left" ? ChevronRight : ChevronLeft
    const awayFromWindow = actual === "left" ? ChevronLeft : ChevronRight
    const Chevron = collapsed ? awayFromWindow : towardsWindow
    const action = t(collapsed ? "ui.quick_drawer_expand" : "ui.quick_drawer_collapse")
    return <div
        className={`quickslot-drawer quickslot-drawer-${actual}${collapsed ? " quickslot-drawer-collapsed" : ""}`}
        data-side={actual}
        data-preferred-side={side}
        data-collapsed={collapsed}
    >
        <button type="button" className="quickslot-drawer-handle" aria-expanded={!collapsed} aria-controls="quickslot-drawer-body" aria-label={action} title={action} onClick={toggle}>
            <Chevron size={12} aria-hidden="true" />
        </button>
        <div id="quickslot-drawer-body" className="quickslot-drawer-body" role="group" aria-label={label} aria-busy={busy || undefined}>
            <div className="quickslot-bar quickslot-bar-drawer">{children}</div>
        </div>
    </div>
}

/**
 * Shortcuts to real inventory items, drawn beside the player panel. A tile is
 * never a slot of its own: it points at the player's real slot and acts on that.
 * Renders nothing at all when there is nothing to show.
 *
 * Presentations: `drawer` (vertical drawer on the window's edge), `panel`
 * (full-width rows, the loadout column) and the older `side` / `top` / `bottom`
 * strips.
 */
export function QuickSlotBar({ position, side = "left", flipped = false, state, player, busy, selected, onSelect, onActivate, onPin, onFlash }: QuickSlotBarProps) {
    const t = useLocale()
    const tiles = useMemo(() => buildQuickTiles(state, player), [player, state])
    if (tiles.length === 0) return null
    const variant = position === "panel" ? "row" : "tile"
    const views = tiles.map((tile) => <QuickTileView
        key={tile.id}
        tile={tile}
        variant={variant}
        player={player}
        busy={busy}
        showKeyHints={state.showKeyHints}
        selected={tile.slot !== null && selected?.inventory.id === player.id && selected.item.slot === tile.slot}
        onSelect={onSelect}
        onActivate={onActivate}
        onPin={onPin}
        onFlash={onFlash}
    />)
    if (position === "drawer") return <QuickDrawer side={side} flipped={flipped} startCollapsed={state.drawer.startCollapsed} label={t("ui.quick_slots")} busy={busy}>{views}</QuickDrawer>
    if (position === "panel") return <section className="quickslot-panel" aria-label={t("ui.loadout")} aria-busy={busy || undefined}>
        <header className="quickslot-panel-header"><p className="eyebrow">{t("ui.quick_slots")}</p><h2>{t("ui.loadout")}</h2></header>
        <div className="quickslot-rows" role="group" aria-label={t("ui.quick_slots")}>{views}</div>
    </section>
    return <div className={`quickslot-bar quickslot-bar-${position}`} role="group" aria-label={t("ui.quick_slots")} aria-busy={busy || undefined}>{views}</div>
}
