// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent, closeSession } = vi.hoisted(() => ({
    sendIntent: vi.fn(async (..._args: unknown[]) => ({ ok: true })),
    closeSession: vi.fn(async (..._args: unknown[]) => undefined),
}))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession, pinQuickSlot: vi.fn(async () => ({ ok: true })) }))

import App from "../App"

const snapshot = {
    sessionId: "s1", token: "t", revision: 1,
    player: { id: "player:1", label: "Pockets", type: "player", slots: 5, weight: 0, maxWeight: 1000, items: [
        { slot: 1, name: "bread", label: "Bread", amount: 1 },
        { slot: 2, name: "water", label: "Water", amount: 6 },
    ] },
}

const tradeView = (overrides: Record<string, unknown> = {}) => ({
    id: "trade-1-1", phase: "open", revision: 4, slots: 4, allowCash: true,
    you: { offers: [{ slot: 2, amount: 3, name: "water", label: "Water" }], cash: 0, ready: false, confirmed: false, balance: 500 },
    them: { offers: [{ slot: 9, amount: 1, name: "phone", label: "Phone", displayMeta: [{ key: "serial", label: "Serial", value: "X" }] }], cash: 25, ready: false, confirmed: false },
    confirmInMs: 0, confirmDelayMs: 3000, endsInMs: 120000,
    ...overrides,
})

describe("trade window", () => {
    let root: Root
    let host: HTMLElement
    const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    const panel = () => host.querySelector("[data-testid='trade-panel']")
    const button = (label: string) => Array.from(host.querySelectorAll("button")).find((el) => el.textContent?.includes(label)) as HTMLButtonElement | undefined
    const tradeCalls = () => sendIntent.mock.calls.map((call) => call[0] as { intent: string; payload: Record<string, unknown> }).filter((call) => call.intent === "trade")
    const flush = () => act(async () => { await Promise.resolve(); await Promise.resolve() })

    beforeEach(async () => {
        vi.useFakeTimers({ toFake: ["setInterval", "clearInterval", "Date"] })
        sendIntent.mockClear()
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
        await act(async () => { root.render(<App />) })
        await post("kora_inventory:nui:sessionOpened", snapshot)
    })
    afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers() })

    it("shows the Trade button only when a partner is in range and trading is on", async () => {
        expect(host.querySelector("[data-testid='trade-request']")).toBeNull()
        await post("kora_inventory:nui:giveAvailability", { available: true })
        const request = host.querySelector("[data-testid='trade-request']") as HTMLButtonElement
        expect(request).not.toBeNull()
        await act(async () => { request.click() })
        await flush()
        expect(sendIntent.mock.calls.some((call) => (call[0] as { intent: string }).intent === "tradeRequest")).toBe(true)
        await post("kora_inventory:nui:config", { trade: { enabled: false } })
        expect(host.querySelector("[data-testid='trade-request']")).toBeNull()
    })

    it("renders as the secondary panel in every layout", async () => {
        await post("kora_inventory:nui:trade", tradeView())
        for (const layout of ["classic", "loadout", "compact", "dock"]) {
            await post("kora_inventory:nui:layout", { layout })
            expect(host.querySelector("main.inventory-shell")!.getAttribute("data-layout")).toBe(layout)
            if (layout === "dock") {
                const tab = host.querySelector("#dock-tab-secondary") as HTMLButtonElement
                expect(tab.textContent).toContain("Trade")
                await act(async () => { tab.click() })
            }
            expect(panel()).not.toBeNull()
        }
    })

    it("marks offered slots, shows both sides and keeps the partner read-only", async () => {
        await post("kora_inventory:nui:trade", tradeView())
        expect(host.querySelectorAll("[data-testid='trade-own-offer']")).toHaveLength(1)
        const partner = host.querySelectorAll("[data-testid='trade-partner-offer']")
        expect(partner).toHaveLength(1)
        expect(partner[0].textContent).toContain("Phone")
        expect(host.querySelector(".slot-offered-badge")?.textContent).toBe("3")
        expect(host.querySelector("[data-testid='trade-partner-side'] input")).toBeNull()
        expect(host.textContent).toContain("$25")
        // Right-clicking a partner offer does nothing; on your own it withdraws.
        await act(async () => { partner[0].dispatchEvent(new MouseEvent("contextmenu", { bubbles: true })) })
        await flush()
        expect(tradeCalls()).toHaveLength(0)
        const own = host.querySelector("[data-testid='trade-own-offer']")!
        await act(async () => { own.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true })) })
        await flush()
        expect(tradeCalls()[0].payload).toMatchObject({ op: "unoffer", id: "trade-1-1", slot: 2 })
    })

    it("sends Ready with the revision the player saw", async () => {
        await post("kora_inventory:nui:trade", tradeView())
        await act(async () => { button("Ready")!.click() })
        await flush()
        expect(tradeCalls().at(-1)!.payload).toEqual({ op: "ready", id: "trade-1-1", revision: 4 })
        await post("kora_inventory:nui:trade", tradeView({ you: { ...tradeView().you, ready: true }, revision: 5 }))
        expect(host.querySelector("[data-testid='trade-own-flag']")!.getAttribute("data-state")).toBe("ready")
        expect(button("Ready")).toBeUndefined()
    })

    it("holds Confirm through the countdown, then confirms with the revision", async () => {
        await post("kora_inventory:nui:trade", tradeView({ phase: "locked", confirmInMs: 3000, revision: 7,
            you: { ...tradeView().you, ready: true }, them: { ...tradeView().them, ready: true } }))
        const confirm = () => host.querySelector("[data-testid='trade-confirm']") as HTMLButtonElement
        expect(confirm().disabled).toBe(true)
        expect(confirm().textContent).toContain("3")
        expect(host.querySelector("[data-testid='trade-partner-flag']")!.getAttribute("data-state")).toBe("ready")
        await act(async () => { vi.advanceTimersByTime(3100) })
        expect(confirm().disabled).toBe(false)
        await act(async () => { confirm().click() })
        await flush()
        expect(tradeCalls().at(-1)!.payload).toEqual({ op: "confirm", id: "trade-1-1", revision: 7 })
        // Offers are frozen: the cash field is disabled while locked.
        expect((host.querySelector("[data-testid='trade-own-side'] input") as HTMLInputElement).disabled).toBe(true)
    })

    it("sets cash within the balance only", async () => {
        await post("kora_inventory:nui:trade", tradeView())
        const input = host.querySelector("[data-testid='trade-own-side'] input") as HTMLInputElement
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!
        await act(async () => { setter.call(input, "900"); input.dispatchEvent(new Event("input", { bubbles: true })) })
        await act(async () => { button("Set")!.click() })
        await flush()
        expect(tradeCalls()).toHaveLength(0)
        await act(async () => { setter.call(input, "120"); input.dispatchEvent(new Event("input", { bubbles: true })) })
        await act(async () => { button("Set")!.click() })
        await flush()
        expect(tradeCalls().at(-1)!.payload).toEqual({ op: "cash", id: "trade-1-1", cash: 120 })
    })

    it("offers with Shift+click: single items at once, stacks through the amount dialog", async () => {
        await post("kora_inventory:nui:trade", tradeView({ you: { offers: [], cash: 0, ready: false, confirmed: false } }))
        const slots = host.querySelectorAll(".inventory-panel-player .slot")
        await act(async () => { (slots[0] as HTMLButtonElement).dispatchEvent(new MouseEvent("click", { bubbles: true, shiftKey: true })) })
        await flush()
        expect(tradeCalls().at(-1)!.payload).toEqual({ op: "offer", id: "trade-1-1", slot: 1, amount: 1 })
        await act(async () => { (slots[1] as HTMLButtonElement).dispatchEvent(new MouseEvent("click", { bubbles: true, shiftKey: true })) })
        const dialog = host.querySelector(".trade-amount-dialog") as HTMLFormElement
        expect(dialog).not.toBeNull()
        const input = dialog.querySelector("input") as HTMLInputElement
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!
        await act(async () => { setter.call(input, "4"); input.dispatchEvent(new Event("input", { bubbles: true })) })
        await act(async () => { dialog.requestSubmit() })
        await flush()
        expect(tradeCalls().at(-1)!.payload).toEqual({ op: "offer", id: "trade-1-1", slot: 2, amount: 4 })
        expect(host.querySelector(".trade-amount-dialog")).toBeNull()
    })

    it("sends Cancel and closes when the server ends the trade", async () => {
        await post("kora_inventory:nui:trade", tradeView())
        await act(async () => { button("Cancel trade")!.click() })
        await flush()
        expect(tradeCalls().at(-1)!.payload).toEqual({ op: "cancel", id: "trade-1-1" })
        await post("kora_inventory:nui:tradeEnded", { id: "other", reason: "x" })
        expect(panel()).not.toBeNull()
        await post("kora_inventory:nui:tradeEnded", { id: "trade-1-1", reason: "cancelled" })
        expect(panel()).toBeNull()
    })

    it("keeps the lease alive while the window is open", async () => {
        await post("kora_inventory:nui:trade", tradeView())
        await act(async () => { vi.advanceTimersByTime(30_000) })
        await flush()
        expect(tradeCalls().some((call) => call.payload.op === "keepalive")).toBe(true)
    })

    it("ignores malformed trade messages and drops the window with the session", async () => {
        await post("kora_inventory:nui:trade", { id: 3 })
        expect(panel()).toBeNull()
        await post("kora_inventory:nui:trade", tradeView())
        expect(panel()).not.toBeNull()
        await post("kora_inventory:nui:sessionClosed", { sessionId: "s1" })
        expect(panel()).toBeNull()
    })
})
