import { describe, expect, it } from "vitest"
import { formatMetaValue } from "./format"

describe("formatMetaValue", () => {
    it("rounds float drift to the configured decimals and drops trailing zeros", () => {
        expect(formatMetaValue(92.70000000000044, 1)).toBe("92.7")
        expect(formatMetaValue(92.70000000000044, 0)).toBe("93")
        expect(formatMetaValue(99.96, 1)).toBe("100")
        expect(formatMetaValue(12.345, 2)).toBe("12.35")
    })

    it("leaves integers, strings, booleans and objects alone", () => {
        expect(formatMetaValue(100, 1)).toBe("100")
        expect(formatMetaValue("KORA-123", 1)).toBe("KORA-123")
        expect(formatMetaValue(true, 1)).toBe("true")
        expect(formatMetaValue({ a: 1 }, 1)).toBe('{"a":1}')
    })

    it("clamps odd decimals", () => {
        expect(formatMetaValue(1.23456, -2)).toBe("1")
        expect(formatMetaValue(1.23456, 9)).toBe("1.235")
    })
})
