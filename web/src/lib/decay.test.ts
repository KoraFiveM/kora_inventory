import { describe, expect, it } from "vitest"
import { DANGER_BELOW, DEFAULT_DECAY, decayLabel, decayLevel, formatDuration, mergeDecayConfig, slotDecay } from "./decay"

const t = (key: string, values: Record<string, string | number> = {}) => ({
    "ui.decay_expires_in": `Expires in ${values.time}`,
    "ui.decay_spoiled": "Spoiled",
}[key] ?? key)

describe("formatDuration", () => {
    it("uses at most two units, largest first", () => {
        expect(formatDuration(4800)).toBe("1h 20m")
        expect(formatDuration(2 * 86400 + 4 * 3600 + 59)).toBe("2d 4h")
        expect(formatDuration(86400 + 59)).toBe("1d 59s")
    })
    it("drops zero units", () => {
        expect(formatDuration(2700)).toBe("45m")
        expect(formatDuration(3600)).toBe("1h")
        expect(formatDuration(30)).toBe("30s")
    })
    it("floors fractions and reads anything under a second as 0s", () => {
        expect(formatDuration(59.9)).toBe("59s")
        expect(formatDuration(0.4)).toBe("0s")
        expect(formatDuration(0)).toBe("0s")
        expect(formatDuration(-10)).toBe("0s")
        expect(formatDuration(Number.NaN)).toBe("0s")
        expect(formatDuration(Number.POSITIVE_INFINITY)).toBe("0s")
    })
})

describe("decayLevel", () => {
    it("is ok above the warning threshold", () => {
        expect(decayLevel(1, 0.25)).toBe("ok")
        expect(decayLevel(0.25, 0.25)).toBe("ok")
    })
    it("warns below the threshold and is destructive below 10%", () => {
        expect(decayLevel(0.24, 0.25)).toBe("warn")
        expect(decayLevel(DANGER_BELOW, 0.25)).toBe("warn")
        expect(decayLevel(DANGER_BELOW - 0.001, 0.25)).toBe("danger")
        expect(decayLevel(0, 0.25)).toBe("danger")
    })
    it("stays destructive under 10% even with a tiny threshold, and never warns with a zero one", () => {
        expect(decayLevel(0.05, 0.02)).toBe("danger")
        expect(decayLevel(0.5, 0)).toBe("ok")
    })
    it("treats a non-finite fraction as the worst case", () => {
        expect(decayLevel(Number.NaN, 0.25)).toBe("danger")
    })
})

describe("decayLabel", () => {
    it("reads as Expires in <time>", () => {
        expect(decayLabel(4800, t)).toBe("Expires in 1h 20m")
    })
    it("reads Spoiled once nothing is left", () => {
        expect(decayLabel(0, t)).toBe("Spoiled")
        expect(decayLabel(0.5, t)).toBe("Spoiled")
        expect(decayLabel(Number.NaN, t)).toBe("Spoiled")
    })
})

describe("slotDecay", () => {
    const on = { enabled: true, showOnSlot: true, warnBelow: 0.25 }
    const item = (remaining: number, fraction: number) => ({ decay: { remaining, fraction } })
    it("draws nothing for items without a decay field", () => {
        expect(slotDecay({}, on, t)).toBeUndefined()
        expect(slotDecay(undefined, on, t)).toBeUndefined()
    })
    it("draws nothing while the feature or the slot bar is off", () => {
        expect(slotDecay(item(100, 0.5), { ...on, enabled: false }, t)).toBeUndefined()
        expect(slotDecay(item(100, 0.5), { ...on, showOnSlot: false }, t)).toBeUndefined()
        expect(slotDecay(item(100, 0.5), DEFAULT_DECAY, t)).toBeUndefined()
    })
    it("returns the fraction, level and tooltip text", () => {
        expect(slotDecay(item(4800, 0.5), on, t)).toEqual({ fraction: 0.5, level: "ok", label: "Expires in 1h 20m" })
        expect(slotDecay(item(600, 0.2), on, t)).toMatchObject({ level: "warn" })
        expect(slotDecay(item(60, 0.05), on, t)).toMatchObject({ level: "danger" })
    })
    it("clamps an out-of-range fraction and ignores malformed fields", () => {
        expect(slotDecay(item(10, 5), on, t)?.fraction).toBe(1)
        expect(slotDecay(item(10, -1), on, t)?.fraction).toBe(0)
        expect(slotDecay({ decay: { remaining: Number.NaN, fraction: 0.5 } }, on, t)).toBeUndefined()
        expect(slotDecay({ decay: "x" as never }, on, t)).toBeUndefined()
    })
})

describe("mergeDecayConfig", () => {
    it("overlays valid pushed values", () => {
        expect(mergeDecayConfig(DEFAULT_DECAY, { enabled: true, showOnSlot: false, warnBelow: 0.4 })).toEqual({ enabled: true, showOnSlot: false, warnBelow: 0.4 })
    })
    it("keeps the current value for anything missing or malformed", () => {
        expect(mergeDecayConfig(DEFAULT_DECAY, undefined)).toBe(DEFAULT_DECAY)
        expect(mergeDecayConfig(DEFAULT_DECAY, { enabled: "yes" as never, warnBelow: Number.NaN })).toEqual(DEFAULT_DECAY)
    })
    it("clamps the warning threshold to 0..1", () => {
        expect(mergeDecayConfig(DEFAULT_DECAY, { warnBelow: 7 }).warnBelow).toBe(1)
        expect(mergeDecayConfig(DEFAULT_DECAY, { warnBelow: -1 }).warnBelow).toBe(0)
    })
})
