// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { setControls } = vi.hoisted(() => ({ setControls: vi.fn(async () => ({ ok: true })) }))
vi.mock("@/lib/nui", () => ({ setControls }))

import { DEFAULT_UI_CONFIG, UiConfigContext } from "@/context"
import { CONTROLS_STORAGE_KEY } from "@/lib/controls"
import { LocaleProvider } from "@/lib/locales"
import { ShortcutBar } from "./ShortcutBar"
import { TopBar } from "./TopBar"

describe("TopBar controls toggle", () => {
    let root: Root
    let host: HTMLElement
    const mount = async (controls = DEFAULT_UI_CONFIG.controls) => {
        await act(async () => {
            root.render(<LocaleProvider><UiConfigContext.Provider value={{ ...DEFAULT_UI_CONFIG, controls }}><TopBar transfer={false} query="" onQueryChange={() => undefined} onClose={() => undefined} /></UiConfigContext.Provider></LocaleProvider>)
        })
    }
    const toggle = () => host.querySelector<HTMLButtonElement>(".controls-toggle")
    const press = () => act(async () => { toggle()!.click() })

    beforeEach(() => {
        window.localStorage.clear()
        setControls.mockClear()
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
    })
    afterEach(() => { act(() => root.unmount()); host.remove(); window.localStorage.clear() })

    it("starts off, labelled Show controls, and asks Lua for nothing", async () => {
        await mount()
        expect(toggle()?.getAttribute("aria-pressed")).toBe("false")
        expect(toggle()?.getAttribute("aria-label")).toBe("Show controls")
        expect(toggle()?.title).toBe("Show controls")
        expect(setControls).not.toHaveBeenCalled()
    })

    it("toggles on and off through the NUI helper and remembers the choice", async () => {
        await mount()
        await press()
        expect(setControls).toHaveBeenLastCalledWith(true)
        expect(toggle()?.getAttribute("aria-pressed")).toBe("true")
        expect(toggle()?.getAttribute("aria-label")).toBe("Hide controls")
        expect(window.localStorage.getItem(CONTROLS_STORAGE_KEY)).toBe("true")
        await press()
        expect(setControls).toHaveBeenLastCalledWith(false)
        expect(toggle()?.getAttribute("aria-pressed")).toBe("false")
        expect(window.localStorage.getItem(CONTROLS_STORAGE_KEY)).toBe("false")
        expect(setControls).toHaveBeenCalledTimes(2)
    })

    it("re-shows the overlay on the next opening when it was left on", async () => {
        window.localStorage.setItem(CONTROLS_STORAGE_KEY, "true")
        await mount()
        expect(setControls).toHaveBeenCalledTimes(1)
        expect(setControls).toHaveBeenCalledWith(true)
        expect(toggle()?.getAttribute("aria-pressed")).toBe("true")
    })

    it("uses defaultVisible until the player has chosen, then their choice wins", async () => {
        await mount({ button: true, defaultVisible: true })
        expect(setControls).toHaveBeenCalledWith(true)
        await act(async () => { root.unmount() })
        root = createRoot(host)
        setControls.mockClear()
        window.localStorage.setItem(CONTROLS_STORAGE_KEY, "false")
        await mount({ button: true, defaultVisible: true })
        expect(setControls).not.toHaveBeenCalled()
        expect(toggle()?.getAttribute("aria-pressed")).toBe("false")
    })

    it("hides the button and never shows the overlay when button is off", async () => {
        window.localStorage.setItem(CONTROLS_STORAGE_KEY, "true")
        await mount({ button: false, defaultVisible: true })
        expect(toggle()).toBeNull()
        expect(setControls).not.toHaveBeenCalled()
    })
})

describe("ShortcutBar", () => {
    let root: Root
    let host: HTMLElement
    beforeEach(() => { host = document.createElement("div"); document.body.appendChild(host); root = createRoot(host) })
    afterEach(() => { act(() => root.unmount()); host.remove() })
    const mount = (movePending: boolean) => act(async () => { root.render(<LocaleProvider><ShortcutBar movePending={movePending} /></LocaleProvider>) })

    it("renders nothing when no move is pending", async () => {
        await mount(false)
        expect(host.innerHTML).toBe("")
    })

    it("shows only a subtle status while a move is pending, with no hint chips", async () => {
        await mount(true)
        expect(host.textContent).toBe("Updating inventory…")
        expect(host.querySelector("kbd")).toBeNull()
    })
})
