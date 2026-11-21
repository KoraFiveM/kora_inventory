import { useEffect } from "react"
import { useDragDropManager } from "react-dnd"
import { watchDragRelease } from "@/lib/dragReset"

/** Ends a drag the backend missed (release outside the window, focus loss,
 * Escape) and when the inventory closes mid-drag. Renders nothing. */
export function DragGuard({ open }: { open: boolean }) {
    const manager = useDragDropManager()
    useEffect(() => {
        const monitor = manager.getMonitor()
        const cancel = () => manager.getActions().endDrag()
        if (!open && monitor.isDragging()) cancel()
        return watchDragRelease(window, () => monitor.isDragging(), cancel)
    }, [manager, open])
    return null
}
