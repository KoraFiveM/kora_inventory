import { describe, expect, it } from "vitest"
import { clampGiveAmount } from "./giveAmount"

describe("clampGiveAmount", () => {
    it("passes the picked amount through", () => expect(clampGiveAmount(3, 10)).toBe(3))
    it("clamps to the stack", () => expect(clampGiveAmount(99, 10)).toBe(10))
    it("clamps to at least one", () => {
        expect(clampGiveAmount(0, 10)).toBe(1)
        expect(clampGiveAmount(-4, 10)).toBe(1)
    })
    it("rounds fractions down and survives NaN", () => {
        expect(clampGiveAmount(2.9, 10)).toBe(2)
        expect(clampGiveAmount(NaN, 10)).toBe(1)
    })
})
