// @vitest-environment jsdom
import { describe, expect, it } from "vitest"
import { watchDragRelease } from "./dragReset"

function setup() {
    const state = { dragging: true, cancels: 0 }
    const stop = watchDragRelease(window, () => state.dragging, () => { state.cancels++; state.dragging = false })
    return { state, stop }
}

describe("watchDragRelease", () => {
    it("resets on mouseup outside the slots", () => {
        const { state, stop } = setup()
        window.dispatchEvent(new MouseEvent("mouseup"))
        expect(state.cancels).toBe(1)
        stop()
    })

    it("resets when the button was released elsewhere (mousemove with no buttons)", () => {
        const { state, stop } = setup()
        window.dispatchEvent(new MouseEvent("mousemove", { buttons: 1 }))
        expect(state.cancels).toBe(0)
        window.dispatchEvent(new MouseEvent("mousemove", { buttons: 0 }))
        expect(state.cancels).toBe(1)
        stop()
    })

    it("resets on dragend, Escape and focus loss", () => {
        for (const fire of [
            () => window.dispatchEvent(new Event("dragend")),
            () => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })),
            () => window.dispatchEvent(new Event("blur")),
        ]) {
            const { state, stop } = setup()
            fire()
            expect(state.cancels).toBe(1)
            stop()
        }
    })

    it("ignores other keys and idle state", () => {
        const { state, stop } = setup()
        window.dispatchEvent(new KeyboardEvent("keydown", { key: "a" }))
        expect(state.cancels).toBe(0)
        state.dragging = false
        window.dispatchEvent(new MouseEvent("mouseup"))
        expect(state.cancels).toBe(0)
        stop()
    })

    it("stops listening once removed (inventory closed)", () => {
        const { state, stop } = setup()
        stop()
        window.dispatchEvent(new MouseEvent("mouseup"))
        expect(state.cancels).toBe(0)
    })
})
