import { useCallback, useContext, useMemo, useRef } from "react"
import { useDrag, useDrop } from "react-dnd"
import { useLocale } from "@/lib/locales"
import { SlotUiContext } from "@/slotUi"
import type { DragSlot, SlotTarget } from "@/lib/inventory"
import type { InventoryItem, InventoryView } from "@/lib/types"
import { ItemArtwork } from "./ItemArtwork"
import { SLOT_DRAG_TYPE } from "./dnd"

export interface SlotProps {
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
export function InventorySlot({ item, index, inventory, selected, busy, hotbar, lastHotbar, canDropSlot, onDrop, onDragEnd, onSelect, onActivate, onSplit }: SlotProps) {
    const t = useLocale()
    const slotUi = useContext(SlotUiContext)
    const flashing = slotUi.flash?.inventoryId === inventory.id && slotUi.flash.slot === index
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
        // Quick slot click: pulse the real slot. The parity class restarts the animation on a repeat.
        flashing && `slot-flash slot-flash-${(slotUi.flash?.nonce ?? 0) % 2}`,
        item && slotUi.isCompatible(item) && "slot-compatible",
        isOver && canDrop && "slot-move-target", isOver && !canDrop && "slot-drop-invalid",
    ].filter(Boolean).join(" ")

    return <button
        ref={setSlotRef}
        className={classes}
        data-fft-kind={inventory.type === "shop" ? "shop-item" : inventory.type === "player" ? "player-slot" : undefined}
        data-fft-item={item?.name}
        aria-label={item ? t("ui.slot_item", { item: item.label ?? item.name, slot: index }) : t("ui.empty_slot", { slot: index })}
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
            // `menu` mode owns right-click; otherwise it stays the split dialog (or nothing).
            if (slotUi.openMenu) slotUi.openMenu({ x: event.clientX, y: event.clientY }, inventory, item)
            else onSplit(inventory, item)
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
