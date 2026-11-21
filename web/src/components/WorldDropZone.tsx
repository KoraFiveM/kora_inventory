import { useDragLayer, useDrop } from "react-dnd"
import type { DragSlot } from "@/lib/inventory"
import { useLocale } from "@/lib/locales"
import type { SessionSnapshot } from "@/lib/types"
import { SLOT_DRAG_TYPE } from "./dnd"

/** Dragging a stack out of the window drops it in the world. The zone is only
 * mounted while a drag is running, so it never captures a click, and it sits
 * behind the shell (z-index) so a slot under the cursor always wins the drop.
 * `didDrop()` is belt-and-braces for the same reason. */
export function WorldDropZone({ session, busy, onDropOut }: { session: SessionSnapshot; busy: boolean; onDropOut: (source: DragSlot) => void }) {
    const t = useLocale()
    // Only inventory slot drags can hit the floor (a trade offer dragged away is withdrawn, not dropped).
    const dragging = useDragLayer((monitor) => monitor.isDragging() && monitor.getItemType() === SLOT_DRAG_TYPE)
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
        <p className={`world-drop-hint${armed ? " world-drop-hint-armed" : ""}`} role="status">{canDrop ? (armed ? t("ui.release_to_drop") : t("ui.drag_out_to_drop")) : busy ? t("ui.updating_inventory") : t("ui.cannot_drop")}</p>
    </>
}
