import { describe, expect, it } from "vitest"
import { DEFAULT_PLAYER_LAYOUT, drawerPlacement, layoutOffsetPx, normalizePlayerLayout, onScreenNudge } from "./playerLayout"

describe("player layout", () => {
    it("clamps and defaults every field", () => {
        expect(normalizePlayerLayout(null)).toEqual(DEFAULT_PLAYER_LAYOUT)
        expect(normalizePlayerLayout({ x: 9, y: "a", scale: 4, playerSide: "up", useForTransfer: "yes" }))
            .toEqual({ x: 1, y: 0, scale: 1.25, playerSide: "left", useForTransfer: false, layout: undefined })
    })

    it("accepts only known layout ids", () => {
        expect(DEFAULT_PLAYER_LAYOUT.layout).toBeUndefined()
        for (const id of ["classic", "loadout", "compact", "dock"]) {
            expect(normalizePlayerLayout({ layout: id }).layout).toBe(id)
        }
        for (const bad of ["Classic", "../evil", "", 4, null, {}, undefined]) {
            expect(normalizePlayerLayout({ layout: bad }).layout).toBeUndefined()
        }
        expect(normalizePlayerLayout({ layout: "dock", x: 0.5 })).toMatchObject({ layout: "dock", x: 0.5 })
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

describe("drawerPlacement", () => {
    const viewport = { width: 1920, height: 1080 }
    const rect = (left: number) => ({ left, top: 100, width: 1000, height: 700 })
    const still = { x: 0, y: 0 }

    it("keeps the preferred edge when it has room, and the union grows on that side", () => {
        const left = drawerPlacement(rect(300), still, 94, "left", viewport, 1)
        expect(left).toMatchObject({ side: "left", flipped: false, rect: { left: 206, width: 1094 } })
        const right = drawerPlacement(rect(300), still, 94, "right", viewport, 1)
        expect(right).toMatchObject({ side: "right", flipped: false, rect: { left: 300, width: 1094 } })
    })

    it("flips to the other edge when the preferred one runs off screen and the other fits", () => {
        const flipped = drawerPlacement(rect(40), still, 94, "left", viewport, 1)
        expect(flipped).toMatchObject({ side: "right", flipped: true, rect: { left: 40, width: 1094 } })
        expect(drawerPlacement(rect(860), still, 94, "right", viewport, 1)).toMatchObject({ side: "left", flipped: true })
    })

    it("keeps the preferred edge when neither fits, so the on-screen nudge can move the window", () => {
        const wide = { left: 40, top: 0, width: 1800, height: 700 }
        expect(drawerPlacement(wide, still, 94, "left", viewport, 1)).toMatchObject({ side: "left", flipped: false })
    })

    it("decides on the un-nudged position", () => {
        // The window sits at 134 only because it was nudged 94 right: un-nudged it is at 40.
        expect(drawerPlacement(rect(134), { x: 94, y: 0 }, 94, "left", viewport, 1).flipped).toBe(true)
    })

    it("combines with the nudge: a window plus drawer is kept entirely on screen", () => {
        const { rect: union } = drawerPlacement(rect(40), still, 94, "left", { width: 1060, height: 1080 }, 1)
        expect(onScreenNudge(union, still, { width: 1060, height: 1080 }, 1).x).toBe(54)
    })
})
