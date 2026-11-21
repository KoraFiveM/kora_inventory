import { describe, expect, it } from "vitest"
import { buildQuickTiles, EMPTY_QUICK_SLOTS, normalizeQuickSlots, tileCount } from "./quickSlots"
import type { InventoryView } from "./types"

const player: InventoryView = {
    id: "player:1", slots: 10, type: "player",
    items: [
        { slot: 2, name: "weapon_pistol", label: "Pistol", amount: 1 },
        { slot: 5, name: "pistol_ammo", label: "Pistol Ammo", amount: 3 },
    ],
}

describe("normalizeQuickSlots", () => {
    it("treats a disabled or malformed message as nothing to show", () => {
        expect(normalizeQuickSlots({ enabled: false })).toBe(EMPTY_QUICK_SLOTS)
        expect(normalizeQuickSlots(undefined)).toBe(EMPTY_QUICK_SLOTS)
        expect(normalizeQuickSlots({ slots: [{ id: "a", label: "A", slot: 1 }] })).toBe(EMPTY_QUICK_SLOTS)
    })
    it("defaults the flags to on and drops bad entries", () => {
        const state = normalizeQuickSlots({ enabled: true, slots: [{ id: "weapon", label: "Weapon", slot: 2 }, { id: "", label: "x", slot: 1 }, null as never, { label: "no id" } as never] })
        expect(state.hideWhenMissing).toBe(true)
        expect(state.showKeyHints).toBe(true)
        expect(state.slots.map((slot) => slot.id)).toEqual(["weapon"])
    })
    it("keeps unresolved slots as null and false flags as false", () => {
        const state = normalizeQuickSlots({ enabled: true, hideWhenMissing: false, showKeyHints: false, slots: [{ id: "a", label: "A", slot: null }, { id: "b", label: "B", slot: 0 }] })
        expect(state.hideWhenMissing).toBe(false)
        expect(state.showKeyHints).toBe(false)
        expect(state.slots.map((slot) => slot.slot)).toEqual([null, null])
    })
})

describe("buildQuickTiles", () => {
    const state = normalizeQuickSlots({
        enabled: true,
        slots: [
            { id: "weapon", label: "Weapon", slot: 2, name: "weapon_pistol", key: "F5", pinned: true },
            { id: "ammo", label: "Ammo", slot: 5, name: "pistol_ammo", total: 36, linked: true },
            { id: "med", label: "Medical", slot: null },
        ],
    })

    it("resolves each tile to the real item and hides unresolved ones", () => {
        const tiles = buildQuickTiles(state, player)
        expect(tiles.map((tile) => tile.id)).toEqual(["weapon", "ammo"])
        expect(tiles[0]).toMatchObject({ slot: 2, pinned: true, key: "F5", linked: false })
        expect(tiles[0].item?.name).toBe("weapon_pistol")
        expect(tiles[1]).toMatchObject({ linked: true, total: 36 })
    })
    it("renders placeholders when hideWhenMissing is off", () => {
        const tiles = buildQuickTiles({ ...state, hideWhenMissing: false }, player)
        expect(tiles.map((tile) => tile.id)).toEqual(["weapon", "ammo", "med"])
        expect(tiles[2]).toMatchObject({ slot: null, item: undefined })
    })
    it("treats a stale slot (empty, or another item) as missing", () => {
        const stale = normalizeQuickSlots({ enabled: true, slots: [{ id: "weapon", label: "Weapon", slot: 7, name: "weapon_pistol" }, { id: "ammo", label: "Ammo", slot: 2, name: "pistol_ammo" }] })
        expect(buildQuickTiles(stale, player)).toEqual([])
    })
    it("is empty when disabled", () => {
        expect(buildQuickTiles(EMPTY_QUICK_SLOTS, player)).toEqual([])
    })
    it("counts the ammo total for linked tiles and the stack otherwise", () => {
        const [weapon, ammo] = buildQuickTiles(state, player)
        expect(tileCount(weapon)).toBeUndefined()
        expect(tileCount(ammo)).toBe(36)
        expect(tileCount({ item: player.items[1] as never, total: null })).toBe(3)
    })
})
