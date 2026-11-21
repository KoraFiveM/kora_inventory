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
import { TIPS_STORAGE_KEY } from "@/lib/tips"

const player = {
    id: "player:1", label: "Pockets", type: "player", slots: 6, weight: 0, maxWeight: 1000,
    items: [{ slot: 1, name: "water", label: "Water", amount: 2 }, { slot: 3, name: "bandage", label: "Bandage", amount: 4, useable: true }],
}
const stash = { id: "stash:a", label: "Garage", type: "stash", slots: 4, weight: 0, maxWeight: 1000, items: [{ slot: 2, name: "bread", label: "Bread", amount: 1 }] }
const shop = { id: "shop:a", label: "Shop", type: "shop", slots: 4, weight: 0, maxWeight: 1000, items: [{ slot: 1, name: "bread", label: "Bread", amount: 1, price: 3 }] }
let counter = 0
const snapshot = (secondary?: unknown) => ({ sessionId: `s${++counter}`, token: "t", revision: 7, secondaryRevision: secondary ? 9 : undefined, player, secondary })

describe("organize controls and panel search", () => {
    let root: Root
    let host: HTMLElement
    const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    const panels = () => Array.from(host.querySelectorAll<HTMLElement>(".inventory-panel"))
    const button = (panel: HTMLElement, label: string) => panel.querySelector<HTMLButtonElement>(`button[aria-label="${label}"]`)

    beforeEach(async () => {
        window.localStorage.setItem(TIPS_STORAGE_KEY, JSON.stringify({ seen: [], dismissed: true, opens: 0 }))
        sendIntent.mockClear()
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
        await act(async () => { root.render(<App />) })
    })
    afterEach(() => { act(() => root.unmount()); host.remove(); window.localStorage.clear() })

    it("puts Sort and Stack all on every non-shop panel", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot(stash))
        const [first, second] = panels()
        for (const panel of [first, second]) {
            expect(button(panel, "Sort")?.getAttribute("title")).toBe("Sort")
            expect(button(panel, "Stack all")?.getAttribute("title")).toBe("Stack all")
            expect(panel.querySelector(".panel-search input")).not.toBeNull()
        }
    })

    it("has no organize controls on a shop", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot(shop))
        const shopPanel = panels().find((panel) => panel.getAttribute("aria-label") === "Shop")!
        expect(button(shopPanel, "Sort")).toBeNull()
        expect(button(shopPanel, "Stack all")).toBeNull()
        expect(shopPanel.querySelector(".panel-search")).toBeNull()
        expect(button(panels().find((panel) => panel.getAttribute("aria-label") === "Pockets")!, "Sort")).not.toBeNull()
    })

    it("sends an organize intent naming the panel, the mode and the revisions", async () => {
        const opened = snapshot(stash)
        await post("kora_inventory:nui:sessionOpened", opened)
        await act(async () => { button(panels()[1], "Stack all")!.click() })
        expect(sendIntent).toHaveBeenCalledTimes(1)
        expect(sendIntent.mock.calls[0][0]).toMatchObject({
            sessionId: opened.sessionId, intent: "organize",
            payload: { inventory: "stash:a", mode: "stack", revision: 7, secondaryRevision: 9 },
        })
        await act(async () => { button(panels()[0], "Sort")!.click() })
        expect(sendIntent.mock.calls.at(-1)?.[0]).toMatchObject({ intent: "organize", payload: { inventory: "player:1", mode: "sort" } })
    })

    it("hides the buttons the server switched off", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot(stash))
        await post("kora_inventory:nui:config", { organize: { enabled: true, sort: false, stack: true, panelSearch: false } })
        const [first] = panels()
        expect(button(first, "Sort")).toBeNull()
        expect(button(first, "Stack all")).not.toBeNull()
        expect(first.querySelector(".panel-search")).toBeNull()
        await post("kora_inventory:nui:config", { organize: { enabled: false, sort: false, stack: false, panelSearch: false } })
        expect(button(panels()[0], "Stack all")).toBeNull()
    })

    it("dims only the searched panel's non-matching slots", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot({ ...stash, items: [{ slot: 1, name: "water", label: "Water", amount: 1 }, { slot: 2, name: "bread", label: "Bread", amount: 1 }] }))
        const [first, second] = panels()
        const input = second.querySelector<HTMLInputElement>(".panel-search input")!
        await act(async () => {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!
            setter.call(input, "brea")
            input.dispatchEvent(new Event("input", { bubbles: true }))
        })
        const dimmed = (panel: HTMLElement) => panel.querySelectorAll(".slot-dimmed").length
        expect(dimmed(second)).toBe(1)
        expect(dimmed(first)).toBe(0)
    })

    it("keeps the top bar search dimming the player panel", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot(stash))
        const input = host.querySelector<HTMLInputElement>(".inventory-topbar .search input")!
        await act(async () => {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!
            setter.call(input, "band")
            input.dispatchEvent(new Event("input", { bubbles: true }))
        })
        expect(panels()[0].querySelectorAll(".slot-dimmed").length).toBe(1)
        expect(panels()[1].querySelectorAll(".slot-dimmed").length).toBe(0)
    })

    it("works in every layout", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot(stash))
        for (const layout of ["loadout", "compact", "dock"]) {
            await post("kora_inventory:nui:layout", { layout })
            expect(host.querySelectorAll('button[aria-label="Sort"]').length).toBeGreaterThanOrEqual(1)
            expect(host.querySelectorAll('button[aria-label="Stack all"]').length).toBeGreaterThanOrEqual(1)
        }
    })
})
