/** Parses the amount typed into the split dialog. Returns an error message instead of throwing. */
export function parseSplitAmount(raw: string, stack: number): { amount: number } | { error: string } {
    const max = Math.floor(stack) - 1
    const text = raw.trim()
    const amount = text === "" ? NaN : Number(text)
    if (!Number.isInteger(amount) || amount < 1 || amount > max) return { error: `Choose an amount from 1 to ${max}` }
    return { amount }
}
