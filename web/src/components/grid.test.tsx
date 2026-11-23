// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import type { InventoryItem, InventoryView } from "@/lib/types"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent } = vi.hoisted(() => ({ sendIntent: vi.fn(async (..._args: unknown[]) => ({ ok: true, pending: true })) }))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession: vi.fn(), pinQuickSlot: vi.fn() }))

import App from "../App"
import { TIPS_STORAGE_KEY } from "@/lib/tips"

const player: InventoryView = { id: "player:1", label: "Pockets", type: "player", slots: 7, gridColumns: 3, items: [
    { slot: 2, name: "wide", label: "Wide", amount: 2, gridWidth: 2, gridHeight: 1 },
] }
const stashItem: InventoryItem = { slot: 1, name: "crate", label: "Crate", amount: 1, gridBaseWidth: 2, gridBaseHeight: 1 }
const stash: InventoryView = { id: "stash:a", label: "Garage", type: "stash", slots: 7, items: [stashItem] }

describe("shaped inventory", () => {
    let root: Root
    let host: HTMLElement
    const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    const slot = (panel: string, index: number) =>
        Array.from(host.querySelectorAll<HTMLButtonElement>(`[aria-label="${panel}"] .slot`)).find((button) => new RegExp(`(?:^Empty slot |, slot )${index}(?:,|$)`).test(button.getAttribute("aria-label") ?? ""))

    beforeEach(async () => {
        window.localStorage.setItem(TIPS_STORAGE_KEY, JSON.stringify({ seen: [], dismissed: true, opens: 0 }))
        sendIntent.mockClear()
        host = document.createElement("div")
        document.body.appendChild(host)
        root = createRoot(host)
        await act(async () => { root.render(<App />) })
        await post("kora_inventory:nui:config", { quickTransfer: true, optimisticMoves: true, queueMoves: true, showHotbar: true, hotbarSlots: 2 })
        await post("kora_inventory:nui:sessionOpened", { sessionId: "grid", token: "t", revision: 7, secondaryRevision: 9, player, secondary: stash })
    })

    afterEach(() => { act(() => root.unmount()); host.remove(); window.localStorage.clear() })

    it("spans occupied cells and keeps real empty anchors and classic slots", () => {
        expect(slot("Pockets", 2)?.style.gridColumn).toBe("2 / span 2")
        expect(slot("Pockets", 2)?.getAttribute("aria-label")).toContain("grid footprint 2 by 1")
        expect(slot("Pockets", 3)).toBeUndefined()
        expect(slot("Pockets", 7)?.style.gridRow).toBe("3 / span 1")
        expect(slot("Garage", 1)?.style.gridRow).toBe("")
        expect(slot("Pockets", 2)?.querySelector(".slot-number")?.textContent).toBe("2")
        expect(slot("Pockets", 7)?.querySelector(".slot-number")).toBeNull()
        expect(slot("Garage", 1)?.querySelector(".slot-number")?.textContent).toBe("1")
    })

    it("requests a whole-stack rotation and waits for the server footprint", async () => {
        await act(async () => { slot("Pockets", 2)?.click() })
        await act(async () => { host.querySelector<HTMLButtonElement>('[data-grid-action="rotate"]')?.click() })
        expect(sendIntent.mock.calls[0][0]).toMatchObject({ intent: "move", payload: {
            fromInventory: player.id, fromSlot: 2, toInventory: player.id, toSlot: 2, amount: 2, rotated: true, revision: 7, secondaryRevision: 9,
        } })
        expect(slot("Pockets", 2)?.style.gridColumn).toBe("2 / span 2")
        await post("kora_inventory:nui:sessionPatched", { sessionId: "grid", revision: 8, player: { items: [
            { ...(player.items as InventoryItem[])[0], gridWidth: 1, gridHeight: 2, gridRotated: true },
        ] } })
        expect(slot("Pockets", 2)?.style.gridRow).toBe("1 / span 2")
        expect(slot("Pockets", 3)).toBeDefined()
        expect(slot("Pockets", 5)).toBeUndefined()
    })

    it("quick-transfers from a classic panel into the first fitting grid anchor without predicting a move", async () => {
        await act(async () => { slot("Garage", 1)?.dispatchEvent(new MouseEvent("click", { bubbles: true, shiftKey: true })) })
        expect(sendIntent.mock.calls[0][0]).toMatchObject({ intent: "move", payload: { fromInventory: stash.id, fromSlot: 1, toInventory: player.id, toSlot: 4 } })
        expect(slot("Pockets", 4)?.classList.contains("slot-filled")).toBe(false)
        expect(slot("Garage", 1)?.classList.contains("slot-filled")).toBe(true)
    })

    it("splits a legacy one-cell stack into an anchor that fits its authored footprint", async () => {
        await post("kora_inventory:nui:sessionPatched", { sessionId: "grid", revision: 8, player: { items: [
            { ...stashItem, slot: 2, amount: 2, gridWidth: 1, gridHeight: 1 },
        ] } })
        expect(slot("Pockets", 2)?.style.gridColumn).toBe("2 / span 1")
        await act(async () => { slot("Pockets", 2)?.click() })
        const split = Array.from(host.querySelectorAll<HTMLButtonElement>(".item-detail .quiet-action")).find((button) => button.textContent?.startsWith("Split "))
        expect(split).toBeDefined()
        await act(async () => { split?.click() })
        expect(sendIntent.mock.calls[0][0]).toMatchObject({ intent: "move", payload: { fromInventory: player.id, fromSlot: 2, toInventory: player.id, toSlot: 4, amount: 1 } })
    })
})
