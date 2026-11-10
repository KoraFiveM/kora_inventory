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

const snapshot = {
    sessionId: "s1", token: "t", revision: 1,
    player: { id: "player:1", label: "Pockets", type: "player", slots: 10, weight: 0, maxWeight: 1000, items: [{ slot: 2, name: "weapon_pistol", label: "Pistol", amount: 1, weight: 1000, info: { serial: "KORA-PISTOL-1", ammo: 12 } }] },
}

let root: Root
let host: HTMLElement
let copied: string[]
const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
const select = () => act(() => host.querySelector<HTMLButtonElement>('button[aria-label^="Pistol"]')!.click())
const copyButton = () => host.querySelector<HTMLButtonElement>(".detail-copy")
const inspector = () => host.querySelector(".item-detail")!

beforeEach(async () => {
    copied = []
    // CEF-like: no navigator.clipboard, only the textarea + execCommand path.
    Object.defineProperty(navigator, "clipboard", { value: undefined, configurable: true })
    document.execCommand = vi.fn(() => {
        copied.push((document.activeElement as HTMLTextAreaElement).value)
        return true
    })
    host = document.createElement("div"); document.body.appendChild(host)
    root = createRoot(host)
    await act(async () => { root.render(<App />) })
    await post("kora_inventory:nui:sessionOpened", snapshot)
})
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks() })

describe("item inspector copy", () => {
    it("makes the selected item's details selectable and copies it as JSON", async () => {
        expect(copyButton()).toBeNull()
        select()
        expect(inspector().classList.contains("item-detail-copyable")).toBe(true)
        await act(async () => { copyButton()!.click() })
        expect(copied).toHaveLength(1)
        expect(JSON.parse(copied[0])).toMatchObject({
            label: "Pistol", name: "weapon_pistol", amount: 1, slot: 2, inventory: "player:1",
            metadata: { serial: "KORA-PISTOL-1", ammo: 12 },
        })
        expect(copyButton()!.textContent).toBe("Copied")
        expect(sendIntent).not.toHaveBeenCalled()
    })

    it("Config.Inspector.allowCopy = false hides the button and keeps the text unselectable", async () => {
        await post("kora_inventory:nui:config", { inspectorCopy: false })
        select()
        expect(copyButton()).toBeNull()
        expect(inspector().classList.contains("item-detail-copyable")).toBe(false)
    })

    it("renders a long metadata value in full and keeps the card's controls", async () => {
        const handsetId = `78c4250bdd6f484629f3ef9103942b1a${"f".repeat(40)}`
        const [item] = snapshot.player.items
        await post("kora_inventory:nui:sessionOpened", { ...snapshot, player: { ...snapshot.player, items: [{ ...item, displayMeta: [{ key: "handsetId", label: "Handset Id", value: handsetId }] }] } })
        select()
        expect(inspector().textContent).toContain(handsetId)
        expect(copyButton()).not.toBeNull()
        expect(inspector().querySelector(".detail-close")).not.toBeNull()
        const css = readFileSync(`${process.cwd()}/src/styles.css`, "utf8")
        expect(css).toMatch(/\.item-detail \{ padding: 14px; display: grid; grid-template-columns: minmax\(0, 1fr\);/)
        expect(css).toMatch(/dt, dd \{ min-width: 0; overflow-wrap: anywhere; \}/)
    })

    it("only the inspector opts back into text selection", () => {
        const css = readFileSync(`${process.cwd()}/src/styles.css`, "utf8")
        expect(css).toMatch(/html, body, #root, #root \* \{ -webkit-user-select: none; user-select: none; \}/)
        expect(css).toMatch(/#root \.item-detail-copyable :is\(h1, p, dl, dt, dd\) \{ -webkit-user-select: text; user-select: text;/)
    })
})
