import { Pin } from "lucide-react"
import { useCallback, useMemo, useRef } from "react"
import { useDrag, useDrop } from "react-dnd"
import { useLocale } from "@/lib/locales"
import type { DragSlot, Selection } from "@/lib/inventory"
import { buildQuickTiles, tileCount, type QuickSlotsState, type QuickTile } from "@/lib/quickSlots"
import type { InventoryItem, InventoryView } from "@/lib/types"
import { ItemArtwork } from "./ItemArtwork"
import { SLOT_DRAG_TYPE } from "./dnd"

export type QuickSlotPosition = "side" | "top" | "bottom"

export interface QuickSlotBarProps {
    position: QuickSlotPosition
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
export function canPinTo(tile: Pick<QuickTile, "linked">, source: DragSlot | undefined, playerId: string, busy: boolean): boolean {
    return Boolean(source) && !busy && !tile.linked && source!.inventoryId === playerId
}

type TileProps = Pick<QuickSlotBarProps, "player" | "busy" | "onSelect" | "onActivate" | "onPin" | "onFlash"> & {
    tile: QuickTile
    showKeyHints: boolean
    selected: boolean
}

function QuickTileView({ tile, player, busy, selected, showKeyHints, onSelect, onActivate, onPin, onFlash }: TileProps) {
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
    const classes = [
        "quickslot", item ? "quickslot-filled" : "quickslot-empty", selected && "quickslot-selected",
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
        <span className="quickslot-label">{tile.label}</span>
        {count !== undefined && <span className="quickslot-count">×{count}</span>}
        {showKeyHints && tile.key !== "" && <kbd className="quickslot-key">{tile.key}</kbd>}
        {tile.pinned && <Pin className="quickslot-pin" size={10} aria-label={t("ui.quick_slot_pinned")} />}
    </button>
}

/**
 * Shortcuts to real inventory items, drawn beside the player panel. A tile is
 * never a slot of its own: it points at the player's real slot and acts on that.
 * Renders nothing at all when there is nothing to show.
 */
export function QuickSlotBar({ position, state, player, busy, selected, onSelect, onActivate, onPin, onFlash }: QuickSlotBarProps) {
    const t = useLocale()
    const tiles = useMemo(() => buildQuickTiles(state, player), [player, state])
    if (tiles.length === 0) return null
    return <div className={`quickslot-bar quickslot-bar-${position}`} role="group" aria-label={t("ui.quick_slots")} aria-busy={busy || undefined}>
        {tiles.map((tile) => <QuickTileView
            key={tile.id}
            tile={tile}
            player={player}
            busy={busy}
            showKeyHints={state.showKeyHints}
            selected={tile.slot !== null && selected?.inventory.id === player.id && selected.item.slot === tile.slot}
            onSelect={onSelect}
            onActivate={onActivate}
            onPin={onPin}
            onFlash={onFlash}
        />)}
    </div>
}
