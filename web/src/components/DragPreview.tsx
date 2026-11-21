import { createPortal } from "react-dom"
import { useDragLayer } from "react-dnd"
import { findInventory, findItem, type DragSlot } from "@/lib/inventory"
import type { SessionSnapshot } from "@/lib/types"
import { DurabilityBar } from "./DurabilityBar"
import { ItemArtwork } from "./ItemArtwork"

export function DragPreview({ session }: { session: SessionSnapshot | null }) {
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
        {typeof draggedItem.durability === "number" && <DurabilityBar value={draggedItem.durability} />}
    </div>, document.body)
}
