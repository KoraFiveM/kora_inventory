/** Amount the Give button sends: the picker value as a whole number, kept within 1..stack. */
export function clampGiveAmount(selected: number, stack: number): number {
    const max = Math.max(1, Math.floor(stack) || 1)
    const wanted = Math.floor(selected)
    return Number.isFinite(wanted) ? Math.min(Math.max(1, wanted), max) : 1
}
