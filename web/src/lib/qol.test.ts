import { describe, expect, it } from "vitest"
import { classifyItem, isDimmed } from "./categories"
import { modifierDragAmount } from "./modifierDrag"
import { quickAmounts } from "./quickAmounts"
import { pickTransferSlot } from "./quickTransfer"
import { weightLevel } from "./weightLevel"
import type { InventoryView } from "./types"

const inv = (items: InventoryView["items"], slots = 4, type = "stash"): InventoryView => ({ id: "x", type, slots, items })

describe("categories", () => {
    it("classifies", () => {
        expect(classifyItem({ name: "weapon_pistol" })).toBe("weapons")
        expect(classifyItem({ name: "thing", ammo: 3 })).toBe("weapons")
        expect(classifyItem({ name: "thing", type: "weapon" })).toBe("weapons")
        expect(classifyItem({ name: "pistol_ammo", ammoType: "AMMO_PISTOL" })).toBe("ammo")
        expect(classifyItem({ name: "bandage", useable: true })).toBe("consumables")
        expect(classifyItem({ name: "rock" })).toBe("other")
    })
    it("dims by filter and query without touching empty slots", () => {
        expect(isDimmed(undefined, "weapons", "zzz")).toBe(false)
        expect(isDimmed({ name: "rock" }, "weapons", "")).toBe(true)
        expect(isDimmed({ name: "rock", label: "Rock" }, "all", "ro")).toBe(false)
        expect(isDimmed({ name: "rock", label: "Rock" }, "all", "zz")).toBe(true)
    })
})

describe("pickTransferSlot", () => {
    const item = { slot: 1, name: "water", amount: 2 }
    it("prefers a stackable stack, else first empty", () => {
        expect(pickTransferSlot(inv([{ slot: 1, name: "a", amount: 1 }, { slot: 3, name: "water", amount: 1 }]), item)).toBe(3)
        expect(pickTransferSlot(inv([{ slot: 1, name: "a", amount: 1 }]), item)).toBe(2)
    })
    it("skips unique stacks and full inventories and shops", () => {
        expect(pickTransferSlot(inv([{ slot: 1, name: "water", amount: 1, unique: true }]), item)).toBe(2)
        expect(pickTransferSlot(inv([{ slot: 1, name: "a", amount: 1 }], 1), item)).toBeUndefined()
        expect(pickTransferSlot(inv([], 4, "shop"), item)).toBeUndefined()
    })
})

describe("modifierDragAmount", () => {
    it("ctrl halves, alt is one, none is normal", () => {
        expect(modifierDragAmount({ ctrl: true }, 9)).toBe(4)
        expect(modifierDragAmount({ ctrl: true }, 1)).toBe(1)
        expect(modifierDragAmount({ alt: true }, 9)).toBe(1)
        expect(modifierDragAmount({ ctrl: true, alt: true }, 9)).toBe(1)
        expect(modifierDragAmount({}, 9)).toBeUndefined()
    })
})

describe("quickAmounts", () => {
    it("lists only amounts within the stack, deduped", () => {
        expect(quickAmounts(100).map((a) => a.value)).toEqual([1, 5, 10, 50, 100])
        expect(quickAmounts(8).map((a) => a.key)).toEqual(["1", "half", "5", "all"])
        expect(quickAmounts(2).map((a) => a.value)).toEqual([1, 2])
        expect(quickAmounts(10).map((a) => a.value)).toEqual([1, 5, 10])
        expect(quickAmounts(0)).toEqual([])
    })
})

describe("weightLevel", () => {
    it("thresholds", () => {
        expect(weightLevel(70, 100, 0.75, 0.95)).toBe("ok")
        expect(weightLevel(75, 100, 0.75, 0.95)).toBe("warn")
        expect(weightLevel(95, 100, 0.75, 0.95)).toBe("danger")
        expect(weightLevel(5, 0, 0.75, 0.95)).toBe("ok")
    })
})
