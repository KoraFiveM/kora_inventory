// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { DndProvider } from "react-dnd"
import { TouchBackend } from "react-dnd-touch-backend"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

// Lets a test say "an item is being dragged" without running a real drag.
const { drag } = vi.hoisted(() => ({ drag: { active: false } }))
vi.mock("react-dnd", async (original) => ({ ...(await original<typeof import("react-dnd")>()), useDragLayer: () => drag.active }))

vi.mock("@/lib/nui", () => ({ sendIntent: vi.fn(async () => ({ ok: true })), closeSession: vi.fn(async () => undefined), pinQuickSlot: vi.fn(async () => ({ ok: true })) }))

import App from "../App"
import { DEFAULT_UI_CONFIG, UiConfigContext } from "@/context"
import { LocaleProvider } from "@/lib/locales"
import { TIPS_STORAGE_KEY } from "@/lib/tips"
import { TipCard } from "./TipCard"

const stored = () => JSON.parse(window.localStorage.getItem(TIPS_STORAGE_KEY) ?? "null")
let counter = 0

describe("TipCard", () => {
    let root: Root
    let host: HTMLElement
    const mount = async (config = DEFAULT_UI_CONFIG, sessionId = `tip-${++counter}`, quick = true) => {
        await act(async () => {
            root.render(<DndProvider backend={TouchBackend}><LocaleProvider><UiConfigContext.Provider value={config}><TipCard sessionId={sessionId} quickSlotsEnabled={quick} /></UiConfigContext.Provider></LocaleProvider></DndProvider>)
        })
        return sessionId
    }
    const card = () => host.querySelector(".tip-card")
    const click = (text: string) => act(async () => { Array.from(host.querySelectorAll("button")).find((b) => b.textContent === text)!.click() })

    beforeEach(() => {
        window.localStorage.clear()
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
    })
    afterEach(() => { act(() => root.unmount()); host.remove(); window.localStorage.clear() })

    it("shows the first tip on a first opening and remembers it", async () => {
        await mount()
        expect(card()?.textContent).toContain("Drag an item out of the window")
        expect(stored()).toEqual({ seen: ["drag_drop"], dismissed: false, opens: 1 })
    })

    it("Next cycles through tips and records each as seen", async () => {
        await mount()
        await click("Next")
        expect(card()?.textContent).toContain("Shift+click")
        expect(stored().seen).toEqual(["drag_drop", "quick_transfer"])
    })

    it("Got it dismisses for good", async () => {
        const id = await mount()
        await click("Got it")
        expect(card()).toBeNull()
        expect(stored().dismissed).toBe(true)
        // A later opening shows nothing.
        await act(async () => { root.unmount() })
        root = createRoot(host)
        await mount(DEFAULT_UI_CONFIG, `${id}-later`)
        expect(card()).toBeNull()
    })

    it("stops after maxShows openings", async () => {
        const config = { ...DEFAULT_UI_CONFIG, tips: { enabled: true, maxShows: 2 } }
        await mount(config); await mount(config)
        expect(card()).not.toBeNull()
        await mount(config)
        expect(card()).toBeNull()
        expect(stored().opens).toBe(3)
    })

    it("does not count a remount of the same session as a new opening", async () => {
        const id = await mount()
        await mount(DEFAULT_UI_CONFIG, id)
        expect(stored().opens).toBe(1)
        expect(card()).not.toBeNull()
    })

    it("shows nothing when disabled", async () => {
        await mount({ ...DEFAULT_UI_CONFIG, tips: { enabled: false, maxShows: 5 } })
        expect(card()).toBeNull()
        expect(stored()).toBeNull()
    })

    it("only offers tips for enabled features", async () => {
        const config = { ...DEFAULT_UI_CONFIG, quickTransfer: false, modifierDrag: false, rightClick: "none" as const, organize: { enabled: false, sort: false, stack: false, panelSearch: false }, playerLayoutChoice: false }
        await mount(config, undefined, false)
        expect(card()?.textContent).toContain("Drag an item out")
        // With one tip left there is nothing to go Next to.
        expect(Array.from(host.querySelectorAll("button")).map((b) => b.textContent)).toEqual(["Got it"])
    })

    it("never shows while an item is being dragged", async () => {
        drag.active = true
        try {
            const id = await mount()
            expect(card()).toBeNull()
            // Dropping it again brings the same tip back.
            drag.active = false
            await mount(DEFAULT_UI_CONFIG, id)
            expect(card()?.textContent).toContain("Drag an item out")
        } finally {
            drag.active = false
        }
    })
})

describe("TipCard inside the window", () => {
    let root: Root
    let host: HTMLElement
    beforeEach(() => { window.localStorage.clear(); host = document.createElement("div"); document.body.appendChild(host); root = createRoot(host) })
    afterEach(() => { act(() => root.unmount()); host.remove(); window.localStorage.clear() })

    it("appears in every layout and respects the pushed config", async () => {
        const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
        await act(async () => { root.render(<App />) })
        await post("kora_inventory:nui:config", { tips: { enabled: true, maxShows: 5 }, organize: { enabled: true, sort: true, stack: true, panelSearch: true } })
        await post("kora_inventory:nui:sessionOpened", { sessionId: "tips-app", token: "t", revision: 1, player: { id: "player:1", label: "Pockets", type: "player", slots: 5, weight: 0, maxWeight: 1000, items: [] } })
        for (const layout of ["classic", "loadout", "compact", "dock"]) {
            await post("kora_inventory:nui:layout", { layout })
            expect(host.querySelector("main.inventory-shell .tip-card"), layout).not.toBeNull()
        }
        await post("kora_inventory:nui:config", { tips: { enabled: false, maxShows: 5 } })
        expect(host.querySelector(".tip-card")).toBeNull()
    })
})
