export type WeightLevel = "ok" | "warn" | "danger"

export function weightLevel(weight: number, maxWeight: number, warnAt: number, dangerAt: number): WeightLevel {
    if (!(maxWeight > 0) || !Number.isFinite(weight)) return "ok"
    const ratio = weight / maxWeight
    if (ratio >= dangerAt) return "danger"
    if (ratio >= warnAt) return "warn"
    return "ok"
}
