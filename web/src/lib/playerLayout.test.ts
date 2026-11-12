import { describe, expect, it } from "vitest"
import { DEFAULT_PLAYER_LAYOUT, layoutOffsetPx, normalizePlayerLayout, onScreenNudge } from "./playerLayout"

describe("player layout", () => {
    it("clamps and defaults every field", () => {
        expect(normalizePlayerLayout(null)).toEqual(DEFAULT_PLAYER_LAYOUT)
        expect(normalizePlayerLayout({ x: 9, y: "a", scale: 4, playerSide: "up", useForTransfer: "yes" }))
            .toEqual({ x: 1, y: 0, scale: 1.25, playerSide: "left", useForTransfer: false })
    })

    it("keeps the transfer view centred unless the player opted in", () => {
        const layout = normalizePlayerLayout({ x: 0.1, y: -0.2, scale: 1 })
        expect(layoutOffsetPx(layout, false, { width: 1920, height: 1080 })).toEqual({ x: 192, y: -216 })
        expect(layoutOffsetPx(layout, true, { width: 1920, height: 1080 })).toEqual({ x: 0, y: 0 })
        expect(layoutOffsetPx({ ...layout, useForTransfer: true }, true, { width: 1920, height: 1080 })).toEqual({ x: 192, y: -216 })
    })

    it("nudges a box back on screen and leaves an on-screen box alone", () => {
        const viewport = { width: 1920, height: 1080 }
        expect(onScreenNudge({ left: 100, top: 100, width: 500, height: 500 }, { x: 0, y: 0 }, viewport, 1)).toEqual({ x: 0, y: 0 })
        expect(onScreenNudge({ left: 1700, top: -50, width: 500, height: 500 }, { x: 0, y: 0 }, viewport, 1)).toEqual({ x: -280, y: 50 })
        // Measured from the un-nudged box: at root scale 2, 280 screen px is 140 root px.
        expect(onScreenNudge({ left: 1140, top: 0, width: 500, height: 500 }, { x: -280, y: 0 }, viewport, 2).x).toBe(-140)
    })
})
