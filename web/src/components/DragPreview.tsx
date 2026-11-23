import { createPortal } from "react-dom"
import { useDragLayer } from "react-dnd"
import { gridPlacementSize, hasGrid } from "@/lib/grid"
import { findInventory, findItem, type DragSlot } from "@/lib/inventory"
import { useLocale } from "@/lib/locales"
import type { SessionSnapshot } from "@/lib/types"
import { DurabilityBar } from "./DurabilityBar"
import { ItemArtwork } from "./ItemArtwork"
import { SLOT_DRAG_TYPE } from "./dnd"

export function DragPreview({ session, rotationFor, busy }: {
    session: SessionSnapshot
    rotationFor: (source: DragSlot) => boolean | undefined
    busy: boolean
}) {
    const t = useLocale()
    const { isDragging, item, clientOffset } = useDragLayer((monitor) => ({
        isDragging: monitor.isDragging() && monitor.getItemType() === SLOT_DRAG_TYPE,
        item: monitor.getItem<DragSlot>(),
        clientOffset: monitor.getClientOffset(),
    }))
    if (!isDragging || !item || !clientOffset) return null
    const source = findInventory(session, item.inventoryId)
    const draggedItem = findItem(source, item.slot)
    if (!source || !draggedItem) return null
    const { width, height } = gridPlacementSize(draggedItem, rotationFor(item))
    const canRotate = !busy && hasGrid(session) && source.type !== "shop" && width !== height
    // The NUI root is scaled to provide a consistent layout across game
    // resolutions. Render the preview outside that transformed subtree so the
    // DnD backend's viewport coordinates can be used directly. Keeping the
    // preview in #root makes fixed positioning browser-dependent in CEF and
    // can produce a large horizontal offset at lower resolutions.
    return createPortal(<>
    <div className={`inventory-drag-preview slot slot-filled${hasGrid(session) ? " inventory-drag-preview-grid" : ""}${source.type === "shop" ? " slot-priced" : ""}`} style={{ left: clientOffset.x, top: clientOffset.y }} aria-hidden="true">
        {!source.gridColumns && <span className="slot-number">{draggedItem.slot}</span>}
        <ItemArtwork item={draggedItem} className="item-art" />
        <span className="item-footer">
            <span className="item-label">{draggedItem.label ?? draggedItem.name}</span>
            {source.type === "shop" && typeof draggedItem.price === "number" && <span className="item-price">${draggedItem.price.toLocaleString()}</span>}
        </span>
        <span className="item-amount">×{draggedItem.amount}</span>
        {typeof draggedItem.durability === "number" && <DurabilityBar value={draggedItem.durability} />}
    </div>
    {canRotate && <p className="grid-rotate-hint" role="status" style={{ left: clientOffset.x, top: clientOffset.y }}>{t("ui.grid_rotate_hint", { width, height })}</p>}
    </>, document.body)
}
