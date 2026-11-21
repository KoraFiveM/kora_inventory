import { describe, expect, it } from "vitest"
import { ammoInfoRows, DEFAULT_AMMO_INFO, isAmmoCompatible, mergeAmmoInfo, resolveRightClick } from "./ammo"
import { clampMenuPosition, contextMenuEntries } from "./contextMenu"
import type { InventoryItem } from "./types"

const item = (extra: Partial<InventoryItem>): InventoryItem => ({ slot: 1, name: "thing", amount: 1, ...extra })
const pistol = item({ name: "weapon_pistol", ammo: { type: "AMMO_PISTOL", item: "pistol_ammo", label: "Pistol Ammo", loaded: 12 } })
const rifle = item({ name: "weapon_rifle", ammo: { type: "AMMO_RIFLE", item: "rifle_ammo", label: "Rifle Ammo" } })
const pistolAmmo = item({ name: "pistol_ammo", amount: 3, ammoType: "AMMO_PISTOL", rounds: 24, fits: ["Pistol", "SMG"] })
const rifleAmmo = item({ name: "rifle_ammo", ammoType: "AMMO_RIFLE" })
const t = (key: string, values: Record<string, string | number> = {}) => ({
    "ui.ammo_takes": "Takes", "ui.ammo_loaded": "Loaded", "ui.ammo_rounds_per_item": "Rounds per item", "ui.ammo_fits": "Fits", "ui.ammo_type": "Type",
    "ui.ammo_rounds_value": `${values.count} rounds`,
}[key] ?? key)

describe("isAmmoCompatible", () => {
    it("matches a selected weapon to ammo of its type, and the reverse", () => {
        expect(isAmmoCompatible(pistol, pistolAmmo)).toBe(true)
        expect(isAmmoCompatible(pistolAmmo, pistol)).toBe(true)
    })
    it("rejects other types, same-kind pairs and plain items", () => {
        expect(isAmmoCompatible(pistol, rifleAmmo)).toBe(false)
        expect(isAmmoCompatible(rifleAmmo, pistol)).toBe(false)
        expect(isAmmoCompatible(pistol, rifle)).toBe(false)
        expect(isAmmoCompatible(pistolAmmo, pistolAmmo)).toBe(false)
        expect(isAmmoCompatible(pistol, item({ name: "bread" }))).toBe(false)
        expect(isAmmoCompatible(item({ name: "bread" }), pistolAmmo)).toBe(false)
        expect(isAmmoCompatible(undefined, pistolAmmo)).toBe(false)
        expect(isAmmoCompatible(pistol, undefined)).toBe(false)
    })
    it("ignores an empty type", () => {
        expect(isAmmoCompatible(item({ ammo: { type: "", item: "", label: "" } }), item({ ammoType: "" }))).toBe(false)
    })
})

describe("ammoInfoRows", () => {
    it("lists what a weapon takes and what is loaded", () => {
        expect(ammoInfoRows(pistol, DEFAULT_AMMO_INFO, t)).toEqual([
            { key: "takes", label: "Takes", value: "Pistol Ammo (AMMO_PISTOL)" },
            { key: "loaded", label: "Loaded", value: "12 rounds" },
        ])
    })
    it("hides loaded rounds when showLoaded is off or the count is absent", () => {
        expect(ammoInfoRows(pistol, { ...DEFAULT_AMMO_INFO, showLoaded: false }, t).map((row) => row.key)).toEqual(["takes"])
        expect(ammoInfoRows(rifle, DEFAULT_AMMO_INFO, t).map((row) => row.key)).toEqual(["takes"])
    })
    it("lists rounds per item and the weapons an ammo item fits", () => {
        expect(ammoInfoRows(pistolAmmo, DEFAULT_AMMO_INFO, t)).toEqual([
            { key: "takes", label: "Type", value: "AMMO_PISTOL" },
            { key: "rounds", label: "Rounds per item", value: "24" },
            { key: "fits", label: "Fits", value: "Pistol, SMG" },
        ])
        expect(ammoInfoRows(pistolAmmo, { ...DEFAULT_AMMO_INFO, showCompatible: false }, t).map((row) => row.key)).toEqual(["takes", "rounds"])
    })
    it("has nothing for a plain item", () => {
        expect(ammoInfoRows(item({ name: "bread" }), DEFAULT_AMMO_INFO, t)).toEqual([])
    })
})

describe("config merging", () => {
    it("merges ammoInfo and ignores malformed values", () => {
        expect(mergeAmmoInfo(DEFAULT_AMMO_INFO, { where: "menu", showLoaded: false })).toEqual({ enabled: true, where: "menu", showLoaded: false, showCompatible: true })
        expect(mergeAmmoInfo(DEFAULT_AMMO_INFO, { where: "nope" as never, enabled: "yes" as never })).toEqual(DEFAULT_AMMO_INFO)
        expect(mergeAmmoInfo(DEFAULT_AMMO_INFO, undefined)).toBe(DEFAULT_AMMO_INFO)
    })
    it("resolves the right-click mode, falling back to the legacy boolean", () => {
        expect(resolveRightClick({ rightClick: "menu" }, "split")).toBe("menu")
        expect(resolveRightClick({ rightClickSplit: false }, "split")).toBe("none")
        expect(resolveRightClick({ rightClick: "bogus", rightClickSplit: true }, "menu")).toBe("split")
        expect(resolveRightClick({}, "menu")).toBe("menu")
    })
})

describe("contextMenuEntries", () => {
    const base = { inventory: { id: "player:1", type: "player" }, playerId: "player:1", giveAvailable: true, inspectorCopy: true, ammoInfo: DEFAULT_AMMO_INFO }
    const entries = (extra: Partial<Parameters<typeof contextMenuEntries>[0]> & { item: InventoryItem }) => contextMenuEntries({ ...base, ...extra })

    it("offers use, split, drop, give and copy for a useable stack in the player's inventory", () => {
        expect(entries({ item: item({ useable: true, amount: 4 }) })).toEqual(["use", "split", "drop", "give", "copy"])
    })
    it("leaves out use for non-useable items and split for single items", () => {
        expect(entries({ item: item({}) })).toEqual(["drop", "give", "copy"])
    })
    it("treats a container as useable", () => {
        expect(entries({ item: item({ container: true }) })).toContain("use")
    })
    it("needs give to be available", () => {
        expect(entries({ item: item({}), giveAvailable: false })).toEqual(["drop", "copy"])
    })
    it("offers only split and copy for another inventory", () => {
        expect(entries({ item: item({ useable: true, amount: 2 }), inventory: { id: "stash:1", type: "stash" } })).toEqual(["split", "copy"])
    })
    it("offers only copy for a shop stack", () => {
        expect(entries({ item: item({ useable: true, amount: 9 }), inventory: { id: "shop:1", type: "shop" } })).toEqual(["copy"])
    })
    it("adds ammo info for weapons and ammo when it is enabled for the menu", () => {
        expect(entries({ item: pistol })).toContain("ammo")
        expect(entries({ item: pistolAmmo })).toContain("ammo")
        expect(entries({ item: pistol, ammoInfo: { ...DEFAULT_AMMO_INFO, where: "menu" } })).toContain("ammo")
    })
    it("leaves ammo info out when disabled, inspector-only, or for other items", () => {
        expect(entries({ item: pistol, ammoInfo: { ...DEFAULT_AMMO_INFO, enabled: false } })).not.toContain("ammo")
        expect(entries({ item: pistol, ammoInfo: { ...DEFAULT_AMMO_INFO, where: "inspector" } })).not.toContain("ammo")
        expect(entries({ item: item({ name: "bread" }) })).not.toContain("ammo")
    })
    it("omits copy when the inspector copy is off", () => {
        expect(entries({ item: item({}), inspectorCopy: false })).toEqual(["drop", "give"])
    })
})

describe("clampMenuPosition", () => {
    const viewport = { width: 800, height: 600 }
    const size = { width: 160, height: 120 }
    it("keeps a menu that fits where the cursor is", () => {
        expect(clampMenuPosition({ x: 100, y: 100 }, size, viewport)).toEqual({ x: 100, y: 100 })
    })
    it("pulls it back from the right and bottom edges", () => {
        expect(clampMenuPosition({ x: 790, y: 590 }, size, viewport)).toEqual({ x: 800 - 160 - 6, y: 600 - 120 - 6 })
    })
    it("never goes past the top-left margin", () => {
        expect(clampMenuPosition({ x: -20, y: -5 }, size, viewport)).toEqual({ x: 6, y: 6 })
    })
})
