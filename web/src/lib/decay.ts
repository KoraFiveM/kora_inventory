import type { DecayConfig, InventoryItem } from "./types"

/** Mirrors Config.kora_inventory.decay: what renders before the config push arrives. */
export const DEFAULT_DECAY: DecayConfig = { enabled: false, showOnSlot: true, warnBelow: 0.25 }

/** Below this fraction of life left the bar is --destructive whatever `warnBelow` says. */
export const DANGER_BELOW = 0.1

/** Merges a pushed `decay` onto the current value; anything malformed keeps what was there. */
export function mergeDecayConfig(current: DecayConfig, pushed: Partial<DecayConfig> | undefined): DecayConfig {
    if (!pushed || typeof pushed !== "object") return current
    const warn = Number(pushed.warnBelow)
    return {
        enabled: typeof pushed.enabled === "boolean" ? pushed.enabled : current.enabled,
        showOnSlot: typeof pushed.showOnSlot === "boolean" ? pushed.showOnSlot : current.showOnSlot,
        warnBelow: Number.isFinite(warn) ? Math.min(1, Math.max(0, warn)) : current.warnBelow,
    }
}

const UNITS: ReadonlyArray<readonly [number, string]> = [[86400, "d"], [3600, "h"], [60, "m"], [1, "s"]]

/** Short duration text, two units at most: "2d 4h", "1h 20m", "45m", "30s". Mirrors shared/decay.lua's format. */
export function formatDuration(seconds: number): string {
    if (!Number.isFinite(seconds) || seconds < 1) return "0s"
    let left = Math.floor(seconds)
    const parts: string[] = []
    for (const [size, suffix] of UNITS) {
        const count = Math.floor(left / size)
        if (count > 0) {
            parts.push(`${count}${suffix}`)
            left -= count * size
        }
        if (parts.length === 2) break
    }
    return parts.join(" ")
}

export type DecayLevel = "ok" | "warn" | "danger"

/** Bar colour class: --destructive under 10%, --warning under `warnBelow`, otherwise the normal accent. */
export function decayLevel(fraction: number, warnBelow: number): DecayLevel {
    if (!Number.isFinite(fraction)) return "danger"
    if (fraction < DANGER_BELOW) return "danger"
    if (fraction < warnBelow) return "warn"
    return "ok"
}

type Translate = (key: string, values?: Record<string, string | number>) => string

/** "Expires in 1h 20m", or "Spoiled" once nothing is left. The same text the inspector row and bar tooltip show. */
export function decayLabel(remaining: number, t: Translate): string {
    if (!Number.isFinite(remaining) || remaining < 1) return t("ui.decay_spoiled")
    return t("ui.decay_expires_in", { time: formatDuration(remaining) })
}

export interface SlotDecay { fraction: number; level: DecayLevel; label: string }

/** What a slot needs to draw its freshness bar, or undefined when it should draw none. */
export function slotDecay(item: Pick<InventoryItem, "decay"> | undefined, config: DecayConfig, t: Translate): SlotDecay | undefined {
    if (!config.enabled || !config.showOnSlot) return undefined
    const decay = item?.decay
    if (!decay || typeof decay !== "object" || !Number.isFinite(decay.remaining) || !Number.isFinite(decay.fraction)) return undefined
    const fraction = Math.min(1, Math.max(0, decay.fraction))
    return { fraction, level: decayLevel(fraction, config.warnBelow), label: decayLabel(decay.remaining, t) }
}
