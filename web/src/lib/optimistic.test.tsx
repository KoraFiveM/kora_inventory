// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { readFileSync } from "node:fs"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent, closeSession } = vi.hoisted(() => ({
    sendIntent: vi.fn(async (..._args: unknown[]): Promise<{ ok: boolean; error?: string }> => ({ ok: true })),
    closeSession: vi.fn(async (..._args: unknown[]) => undefined),
}))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession }))

import App from "../App"
import { predictMove, restoreInventories } from "./optimistic"
import type { InventoryItem, InventoryView, SessionSnapshot } from "./types"

const leaf = (slot: number, amount: number, extra: Partial<InventoryItem> = {}): InventoryItem => ({ slot, name: "coca_leaf", label: "Coca Leaf", amount, weight: 1, ...extra })
const water = (slot: number, amount: number): InventoryItem => ({ slot, name: "water", label: "Water", amount, weight: 2 })
const view = (id: string, items: InventoryItem[], extra: Partial<InventoryView> = {}): InventoryView =>
    ({ id, label: id, type: "player", slots: 10, weight: 0, maxWeight: 1000, items, ...extra })
const session = (player: InventoryItem[], secondary?: InventoryView): SessionSnapshot =>
    ({ sessionId: "s1", token: "t", revision: 1, player: view("player:1", player), secondary })
const slotsOf = (inv: InventoryView) => Object.fromEntries((inv.items as InventoryItem[]).map((item) => [item.slot, `${item.name}x${item.amount}`]))

describe("predictMove", () => {
    it("moves a whole stack into an empty slot", () => {
        const out = predictMove(session([leaf(1, 3)]), { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 4, amount: 3 })!
        expect(slotsOf(out.session.player)).toEqual({ 4: "coca_leafx3" })
    })
    it("splits a partial amount into an empty slot", () => {
        const out = predictMove(session([leaf(1, 3)]), { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 2, amount: 1 })!
        expect(slotsOf(out.session.player)).toEqual({ 1: "coca_leafx2", 2: "coca_leafx1" })
    })
    it("merges identical stacks and refuses to merge differing metadata", () => {
        const req = { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 2, amount: 2 }
        expect(slotsOf(predictMove(session([leaf(1, 2), leaf(2, 5)]), req)!.session.player)).toEqual({ 2: "coca_leafx7" })
        // different metadata is a swap, which is legal for a whole stack
        expect(slotsOf(predictMove(session([leaf(1, 2), leaf(2, 5, { metadata: { q: 1 } })]), req)!.session.player)).toEqual({ 1: "coca_leafx5", 2: "coca_leafx2" })
    })
    it("swaps different items and declines a partial swap", () => {
        const base = session([leaf(1, 2), water(2, 1)])
        const req = { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 2, amount: 2 }
        expect(slotsOf(predictMove(base, req)!.session.player)).toEqual({ 1: "waterx1", 2: "coca_leafx2" })
        expect(predictMove(base, { ...req, amount: 1 })).toBeUndefined()
    })
    it("moves between inventories, updates weights, and declines an over-weight move", () => {
        const stash = view("stash:1", [], { type: "stash", maxWeight: 10 })
        const ok = predictMove(session([leaf(1, 3)], stash), { fromInventory: "player:1", fromSlot: 1, toInventory: "stash:1", toSlot: 1, amount: 3 })!
        expect(slotsOf(ok.session.secondary!)).toEqual({ 1: "coca_leafx3" })
        expect(ok.session.secondary!.weight).toBe(3)
        expect(ok.session.player.weight).toBe(0)
        expect(predictMove(session([leaf(1, 30)], stash), { fromInventory: "player:1", fromSlot: 1, toInventory: "stash:1", toSlot: 1, amount: 30 })).toBeUndefined()
    })
    it("does not touch shops, missing items or bad slots, and never mutates its input", () => {
        const shop = view("shop:1", [leaf(1, 5)], { type: "shop" })
        expect(predictMove(session([], shop), { fromInventory: "shop:1", fromSlot: 1, toInventory: "player:1", toSlot: 1, amount: 1 })).toBeUndefined()
        expect(predictMove(session([leaf(1, 2)]), { fromInventory: "player:1", fromSlot: 2, toInventory: "player:1", toSlot: 3, amount: 1 })).toBeUndefined()
        expect(predictMove(session([leaf(1, 2)]), { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 99, amount: 1 })).toBeUndefined()
        const before = session([leaf(1, 3)])
        const frozen = JSON.stringify(before)
        predictMove(before, { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 2, amount: 1 })
        expect(JSON.stringify(before)).toBe(frozen)
    })
    it("restoreInventories returns exactly the previous views", () => {
        const before = session([leaf(1, 3)])
        const out = predictMove(before, { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 2, amount: 1 })!
        expect(restoreInventories(out.session, out.before).player).toBe(before.player)
    })
})

const snapshot = session([leaf(1, 3)])
let root: Root
let host: HTMLElement
const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
const slotText = (n: number) => host.querySelector(`button[aria-label$="slot ${n}"], button[aria-label="Empty slot ${n}"]`)!.textContent ?? ""
const filled = (n: number) => !host.querySelector(`button[aria-label="Empty slot ${n}"]`)
const notice = () => host.querySelector('[role="alert"]')?.textContent
const splitOne = async () => {
    act(() => { host.querySelector('button[aria-label^="Coca Leaf"]')!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
    await act(async () => { host.querySelector("form")!.requestSubmit() })
}
let answer: (value: { ok: boolean; error?: string }) => void
const hold = () => sendIntent.mockImplementationOnce(() => new Promise((resolve) => { answer = resolve }))

beforeEach(async () => {
    vi.useFakeTimers()
    sendIntent.mockReset(); sendIntent.mockImplementation(async () => ({ ok: true }))
    host = document.createElement("div"); document.body.appendChild(host)
    root = createRoot(host)
    await act(async () => { root.render(<App />) })
    await post("kora_inventory:nui:sessionOpened", snapshot)
})
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers() })

describe("optimistic moves in the NUI", () => {
    it("applies the move immediately, before the server answers", async () => {
        hold(); await splitOne()
        expect(sendIntent).toHaveBeenCalledTimes(1)
        expect(filled(2)).toBe(true)
        expect(slotText(2)).toContain("×1")
        expect(slotText(1)).toContain("×2")
    })

    it("rolls back exactly and shows the error when the server rejects", async () => {
        hold(); await splitOne()
        await act(async () => { answer({ ok: false, error: "over weight" }) })
        expect(filled(2)).toBe(false)
        expect(slotText(1)).toContain("×3")
        expect(notice()).toContain("over weight")
    })

    it("rolls back on a kora_inventory:nui:rejected event", async () => {
        hold(); await splitOne()
        await post("kora_inventory:nui:rejected", { reason: "denied" })
        expect(filled(2)).toBe(false)
        expect(slotText(1)).toContain("×3")
        expect(notice()).toContain("denied")
    })

    it("rolls back when the server never answers", async () => {
        hold(); await splitOne()
        expect(filled(2)).toBe(true)
        await act(async () => { vi.advanceTimersByTime(10001) })
        expect(filled(2)).toBe(false)
        expect(slotText(1)).toContain("×3")
        expect(notice()).toContain("did not respond")
    })

    it("reconciles with the authoritative patch and does not roll back afterwards", async () => {
        hold(); await splitOne()
        // the server decided differently from the prediction
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: view("player:1", [leaf(1, 1), leaf(5, 2)]) })
        expect(filled(2)).toBe(false)
        expect(slotText(5)).toContain("×2")
        await act(async () => { answer({ ok: true }) })
        await act(async () => { vi.advanceTimersByTime(20000) })
        expect(slotText(5)).toContain("×2")
        expect(slotText(1)).toContain("×1")
        expect(notice()).toBeUndefined()
    })

    it("an authoritative refresh wins over a late rejection", async () => {
        hold(); await splitOne()
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: view("player:1", [leaf(1, 1), leaf(5, 2)]) })
        await act(async () => { answer({ ok: false, error: "late" }) })
        expect(slotText(5)).toContain("×2")
        expect(filled(2)).toBe(false)
    })

    it("a late answer to a timed-out request cannot roll back the next move", async () => {
        hold(); await splitOne()
        await act(async () => { vi.advanceTimersByTime(10001) })
        const first = answer
        hold(); await splitOne()
        expect(filled(2)).toBe(true)
        await act(async () => { first({ ok: false, error: "ancient" }) })
        expect(filled(2)).toBe(true)
        expect(notice()).not.toContain("ancient")
    })

    it("flag off keeps the old behaviour: nothing moves until the server patches", async () => {
        await post("kora_inventory:nui:config", { optimisticMoves: false })
        hold(); await splitOne()
        expect(sendIntent).toHaveBeenCalledTimes(1)
        expect(filled(2)).toBe(false)
        expect(slotText(1)).toContain("×3")
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: view("player:1", [leaf(1, 2), leaf(2, 1)]) })
        expect(slotText(2)).toContain("×1")
    })

    it("flag off: a rejection leaves the (unchanged) inventory as it was", async () => {
        await post("kora_inventory:nui:config", { optimisticMoves: false })
        hold(); await splitOne()
        await act(async () => { answer({ ok: false, error: "nope" }) })
        expect(slotText(1)).toContain("×3")
        expect(notice()).toContain("nope")
    })
})

const disabledSlots = () => host.querySelectorAll('.slot[aria-disabled="true"]').length

describe("the inventory stays usable while a move waits for the server", () => {

    it("never locks the slots or shows a busy state behind a pending move", async () => {
        hold(); await splitOne()
        expect(disabledSlots()).toBe(0)
        expect(host.querySelector('[aria-busy="true"]')).toBeNull()
    })

    it("queues a second drag and sends it in order once the first is answered", async () => {
        hold(); await splitOne()
        await splitOne()
        expect(sendIntent).toHaveBeenCalledTimes(1)
        await act(async () => { answer({ ok: true }) })
        await act(async () => { vi.advanceTimersByTime(1) })
        expect(sendIntent).toHaveBeenCalledTimes(2)
        expect(sendIntent.mock.calls[1][0]).toMatchObject({ intent: "move" })
    })

    it("settles on the answer alone, without waiting for a patch of every inventory", async () => {
        hold(); await splitOne()
        await act(async () => { answer({ ok: true }) })
        await splitOne()
        expect(sendIntent).toHaveBeenCalledTimes(2)
    })

    it("a refused move rolls back, the queued move still goes out, and the server is asked to resync", async () => {
        hold(); await splitOne()
        await splitOne()
        await act(async () => { answer({ ok: false, error: "nope" }) })
        await act(async () => { vi.advanceTimersByTime(50) })
        const intents = sendIntent.mock.calls.map((call) => (call[0] as { intent: string }).intent)
        expect(intents.filter((intent) => intent === "move")).toHaveLength(2)
        expect(intents).toContain("sync")
        expect(notice()).toContain("nope")
    })

    it("a move that gets no answer is rolled back, resynced, and the next drag works", async () => {
        hold(); await splitOne()
        await splitOne()
        await act(async () => { vi.advanceTimersByTime(10001) })
        expect(notice()).toContain("did not respond")
        const intents = () => sendIntent.mock.calls.map((call) => (call[0] as { intent: string }).intent)
        expect(intents()).toContain("sync")
        expect(intents().filter((intent) => intent === "move")).toHaveLength(2)
        // a late answer to the dead request changes nothing, and the inventory is still usable
        await act(async () => { answer({ ok: false, error: "ancient" }) })
        expect(notice()).not.toContain("ancient")
        await act(async () => { vi.advanceTimersByTime(10001) })
        await splitOne()
        expect(intents().filter((intent) => intent === "move").length).toBeGreaterThanOrEqual(3)
    })

    it("repeated unanswered drags never close the inventory or lock the slots", async () => {
        for (let i = 0; i < 6; i++) {
            sendIntent.mockImplementationOnce(() => new Promise(() => undefined))
            await splitOne()
            await act(async () => { vi.advanceTimersByTime(10001) })
        }
        expect(disabledSlots()).toBe(0)
        expect(host.querySelector(".inventory-shell")).not.toBeNull()
        expect(closeSession).not.toHaveBeenCalled()
        expect(slotText(1)).toContain("×3")
    })

    it("refuses drags beyond the queue limit with a message and recovers", async () => {
        hold(); await splitOne()
        for (let i = 0; i < 8; i++) await splitOne()
        expect(notice()).toBeUndefined()
        await splitOne()
        expect(notice()).toContain("Too many moves")
    })

    describe("buying from a shop", () => {
        const shop = view("shop:1", [{ slot: 1, name: "bread", label: "Bread", amount: 40, price: 9, weight: 1 }, { slot: 2, name: "beer", label: "Beer", amount: 60, price: 12, weight: 1 }], { type: "shop", label: "Liquor", slots: 16 })
        const buyOnce = async (n: number) => act(async () => { host.querySelector(`.inventory-stage-secondary button[aria-label$="slot ${n}"]`)!.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true })) })
        const buys = () => sendIntent.mock.calls.filter((call) => (call[0] as { intent: string }).intent === "buy").length

        beforeEach(async () => { await post("kora_inventory:nui:sessionOpened", { ...snapshot, secondary: shop }) })

        it("settles on the plain true answer of a purchase, with no patch, so the next buy goes out", async () => {
            for (let i = 1; i <= 5; i++) { await buyOnce(1); expect(buys()).toBe(i) }
            expect(disabledSlots()).toBe(0)
        })

        it("a purchase that is refused or unanswered does not block later purchases", async () => {
            sendIntent.mockImplementationOnce(async () => ({ ok: false, error: "not enough money" }))
            await buyOnce(1)
            expect(notice()).toContain("not enough money")
            sendIntent.mockImplementationOnce(() => new Promise(() => undefined))
            await buyOnce(2)
            await act(async () => { vi.advanceTimersByTime(10001) })
            expect(notice()).toContain("did not respond")
            await buyOnce(1)
            expect(buys()).toBe(3)
        })
    })
    it("queueMoves off locks the inventory until the server answers, without a wait cursor", async () => {
        await post("kora_inventory:nui:config", { queueMoves: false })
        hold(); await splitOne()
        expect(disabledSlots()).toBeGreaterThan(0)
        act(() => { host.querySelector('button[aria-label^="Coca Leaf"]')!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
        expect(host.querySelector("form")).toBeNull()
        expect(sendIntent).toHaveBeenCalledTimes(1)
        await act(async () => { answer({ ok: true }) })
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: view("player:1", [leaf(1, 2), leaf(2, 1)]) })
        expect(disabledSlots()).toBe(0)
    })

    it("honours the configured move timeout", async () => {
        await post("kora_inventory:nui:config", { moveTimeoutMs: 3000 })
        hold(); await splitOne()
        await act(async () => { vi.advanceTimersByTime(2999) })
        expect(filled(2)).toBe(true)
        await act(async () => { vi.advanceTimersByTime(2) })
        expect(filled(2)).toBe(false)
        expect(notice()).toContain("did not respond")
    })

    it("opening a session starts unlocked and the stylesheet has no busy cursor", () => {
        expect(disabledSlots()).toBe(0)
        const css = readFileSync("src/styles.css", "utf8")
        expect(css).not.toMatch(/cursor:\s*(wait|progress)/)
    })
})
