import { describe, expect, it } from "vitest"
import { auditPlayer, emptyAuditFilter, formatAuditTime, sliceOmnipack } from "./audit"
import type { InventoryItem } from "./types"

const item = (slot: number, name: string, label?: string): InventoryItem => ({ slot, name, label, amount: 9999 })

describe("audit filter", () => {
    it("defaults to the last 24 hours and page 0", () => {
        expect(emptyAuditFilter()).toEqual({ player: "", item: "", resource: "", range: "24h", page: 0 })
    })
    it("keeps known ranges and drops unknown ones", () => {
        expect(emptyAuditFilter({ range: "7d", item: "bread" })).toMatchObject({ range: "7d", item: "bread" })
        expect(emptyAuditFilter({ range: "99y" as never }).range).toBe("24h")
    })
})

describe("audit display", () => {
    it("names the player by citizen and server id", () => {
        expect(auditPlayer({ at: 1, action: "add", citizenid: "ABC123", source: 7 })).toBe("ABC123 (#7)")
        expect(auditPlayer({ at: 1, action: "add", source: 7 })).toBe("#7")
        expect(auditPlayer({ at: 1, action: "add" })).toBe("—")
    })
    it("shows a clock for today and a date for older rows", () => {
        const now = new Date(2026, 10, 21, 15, 0, 0).getTime()
        expect(formatAuditTime(new Date(2026, 10, 21, 14, 3, 22).getTime() / 1000, now)).toBe("14:03:22")
        expect(formatAuditTime(new Date(2026, 10, 20, 9, 5, 0).getTime() / 1000, now)).toBe("20 Nov 09:05")
    })
})

describe("omnipack slice", () => {
    const items = [item(1, "bandage", "Bandage"), item(2, "bread", "Bread"), item(3, "weapon_pistol", "Pistol")]
    it("returns everything up to the limit without a query", () => {
        expect(sliceOmnipack(items, "", 2)).toMatchObject({ total: 3, remaining: 1 })
    })
    it("searches name and label across the whole list, keeping real slots", () => {
        const slice = sliceOmnipack(items, "PIS", 10)
        expect(slice.shown.map((entry) => entry.slot)).toEqual([3])
        expect(slice.remaining).toBe(0)
    })
    it("reports no matches", () => {
        expect(sliceOmnipack(items, "zzz", 10)).toEqual({ shown: [], total: 0, remaining: 0 })
    })
})
