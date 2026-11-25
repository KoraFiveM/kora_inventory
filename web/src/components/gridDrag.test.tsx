// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { TIPS_STORAGE_KEY } from "@/lib/tips"
import type { InventoryView } from "@/lib/types"
import App from "../App"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent } = vi.hoisted(() => ({ sendIntent: vi.fn(async (..._args: unknown[]) => ({ ok: true, pending: true })) }))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession: vi.fn(), pinQuickSlot: vi.fn() }))

const player: InventoryView = { id: "player:1", label: "Pockets", type: "player", slots: 11, gridColumns: 4, items: [
    { slot: 1, name: "bar", label: "Bar", amount: 1, gridWidth: 2, gridHeight: 1, gridBaseWidth: 2, gridBaseHeight: 1 },
    { slot: 7, name: "blocker", label: "Blocker", amount: 1 },
] }

describe("shaped inventory drags", () => {
    let root: Root
    let host: HTMLElement
    let hit: HTMLElement
    const slot = (label: string) => host.querySelector<HTMLButtonElement>(`[aria-label="${label}"]`)!
    const dragEvent = (type: string, target: HTMLElement, x: number) => act(() => {
        hit = target
        target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: 20, buttons: type === "mouseup" ? 0 : 1 }))
    })
    const pointAt = (target: HTMLElement, x: number) => dragEvent("mousemove", target, x)
    const footprint = (state: string) =>
        Array.from(host.querySelectorAll<HTMLElement>(`.grid-drop-${state}`), (cell) => [cell.style.gridColumn, cell.style.gridRow])

    beforeEach(async () => {
        window.localStorage.setItem(TIPS_STORAGE_KEY, JSON.stringify({ seen: [], dismissed: true, opens: 0 }))
        document.elementFromPoint = () => hit
        document.elementsFromPoint = () => [hit]
        sendIntent.mockClear()
        host = document.createElement("div")
        document.body.appendChild(host)
        root = createRoot(host)
        await act(async () => { root.render(<App />) })
        await act(async () => {
            window.dispatchEvent(new MessageEvent("message", { data: {
                action: "kora_inventory:nui:sessionOpened",
                data: { sessionId: "grid-drag", token: "t", revision: 7, secondaryRevision: 0, player },
            } }))
        })
    })

    afterEach(() => {
        act(() => root.unmount())
        host.remove()
        Reflect.deleteProperty(document, "elementFromPoint")
        Reflect.deleteProperty(document, "elementsFromPoint")
        window.localStorage.clear()
    })

    it("clips the edge preview, outlines a blocked rectangle, then rotates and commits under a stationary cursor", async () => {
        const source = slot("Bar, slot 1, grid footprint 2 by 1")
        const edge = slot("Empty slot 4")
        const target = slot("Empty slot 6")
        await dragEvent("mousedown", source, 10)
        await pointAt(source, 20)
        await pointAt(edge, 40)
        expect(footprint("edge")).toEqual([["4", "1"]])
        expect(host.textContent).toContain("Out of bounds")
        await pointAt(target, 60)
        expect(footprint("blocked")).toEqual([["2", "2"], ["3", "2"]])
        expect(host.textContent).toContain("Blocked")
        expect(document.querySelector(".grid-rotate-hint")?.textContent).toBe("R to rotate · 2 × 1")
        expect(sendIntent).not.toHaveBeenCalled()

        await act(async () => { window.dispatchEvent(new KeyboardEvent("keydown", { key: "r" })) })
        expect(footprint("fit")).toEqual([["2", "2"], ["2", "3"]])
        expect(document.querySelector(".grid-rotate-hint")?.textContent).toBe("R to rotate · 1 × 2")
        expect(sendIntent).not.toHaveBeenCalled()
        await dragEvent("mouseup", target, 60)

        expect(sendIntent.mock.calls[0]?.[0]).toMatchObject({ intent: "move", payload: {
            fromInventory: player.id, fromSlot: 1, toInventory: player.id, toSlot: 6, amount: 1, rotated: true, revision: 7,
        } })
        expect(host.querySelector(".grid-drop-cell")).toBeNull()
        expect(document.querySelector(".grid-rotate-hint")).toBeNull()
        expect(source.style.gridColumn).toBe("1 / span 2")
    })

    it("rejects release on a blocked footprint and accepts rotating in place on the next drag", async () => {
        const source = slot("Bar, slot 1, grid footprint 2 by 1")
        const blocked = slot("Empty slot 6")
        await dragEvent("mousedown", source, 10)
        await pointAt(source, 20)
        await pointAt(blocked, 60)
        await dragEvent("mouseup", blocked, 60)
        expect(sendIntent).not.toHaveBeenCalled()
        expect(host.querySelector(".grid-drop-cell")).toBeNull()

        await dragEvent("mousedown", source, 10)
        await pointAt(source, 20)
        await pointAt(source, 22)
        await act(async () => { window.dispatchEvent(new KeyboardEvent("keydown", { key: "r" })) })
        expect(footprint("fit")).toEqual([["1", "1"], ["1", "2"]])
        await dragEvent("mouseup", source, 22)
        expect(sendIntent.mock.calls[0]?.[0]).toMatchObject({ intent: "move", payload: {
            fromInventory: player.id, fromSlot: 1, toInventory: player.id, toSlot: 1, amount: 1, rotated: true,
        } })
    })
})
