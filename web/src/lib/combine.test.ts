import { describe, expect, it } from "vitest"
import { DEFAULT_COMBINE, findCombination, mergeCombine, sanitizeRecipes, type CombineConfig } from "./combine"

const config: CombineConfig = {
    enabled: true,
    recipes: [
        { a: "rolling_paper", b: "weed", label: "Roll a joint" },
        { a: "water_bottle", b: "sandwich", label: "Make a picnic" },
    ],
}
const item = (name: string) => ({ name })

describe("findCombination", () => {
    it("finds the recipe for a pair", () => {
        expect(findCombination(item("rolling_paper"), item("weed"), config)?.label).toBe("Roll a joint")
    })
    it("is order independent", () => {
        expect(findCombination(item("weed"), item("rolling_paper"), config)?.label).toBe("Roll a joint")
        expect(findCombination(item("sandwich"), item("water_bottle"), config)?.label).toBe("Make a picnic")
    })
    it("ignores case and surrounding spaces", () => {
        expect(findCombination(item(" WEED "), item("Rolling_Paper"), config)).not.toBeNull()
    })
    it("returns null for a pair with no recipe", () => {
        expect(findCombination(item("weed"), item("sandwich"), config)).toBeNull()
        expect(findCombination(item("rolling_paper"), item("rolling_paper"), config)).toBeNull()
    })
    it("never combines an item with its own kind, even if a recipe names it twice", () => {
        const odd: CombineConfig = { enabled: true, recipes: [{ a: "weed", b: "weed", label: "Twice" }] }
        expect(findCombination(item("weed"), item("weed"), odd)).toBeNull()
    })
    it("returns null when combining is disabled", () => {
        expect(findCombination(item("rolling_paper"), item("weed"), { ...config, enabled: false })).toBeNull()
    })
    it("returns null when either slot is empty or malformed", () => {
        expect(findCombination(undefined, item("weed"), config)).toBeNull()
        expect(findCombination(item("weed"), undefined, config)).toBeNull()
        expect(findCombination({ name: 5 as unknown as string }, item("weed"), config)).toBeNull()
        expect(findCombination(item(""), item("weed"), config)).toBeNull()
    })
    it("returns null with no recipes", () => {
        expect(findCombination(item("rolling_paper"), item("weed"), { enabled: true, recipes: [] })).toBeNull()
    })
    it("ships with the rolling paper and weed recipe", () => {
        expect(findCombination(item("rolling_paper"), item("weed"), DEFAULT_COMBINE)?.label).toBe("Roll a joint")
    })
})

describe("sanitizeRecipes", () => {
    it("keeps well formed rows and drops the rest", () => {
        expect(sanitizeRecipes([
            { a: "x", b: "y", label: "Mix" },
            { a: "x" },
            null,
            "text",
            { a: "", b: "y" },
            { a: "p", b: "q" },
        ])).toEqual([{ a: "x", b: "y", label: "Mix" }, { a: "p", b: "q", label: "Combine" }])
    })
    it("accepts nothing but an array", () => {
        expect(sanitizeRecipes(undefined)).toEqual([])
        expect(sanitizeRecipes({ a: "x", b: "y" })).toEqual([])
    })
    it("does not carry extra fields such as amounts to the browser", () => {
        const [row] = sanitizeRecipes([{ a: "x", b: "y", label: "Mix", result: "z", amount: 5 }])
        expect(Object.keys(row).sort()).toEqual(["a", "b", "label"])
    })
})

describe("mergeCombine", () => {
    it("takes a pushed table", () => {
        expect(mergeCombine(DEFAULT_COMBINE, { enabled: false, recipes: [{ a: "x", b: "y", label: "Mix" }] }))
            .toEqual({ enabled: false, recipes: [{ a: "x", b: "y", label: "Mix" }] })
    })
    it("keeps what it has when the push is absent or malformed", () => {
        expect(mergeCombine(DEFAULT_COMBINE, undefined)).toBe(DEFAULT_COMBINE)
        expect(mergeCombine(DEFAULT_COMBINE, "nope")).toBe(DEFAULT_COMBINE)
        expect(mergeCombine(DEFAULT_COMBINE, { enabled: "yes", recipes: "all" })).toEqual(DEFAULT_COMBINE)
    })
    it("lets a push clear every recipe", () => {
        expect(mergeCombine(DEFAULT_COMBINE, { recipes: [] }).recipes).toEqual([])
    })
})
