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

import { DEFAULT_UI_CONFIG } from "@/context"
import App from "../App"
import { LAYOUTS, LAYOUT_IDS, resolveLayout } from "./index"

describe("resolveLayout", () => {
    const config = { ...DEFAULT_UI_CONFIG, layout: "classic" as const }

    it("uses the player's choice when choice is on and the layout is allowed", () => {
        expect(resolveLayout(config, { layout: "dock" })).toBe("dock")
    })

    it("ignores the player's choice when choice is off", () => {
        expect(resolveLayout({ ...config, layout: "compact", playerLayoutChoice: false }, { layout: "dock" })).toBe("compact")
    })

    it("falls to the server layout when the player's choice is not allowed", () => {
        const limited = { ...config, layout: "compact" as const, layouts: { dock: false } }
        expect(resolveLayout(limited, { layout: "dock" })).toBe("compact")
    })

    it("falls to classic when neither is allowed or nothing is chosen", () => {
        expect(resolveLayout({ ...config, layout: "dock", layouts: { dock: false, loadout: false } }, { layout: "loadout" })).toBe("classic")
        expect(resolveLayout(config, undefined)).toBe("classic")
        expect(resolveLayout(config, {})).toBe("classic")
        expect(resolveLayout({ ...config, layout: "nope" as never }, { layout: "nope" as never })).toBe("classic")
    })

    it("treats a missing layouts key as allowed", () => {
        expect(resolveLayout({ ...config, layouts: {} }, { layout: "loadout" })).toBe("loadout")
    })

    it("registers a component for every id", () => {
        for (const id of LAYOUT_IDS) expect(typeof LAYOUTS[id]).toBe("function")
    })
})

describe("layout in the app", () => {
    const snapshot = {
        sessionId: "s1", token: "t", revision: 1,
        player: { id: "player:1", label: "Pockets", type: "player", slots: 5, weight: 0, maxWeight: 1000, items: [] },
    }
    let root: Root
    let host: HTMLElement
    const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    const shell = () => host.querySelector("main.inventory-shell")!

    beforeEach(async () => {
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
        await act(async () => { root.render(<App />) })
        await post("kora_inventory:nui:sessionOpened", snapshot)
    })
    afterEach(() => { act(() => root.unmount()); host.remove() })

    it("defaults to classic and marks the shell with data-layout", () => {
        expect(shell().getAttribute("data-layout")).toBe("classic")
    })

    it("follows the server layout, then the player's allowed choice", async () => {
        await post("kora_inventory:nui:config", { layout: "compact" })
        expect(shell().getAttribute("data-layout")).toBe("compact")
        await post("kora_inventory:nui:layout", { layout: "dock" })
        expect(shell().getAttribute("data-layout")).toBe("dock")
        await post("kora_inventory:nui:config", { layouts: { dock: false } })
        expect(shell().getAttribute("data-layout")).toBe("compact")
        await post("kora_inventory:nui:config", { layouts: { dock: true }, playerLayoutChoice: false })
        expect(shell().getAttribute("data-layout")).toBe("compact")
    })

    it("ignores unknown ids and non-boolean allowances in the pushed config", async () => {
        await post("kora_inventory:nui:config", { layout: "../x", layouts: { dock: "no", loadout: false } })
        expect(shell().getAttribute("data-layout")).toBe("classic")
        await post("kora_inventory:nui:layout", { layout: "loadout" })
        expect(shell().getAttribute("data-layout")).toBe("classic")
        await post("kora_inventory:nui:layout", { layout: "dock" })
        expect(shell().getAttribute("data-layout")).toBe("dock")
    })
    it("renders every layout with a real transfer session and drag-and-drop provider", async () => {
        const secondary = { id: "stash:a", label: "Garage stash", type: "stash", slots: 5, weight: 0, maxWeight: 1000, items: [{ slot: 1, name: "water", label: "Water", amount: 2 }] }
        await post("kora_inventory:nui:sessionOpened", { ...snapshot, secondary })
        for (const layout of ["loadout", "compact", "dock"]) {
            await post("kora_inventory:nui:layout", { layout })
            expect(shell().getAttribute("data-layout")).toBe(layout)
            expect(host.querySelectorAll(".inventory-panel").length).toBeGreaterThanOrEqual(2)
            expect(host.querySelectorAll(".slot").length).toBe(10)
        }
    })
})
