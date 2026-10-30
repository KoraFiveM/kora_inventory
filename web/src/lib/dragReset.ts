/**
 * Ends a drag that the DnD backend never saw finish.
 *
 * CEF does not deliver a mouseup that happens outside the NUI (or after focus
 * moved to the game), so react-dnd keeps `isDragging` true and the slot stays
 * locked. The backend only listens for mouseup/Escape on the document, so this
 * covers the cases it cannot see. `cancel` must end the drag WITHOUT dropping.
 */
export function watchDragRelease(target: Window, isDragging: () => boolean, cancel: () => void) {
    const cancelIfDragging = () => { if (isDragging()) cancel() }

    // A mousemove with no button held means the release happened somewhere we
    // were not listening.
    const onMouseMove = (event: MouseEvent) => { if (event.buttons === 0) cancelIfDragging() }
    const onKeyDown = (event: KeyboardEvent) => { if (event.key === "Escape") cancelIfDragging() }
    const onVisibility = () => { if (target.document.visibilityState === "hidden") cancelIfDragging() }

    target.addEventListener("mouseup", cancelIfDragging)
    target.addEventListener("mousemove", onMouseMove)
    target.addEventListener("dragend", cancelIfDragging)
    target.addEventListener("blur", cancelIfDragging)
    target.addEventListener("keydown", onKeyDown)
    target.document.addEventListener("visibilitychange", onVisibility)

    return () => {
        target.removeEventListener("mouseup", cancelIfDragging)
        target.removeEventListener("mousemove", onMouseMove)
        target.removeEventListener("dragend", cancelIfDragging)
        target.removeEventListener("blur", cancelIfDragging)
        target.removeEventListener("keydown", onKeyDown)
        target.document.removeEventListener("visibilitychange", onVisibility)
    }
}
