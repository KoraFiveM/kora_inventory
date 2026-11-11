// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

type Response = { ok: boolean; error?: string; pending?: boolean }
const { sendIntent, closeSession } = vi.hoisted(() => ({
    sendIntent: vi.fn(async (..._args: unknown[]): Promise<Response> => ({ ok: true })),
    closeSession: vi.fn(async (..._args: unknown[]) => undefined),
}))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession }))

import App from "../App"
import { predictBuy, predictMove } from "./optimistic"
import type { InventoryItem, InventoryView, SessionSnapshot } from "./types"

const item = (slot: number, name: string, amount: number, extra: Partial<InventoryItem> = {}): InventoryItem => ({ slot, name, label: name, amount, weight: 1, ...extra })
const view = (id: string, items: InventoryItem[], extra: Partial<InventoryView> = {}): InventoryView =>
    ({ id, label: id, type: "player", slots: 10, weight: 0, maxWeight: 1000, items, ...extra })
const shopView = (items: InventoryItem[]) => view("shop:1", items, { type: "shop" })
const session = (player: InventoryItem[], shop: InventoryItem[] = [item(1, "water", 5, { price: 3 })]): SessionSnapshot =>
    ({ sessionId: "s1", token: "t", revision: 1, secondaryRevision: 1, player: view("player:1", player), secondary: shopView(shop) })
const slotsOf = (inv: InventoryView) => Object.fromEntries((inv.items as InventoryItem[]).map((entry) => [entry.slot, `${entry.name}x${entry.amount}`]))

describe("predictBuy", () => {
    it("takes the stock and puts the item in the first free slot", () => {
        const out = predictBuy(session([item(1, "bread", 2)]), { shopInventory: "shop:1", slot: 1, amount: 2 })!
        expect(slotsOf(out.session.player)).toEqual({ 1: "breadx2", 2: "waterx2" })
        expect(slotsOf(out.session.secondary!)).toEqual({ 1: "waterx3" })
        expect(out.session.player.weight).toBe(4)
        expect((out.session.player.items as InventoryItem[]).find((entry) => entry.name === "water")?.pending).toBe(true)
        expect((out.session.player.items as InventoryItem[]).find((entry) => entry.name === "bread")?.pending).toBeUndefined()
    })
    it("stacks onto a matching stack and removes an emptied stock row", () => {
        const out = predictBuy(session([item(4, "water", 2)], [item(1, "water", 1, { price: 3 })]), { shopInventory: "shop:1", slot: 1, amount: 1 })!
        expect(slotsOf(out.session.player)).toEqual({ 4: "waterx3" })
        expect(slotsOf(out.session.secondary!)).toEqual({})
    })
    it("never stacks unique items and refuses a multi-buy of them", () => {
        const gun = item(1, "pistol", 1, { unique: true, price: 500 })
        expect(slotsOf(predictBuy(session([item(2, "pistol", 1, { unique: true })], [gun]), { shopInventory: "shop:1", slot: 1, amount: 1 })!.session.player)).toEqual({ 1: "pistolx1", 2: "pistolx1" })
        expect(predictBuy(session([], [{ ...gun, amount: 3 }]), { shopInventory: "shop:1", slot: 1, amount: 2 })).toBeUndefined()
    })
    it("declines when the outcome is not certain", () => {
        const base = session([item(1, "bread", 2)])
        expect(predictBuy(base, { shopInventory: "shop:1", slot: 1, amount: 6 })).toBeUndefined()
        expect(predictBuy(base, { shopInventory: "shop:1", slot: 9, amount: 1 })).toBeUndefined()
        expect(predictBuy(base, { shopInventory: "shop:9", slot: 1, amount: 1 })).toBeUndefined()
        expect(predictBuy(session([], [item(1, "water", 5, { weight: undefined })]), { shopInventory: "shop:1", slot: 1, amount: 1 })).toBeUndefined()
        const heavy = { ...base, player: { ...base.player, maxWeight: 5 } }
        expect(predictBuy(heavy, { shopInventory: "shop:1", slot: 1, amount: 4 })).toBeUndefined()
        const full = session(Array.from({ length: 10 }, (_, index) => item(index + 1, `thing${index}`, 1)))
        expect(predictBuy(full, { shopInventory: "shop:1", slot: 1, amount: 1 })).toBeUndefined()
    })
    it("never mutates the session it was given", () => {
        const before = session([item(1, "bread", 2)])
        const frozen = JSON.stringify(before)
        predictBuy(before, { shopInventory: "shop:1", slot: 1, amount: 1 })
        expect(JSON.stringify(before)).toBe(frozen)
    })
})

describe("pending marks", () => {
    it("flags what a move created or changed, and nothing it did not touch", () => {
        const base = { sessionId: "s1", token: "t", player: view("player:1", [item(1, "bread", 3), item(2, "water", 1), item(3, "rope", 1)]) }
        const split = predictMove(base, { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 5, amount: 1 })!
        const byName = (name: string) => (split.session.player.items as InventoryItem[]).find((entry) => entry.name === name)!
        expect(byName("bread").amount).toBe(2)
        expect((split.session.player.items as InventoryItem[]).filter((entry) => entry.pending).map((entry) => entry.slot)).toEqual([5])
        const swap = predictMove(base, { fromInventory: "player:1", fromSlot: 1, toInventory: "player:1", toSlot: 2, amount: 3 })!
        expect((swap.session.player.items as InventoryItem[]).filter((entry) => entry.pending).map((entry) => entry.name).sort()).toEqual(["bread", "water"])
    })
})

let root: Root
let host: HTMLElement
const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
// Both panels have a slot 2, so everything about "the destination" is read from the player's own grid.
const player = () => host.querySelector(".inventory-stage-player")!
const slot = (n: number) => player().querySelector(`button[aria-label$="slot ${n}"], button[aria-label="Empty slot ${n}"]`)!
const filled = (n: number) => !player().querySelector(`button[aria-label="Empty slot ${n}"]`)
const notice = () => host.querySelector('[role="alert"]')?.textContent
const drag = async (fromLabel: string) => {
    // The shop is the secondary panel: select the stock row, then press Buy.
    act(() => { host.querySelector(`button[aria-label^="${fromLabel}"]`)!.dispatchEvent(new MouseEvent("click", { bubbles: true })) })
    await act(async () => { (host.querySelector(".primary-action") as HTMLButtonElement).click() })
}
let ack: (value: Response) => void
const holdFetch = () => sendIntent.mockImplementationOnce(() => new Promise((resolve) => { ack = resolve }))
const verdict = (requestId: number, ok: boolean, error?: string) => post("kora_inventory:nui:intentResult", { requestId, ok, error })
const lastRequestId = () => (sendIntent.mock.calls.at(-1)![0] as { requestId: number }).requestId

beforeEach(async () => {
    vi.useFakeTimers()
    sendIntent.mockReset(); sendIntent.mockImplementation(async () => ({ ok: true, pending: true }))
    host = document.createElement("div"); document.body.appendChild(host)
    root = createRoot(host)
    await act(async () => { root.render(<App />) })
    await post("kora_inventory:nui:sessionOpened", session([item(1, "bread", 2)]))
})
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers() })

describe("a shop purchase over the direct transport", () => {
    it("shows the item in the destination at once, dimmed, with the stock already taken", async () => {
        await drag("water")
        expect(sendIntent).toHaveBeenCalledTimes(1)
        expect(sendIntent.mock.calls[0][0]).toMatchObject({ intent: "buy", requestId: expect.any(Number) })
        expect(filled(2)).toBe(true)
        expect(slot(2).textContent).toContain("water")
        expect(slot(2).getAttribute("data-pending")).toBe("true")
        expect(slot(2).className).toContain("slot-pending")
        expect(slot(1).className).not.toContain("slot-pending")
    })

    it("does not snap back while the server is still working", async () => {
        await drag("water")
        await act(async () => { vi.advanceTimersByTime(5000) })
        expect(filled(2)).toBe(true)
        expect(notice()).toBeUndefined()
    })

    it("keeps the item and settles when the verdict arrives, then the patch clears the dimming", async () => {
        await drag("water")
        const id = lastRequestId()
        await verdict(id, true)
        expect(filled(2)).toBe(true)
        expect(notice()).toBeUndefined()
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: view("player:1", [item(1, "bread", 2), item(2, "water", 1)]) })
        expect(slot(2).getAttribute("data-pending")).toBeNull()
        await act(async () => { vi.advanceTimersByTime(20000) })
        expect(filled(2)).toBe(true)
    })

    it("accepts a verdict that arrives before the fetch response", async () => {
        holdFetch()
        await drag("water")
        await verdict(lastRequestId(), true)
        await act(async () => { ack({ ok: true, pending: true }) })
        await act(async () => { vi.advanceTimersByTime(20000) })
        expect(filled(2)).toBe(true)
        expect(notice()).toBeUndefined()
    })

    it("undoes the purchase with the server's reason when it is refused", async () => {
        await drag("water")
        await verdict(lastRequestId(), false, "not enough money")
        expect(filled(2)).toBe(false)
        expect(slot(1).textContent).toContain("bread")
        expect(host.querySelector('button[aria-label^="water"]')!.textContent).toContain("×5")
        expect(notice()).toContain("not enough money")
    })

    it("undoes it with a clear notice when the server times out", async () => {
        await drag("water")
        await verdict(lastRequestId(), false, "timeout")
        expect(filled(2)).toBe(false)
        expect(notice()).toContain("did not respond")
    })

    it("undoes it when nothing arrives within the move timeout", async () => {
        await drag("water")
        await act(async () => { vi.advanceTimersByTime(6001) })
        expect(filled(2)).toBe(false)
        expect(notice()).toContain("did not respond")
    })

    it("falls back to the blocking answer when the bridge sends the verdict in the fetch", async () => {
        sendIntent.mockImplementationOnce(async () => ({ ok: false, error: "over weight" }))
        await drag("water")
        expect(filled(2)).toBe(false)
        expect(notice()).toContain("over weight")
    })

    it("paints nothing when optimistic moves are off, until the server patches", async () => {
        await post("kora_inventory:nui:config", { optimisticMoves: false })
        await drag("water")
        expect(filled(2)).toBe(false)
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: view("player:1", [item(1, "bread", 2), item(2, "water", 1)]) })
        expect(filled(2)).toBe(true)
        expect(slot(2).getAttribute("data-pending")).toBeNull()
    })

    it("clears the refusal notice on its own", async () => {
        await drag("water")
        await verdict(lastRequestId(), false, "nope")
        expect(notice()).toContain("nope")
        await act(async () => { vi.advanceTimersByTime(6001) })
        expect(notice()).toBeUndefined()
    })
})
