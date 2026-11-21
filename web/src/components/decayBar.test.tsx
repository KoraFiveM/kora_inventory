// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent, closeSession } = vi.hoisted(() => ({
    sendIntent: vi.fn(async (..._args: unknown[]) => ({ ok: true })),
    closeSession: vi.fn(async (..._args: unknown[]) => undefined),
}))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession }))

import App from "../App"

const item = (slot: number, name: string, decay?: { remaining: number; fraction: number }) => ({ slot, name, label: name, amount: 1, ...(decay ? { decay } : {}) })
const snapshot = {
    sessionId: "s1", token: "t", revision: 1,
    player: {
        id: "player:1", label: "Pockets", type: "player", slots: 5, weight: 0, maxWeight: 1000,
        items: [item(1, "fresh", { remaining: 172800, fraction: 1 }), item(2, "old", { remaining: 4800, fraction: 0.2 }), item(3, "rotten", { remaining: 60, fraction: 0.03 }), item(4, "rock")],
    },
}

describe("decay bar on slots", () => {
    let root: Root
    let host: HTMLElement
    const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    const bars = () => Array.from(host.querySelectorAll<HTMLElement>(".decay-bar"))

    beforeEach(async () => {
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
        await act(async () => { root.render(<App />) })
    })
    afterEach(() => { act(() => root.unmount()); host.remove() })

    it("draws nothing until the server turns decay on", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot)
        expect(bars()).toHaveLength(0)
    })

    for (const layout of ["classic", "loadout", "compact", "dock"]) {
        it(`colours the bar by remaining life and carries the tooltip text (${layout} layout)`, async () => {
            await post("kora_inventory:nui:config", { layout, decay: { enabled: true, showOnSlot: true, warnBelow: 0.25 } })
            await post("kora_inventory:nui:sessionOpened", snapshot)
            const found = bars()
            expect(found).toHaveLength(3)
            expect(found[0].className).toContain("decay-ok")
            expect(found[1].className).toContain("decay-warn")
            expect(found[2].className).toContain("decay-danger")
            expect(found[1].title).toBe("Expires in 1h 20m")
            expect(found[1].querySelector("i")?.getAttribute("style")).toContain("width: 20%")
        })
    }

    it("hides the bars when showOnSlot is off", async () => {
        await post("kora_inventory:nui:config", { decay: { enabled: true, showOnSlot: false } })
        await post("kora_inventory:nui:sessionOpened", snapshot)
        expect(bars()).toHaveLength(0)
    })

    it("follows warnBelow", async () => {
        await post("kora_inventory:nui:config", { decay: { enabled: true, showOnSlot: true, warnBelow: 0.05 } })
        await post("kora_inventory:nui:sessionOpened", snapshot)
        expect(bars()[1].className).toContain("decay-ok")
    })

    it("never draws a bar in a shop", async () => {
        await post("kora_inventory:nui:config", { decay: { enabled: true, showOnSlot: true } })
        const shop = { id: "shop:deli", label: "Deli", type: "shop", slots: 3, weight: 0, maxWeight: 1000, items: [{ ...item(1, "sandwich", { remaining: 10, fraction: 0.5 }), price: 3 }] }
        await post("kora_inventory:nui:sessionOpened", { ...snapshot, player: { ...snapshot.player, items: [] }, secondary: shop })
        expect(bars()).toHaveLength(0)
    })
})
