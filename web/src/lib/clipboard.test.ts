// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest"
import { copyText, itemCopyText } from "./clipboard"

describe("itemCopyText", () => {
    it("copies label, name, amount, slot, inventory and metadata as JSON", () => {
        const text = itemCopyText({ id: "player:1", type: "player" }, {
            slot: 3, name: "weapon_pistol", label: "Pistol", amount: 1, weight: 1000,
            info: { serial: "ABC123", durability: 92.7 },
        })
        expect(JSON.parse(text)).toEqual({
            label: "Pistol", name: "weapon_pistol", amount: 1, slot: 3,
            inventory: "player:1", inventoryType: "player", weight: 1000,
            metadata: { serial: "ABC123", durability: 92.7 },
        })
    })

    it("falls back to ox-style metadata, then an empty table", () => {
        expect(JSON.parse(itemCopyText({ id: "s" }, { slot: 1, name: "water", amount: 2, metadata: { a: 1 } })).metadata).toEqual({ a: 1 })
        const bare = JSON.parse(itemCopyText({ id: "shop", type: "shop" }, { slot: 1, name: "water", amount: 5, price: 8 }))
        expect(bare.metadata).toEqual({})
        expect(bare.label).toBe("water")
        expect(bare.price).toBe(8)
    })
})

describe("copyText", () => {
    afterEach(() => { vi.restoreAllMocks() })

    it("uses the hidden textarea + execCommand path first and cleans up", async () => {
        const exec = vi.fn(() => true)
        document.execCommand = exec
        const writeText = vi.fn(async () => undefined)
        Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true })
        expect(await copyText("hello")).toBe(true)
        expect(exec).toHaveBeenCalledWith("copy")
        expect(writeText).not.toHaveBeenCalled()
        expect(document.querySelector("textarea")).toBeNull()
    })

    it("falls back to navigator.clipboard when execCommand fails", async () => {
        document.execCommand = vi.fn(() => false)
        const writeText = vi.fn(async () => undefined)
        Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true })
        expect(await copyText("hello")).toBe(true)
        expect(writeText).toHaveBeenCalledWith("hello")
    })

    it("reports failure when neither method is available", async () => {
        document.execCommand = vi.fn(() => { throw new Error("blocked") })
        Object.defineProperty(navigator, "clipboard", { value: undefined, configurable: true })
        expect(await copyText("hello")).toBe(false)
    })
})
