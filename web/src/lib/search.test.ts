import { describe, expect, it } from "vitest"
import { contextMenuEntries } from "./contextMenu"
import { DEFAULT_AMMO_INFO } from "./ammo"
import { canOpenBag, isClosedBag, isWaterDamaged, openBagPayload } from "./search"
import type { InventoryItem, InventoryView } from "./types"

const target: InventoryView = { id: "player:9", type: "player", slots: 40, items: [] }
const own: InventoryView = { id: "player:1", type: "player", slots: 40, items: [] }
const bag: InventoryItem = { slot: 4, name: "backpack", amount: 1, closedContainer: true, openable: true }

describe("search helpers", () => {
    it("recognises a closed bag only when the server flagged it", () => {
        expect(isClosedBag(bag)).toBe(true)
        expect(isClosedBag({ ...bag, closedContainer: undefined })).toBe(false)
        expect(isClosedBag(undefined)).toBe(false)
    })

    it("offers Open bag only for another player's openable closed bag", () => {
        expect(canOpenBag(target, bag, "player:1")).toBe(true)
        expect(canOpenBag(own, bag, "player:1")).toBe(false)
        expect(canOpenBag(target, { ...bag, openable: false }, "player:1")).toBe(false)
        expect(canOpenBag({ id: "stash:1", type: "stash" }, bag, "player:1")).toBe(false)
    })

    it("sends only the granted inventory id and the slot", () => {
        expect(openBagPayload(target, bag)).toEqual({ inventory: "player:9", slot: 4 })
    })

    it("flags water damaged items", () => {
        expect(isWaterDamaged({ slot: 1, name: "phone", amount: 1, waterDamaged: true })).toBe(true)
        expect(isWaterDamaged({ slot: 1, name: "phone", amount: 1 })).toBe(false)
    })

    it("puts Open in the context menu for a searched bag and never Use or Drop", () => {
        const entries = contextMenuEntries({ inventory: target, item: bag, playerId: "player:1", giveAvailable: true, inspectorCopy: false, ammoInfo: DEFAULT_AMMO_INFO })
        expect(entries).toContain("open")
        expect(entries).not.toContain("use")
        expect(entries).not.toContain("drop")
    })
})
