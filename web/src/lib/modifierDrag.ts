interface DragModifiers { ctrl?: boolean; alt?: boolean }

/** Ctrl = half the stack (floor, min 1), Alt = one, otherwise undefined (normal drag). */
export function modifierDragAmount(modifiers: DragModifiers | undefined, stack: number): number | undefined {
    const total = Math.max(1, Math.floor(stack))
    if (modifiers?.alt) return 1
    if (modifiers?.ctrl) return Math.max(1, Math.floor(total / 2))
    return undefined
}
