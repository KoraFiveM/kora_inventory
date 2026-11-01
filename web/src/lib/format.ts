/**
 * Formats a metadata value for the item inspector. Fractional numbers are
 * rounded to `decimals` places (Config.Inspector.decimals) with trailing zeros
 * dropped, so a float-drifted 92.70000000000044 reads as 92.7. Integers and
 * non-numbers are shown as they are.
 */
export function formatMetaValue(value: unknown, decimals: number): string {
    if (typeof value === "object" && value !== null) return JSON.stringify(value)
    if (typeof value !== "number" || !Number.isFinite(value) || Number.isInteger(value)) return String(value)
    const places = Math.max(0, Math.min(3, Math.floor(decimals)))
    const rounded = Number(value.toFixed(places))
    return String(Object.is(rounded, -0) ? 0 : rounded)
}
