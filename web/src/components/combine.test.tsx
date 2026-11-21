// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent, closeSession, backend } = vi.hoisted(() => {
    // A drag backend that only records what is registered, so a drag can be run
    // through react-dnd's own manager without pointer events.
    const sources = new Map<unknown, unknown>()
    const targets = new Map<unknown, unknown>()
    const state: { manager?: { getActions: () => { beginDrag: (ids: unknown[]) => void; hover: (ids: unknown[]) => void; drop: () => void; endDrag: () => void }; getMonitor: () => { isDragging: () => boolean } } } = {}
    const factory = (manager: never) => {
        state.manager = manager
        return {
            setup() {}, teardown() {},
            connectDragSource(id: unknown, node?: unknown) { sources.set(id, node); return () => sources.delete(id) },
            connectDragPreview() { return () => undefined },
            connectDropTarget(id: unknown, node?: unknown) { targets.set(id, node); return () => targets.delete(id) },
            profile: () => ({}),
        }
    }
    const idOf = (map: Map<unknown, unknown>, node: Element | null) => [...map.entries()].find(([, n]) => n === node)?.[0]
    return {
        sendIntent: vi.fn(async (..._args: unknown[]): Promise<{ ok: boolean; error?: string }> => ({ ok: true })),
        closeSession: vi.fn(async (..._args: unknown[]) => undefined),
        backend: { factory, state, sources, targets, idOf },
    }
})
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession }))
vi.mock("react-dnd-touch-backend", () => ({ TouchBackend: backend.factory }))

import App from "../App"
import type { InventoryItem, InventoryView, SessionSnapshot } from "@/lib/types"

const item = (slot: number, name: string, label: string, amount = 1): InventoryItem => ({ slot, name, label, amount, weight: 1 })
const view = (id: string, items: InventoryItem[], extra: Partial<InventoryView> = {}): InventoryView =>
    ({ id, label: id, type: "player", slots: 10, weight: 0, maxWeight: 1000, items, ...extra })
const player = view("player:1", [
    item(1, "rolling_paper", "Rolling Paper", 3),
    item(2, "weed", "Weed", 2),
    item(3, "water_bottle", "Water Bottle"),
])
const stash = view("stash:1", [item(5, "weed", "Stash Weed", 4)], { type: "stash" })
const snapshot = (secondary?: InventoryView): SessionSnapshot => ({ sessionId: "s1", token: "t", revision: 7, player, secondary })

let root: Root
let host: HTMLElement
const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
const slot = (label: string) => host.querySelector(`button[aria-label^="${label}"]`)
const dialog = () => host.querySelector('[role="dialog"]')
const buttonNamed = (name: string) => [...host.querySelectorAll<HTMLButtonElement>('[role="dialog"] button')].find((button) => button.textContent === name)!
const intents = () => sendIntent.mock.calls.map(([call]) => call as { intent: string; payload: Record<string, unknown> })

function drag(from: Element | null, to: Element | null) {
    const sourceId = backend.idOf(backend.sources, from)
    const targetId = backend.idOf(backend.targets, to)
    expect(sourceId).toBeDefined()
    expect(targetId).toBeDefined()
    const actions = backend.state.manager!.getActions()
    act(() => { actions.beginDrag([sourceId]) })
    act(() => { actions.hover([targetId]) })
    act(() => { actions.drop() })
    act(() => { actions.endDrag() })
}

beforeEach(async () => {
    sendIntent.mockClear(); closeSession.mockClear()
    host = document.createElement("div"); document.body.appendChild(host)
    root = createRoot(host)
    await act(async () => { root.render(<App />) })
    await post("kora_inventory:nui:sessionOpened", snapshot())
})
afterEach(async () => { await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)) }); act(() => root.unmount()); host.remove(); backend.sources.clear(); backend.targets.clear(); vi.restoreAllMocks() })

describe("dropping one item onto another", () => {
    it("asks before combining a recipe pair instead of swapping", () => {
        drag(slot("Rolling Paper"), slot("Weed"))
        expect(dialog()).not.toBeNull()
        expect(dialog()!.textContent).toContain("Roll a joint?")
        expect(dialog()!.textContent).toContain("Rolling Paper + Weed")
        expect(sendIntent).not.toHaveBeenCalled()
    })

    it("works in either drag order", () => {
        drag(slot("Weed"), slot("Rolling Paper"))
        expect(dialog()!.textContent).toContain("Roll a joint?")
        expect(sendIntent).not.toHaveBeenCalled()
    })

    it("Cancel leaves both slots alone and sends nothing", () => {
        drag(slot("Rolling Paper"), slot("Weed"))
        act(() => buttonNamed("Cancel").click())
        expect(dialog()).toBeNull()
        expect(sendIntent).not.toHaveBeenCalled()
        expect(slot("Rolling Paper")).not.toBeNull()
        expect(slot("Weed")).not.toBeNull()
    })

    it("Escape and a click outside dismiss it without closing the inventory", () => {
        drag(slot("Rolling Paper"), slot("Weed"))
        act(() => { window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })) })
        expect(dialog()).toBeNull()
        expect(closeSession).not.toHaveBeenCalled()
        drag(slot("Rolling Paper"), slot("Weed"))
        act(() => host.querySelector('[data-testid="combine-backdrop"]')!.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })))
        expect(dialog()).toBeNull()
        expect(sendIntent).not.toHaveBeenCalled()
    })

    it("Combine sends only the two slots and the revision", () => {
        drag(slot("Rolling Paper"), slot("Weed"))
        act(() => buttonNamed("Combine").click())
        expect(dialog()).toBeNull()
        expect(intents()).toHaveLength(1)
        const [sent] = intents()
        expect(sent.intent).toBe("combine")
        expect(sent.payload).toEqual({ inventory: "player:1", fromSlot: 1, toSlot: 2, revision: 7 })
        expect(Object.keys(sent.payload)).not.toContain("recipe")
        expect(Object.keys(sent.payload)).not.toContain("amount")
    })

    it("a pair with no recipe behaves exactly as before", () => {
        drag(slot("Rolling Paper"), slot("Water Bottle"))
        expect(dialog()).toBeNull()
        expect(intents().map((call) => call.intent)).toEqual(["move"])
    })

    it("dropping on an empty slot is a plain move", () => {
        drag(slot("Rolling Paper"), host.querySelector('button[aria-label="Empty slot 6"]'))
        expect(dialog()).toBeNull()
        expect(intents().map((call) => call.intent)).toEqual(["move"])
    })

    it("only applies inside the player's own inventory", async () => {
        await post("kora_inventory:nui:sessionOpened", snapshot(stash))
        drag(slot("Rolling Paper"), slot("Stash Weed"))
        expect(dialog()).toBeNull()
        expect(intents().map((call) => call.intent)).toEqual(["move"])
    })

    it("is off when the server says combining is disabled", async () => {
        await post("kora_inventory:nui:config", { combine: { enabled: false, recipes: [{ a: "rolling_paper", b: "weed", label: "Roll a joint" }] } })
        drag(slot("Rolling Paper"), slot("Weed"))
        expect(dialog()).toBeNull()
        expect(intents().map((call) => call.intent)).toEqual(["move"])
    })

    it("uses the recipe list the server pushed", async () => {
        await post("kora_inventory:nui:config", { combine: { enabled: true, recipes: [{ a: "water_bottle", b: "weed", label: "Brew tea" }] } })
        drag(slot("Water Bottle"), slot("Weed"))
        expect(dialog()!.textContent).toContain("Brew tea?")
        act(() => buttonNamed("Cancel").click())
        drag(slot("Rolling Paper"), slot("Weed"))
        expect(dialog()).toBeNull()
    })

    it("a closed session drops a pending popover", async () => {
        drag(slot("Rolling Paper"), slot("Weed"))
        expect(dialog()).not.toBeNull()
        await post("kora_inventory:nui:sessionClosed", { sessionId: "s1" })
        expect(dialog()).toBeNull()
    })
})
