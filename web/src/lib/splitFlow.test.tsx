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

import { readFileSync } from "node:fs"
import App from "../App"
import { parseSplitAmount } from "./split"

const snapshot = {
    sessionId: "s1", token: "t", revision: 1,
    player: { id: "player:1", label: "Pockets", type: "player", slots: 10, weight: 0, maxWeight: 1000, items: [{ slot: 1, name: "coca_leaf", label: "Coca Leaf", amount: 2, weight: 1 }] },
}

let root: Root
let host: HTMLElement
const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
const slot = () => host.querySelector<HTMLButtonElement>('button[aria-label^="Coca Leaf"]')!
const rightClick = () => act(() => { slot().dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
const key = (k: string) => act(() => { window.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true })) })
const dialog = () => host.querySelector('[role="dialog"]')

beforeEach(async () => {
    sendIntent.mockClear(); closeSession.mockClear()
    vi.spyOn(window, "prompt").mockImplementation(() => { throw new Error("window.prompt blocks CEF and must never be used") })
    host = document.createElement("div"); document.body.appendChild(host)
    root = createRoot(host)
    await act(async () => { root.render(<App />) })
    await post("qbinventory:nui:sessionOpened", snapshot)
})
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks() })

describe("parseSplitAmount", () => {
    it("accepts 1..stack-1 and rejects the rest", () => {
        expect(parseSplitAmount("1", 2)).toEqual({ amount: 1 })
        for (const bad of ["", "0", "2", "1.5", "abc", "-1"]) expect("error" in parseSplitAmount(bad, 2)).toBe(true)
    })
})

describe("right-click split", () => {
    it("opens a visible dialog instead of window.prompt", () => {
        rightClick()
        expect(dialog()).not.toBeNull()
        expect(host.querySelector("input[type=number]")).not.toBeNull()
    })

    it("Escape cancels only the dialog; the inventory stays open and interactive", () => {
        rightClick(); key("Escape")
        expect(dialog()).toBeNull()
        expect(closeSession).not.toHaveBeenCalled()
        act(() => slot().click())
        expect(slot().getAttribute("aria-pressed")).toBe("true")
        key("Escape")
        expect(closeSession).toHaveBeenCalledTimes(1)
    })

    it("Cancel, backdrop click and right-click on the backdrop dismiss it", () => {
        rightClick(); act(() => (Array.from(host.querySelectorAll("button")).find((b) => b.textContent === "Cancel")!).click())
        expect(dialog()).toBeNull()
        rightClick(); act(() => host.querySelector('[data-testid="split-backdrop"]')!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })))
        expect(dialog()).toBeNull()
        rightClick(); act(() => host.querySelector('[data-testid="split-backdrop"]')!.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })))
        expect(dialog()).toBeNull()
        expect(sendIntent).not.toHaveBeenCalled()
    })

    it("confirm sends one move into an empty slot and closes the dialog", async () => {
        rightClick()
        await act(async () => { host.querySelector("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })) })
        expect(dialog()).toBeNull()
        expect(sendIntent).toHaveBeenCalledTimes(1)
        const call = sendIntent.mock.calls[0] as unknown as [{ intent: string; payload: Record<string, unknown> }]
        expect(call[0].intent).toBe("move")
        expect(call[0].payload).toMatchObject({ fromSlot: 1, toSlot: 2, amount: 1 })
    })

    it("a server patch dismisses the dialog and the inventory stays usable", async () => {
        rightClick()
        await post("qbinventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: snapshot.player })
        expect(dialog()).toBeNull()
        await post("qbinventory:nui:rejected", { reason: "nope" })
        rightClick()
        expect(dialog()).not.toBeNull()
    })

    it("does nothing when rightClickSplit is disabled", async () => {
        await post("qbinventory:nui:config", { rightClickSplit: false })
        rightClick()
        expect(dialog()).toBeNull()
    })

    const btn = (text: string) => Array.from(host.querySelectorAll("button")).find((b) => b.textContent === text)!
    const mouseClick = (el: Element) => act(() => {
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, button: 0 }))
    })

    it("a full mouse click on Cancel closes the dialog without sending anything", () => {
        rightClick(); mouseClick(btn("Cancel"))
        expect(dialog()).toBeNull()
        expect(sendIntent).not.toHaveBeenCalled()
    })

    it("a full mouse click on Split sends the split", async () => {
        rightClick()
        await act(async () => { mouseClick(btn("Split")) })
        expect(dialog()).toBeNull()
        expect(sendIntent).toHaveBeenCalledTimes(1)
    })

    it("Enter in the input confirms", async () => {
        rightClick()
        await act(async () => { host.querySelector("form")!.requestSubmit() })
        expect(sendIntent).toHaveBeenCalledTimes(1)
    })

    it("the backdrop re-enables pointer events (html/body/#root are pointer-events:none in CEF)", () => {
        const css = readFileSync(`${process.cwd()}/src/styles.css`, "utf8")
        const rule = css.match(/^\.split-backdrop\s*\{([^}]*)\}/m)?.[1] ?? ""
        expect(rule).toMatch(/pointer-events:\s*auto/)
    })
})
