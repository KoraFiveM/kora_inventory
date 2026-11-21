export type QuickAmountKey = "1" | "5" | "10" | "half" | "all"
export interface QuickAmount { key: QuickAmountKey; value: number }

/** Preset amounts no larger than the stack, deduplicated by value and ascending. */
export function quickAmounts(max: number): QuickAmount[] {
    const stack = Math.floor(max)
    if (!(stack >= 1)) return []
    const candidates: QuickAmount[] = [
        { key: "1", value: 1 }, { key: "5", value: 5 }, { key: "10", value: 10 },
        { key: "half", value: Math.max(1, Math.floor(stack / 2)) }, { key: "all", value: stack },
    ]
    const seen = new Set<number>()
    return candidates
        .filter((entry) => entry.value <= stack)
        .sort((a, b) => a.value - b.value)
        .filter((entry) => !seen.has(entry.value) && seen.add(entry.value))
}
