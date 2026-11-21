/**
 * Drag-one-item-onto-another combining, presentation side.
 *
 * The browser only ever knows each recipe's two item names and its label
 * (Config.kora_inventory.combine.recipes plus whatever other resources register,
 * pushed on `kora_inventory:nui:config`). It uses that list for one decision:
 * ask "Roll a joint? Combine / Cancel" instead of swapping two slots. Amounts,
 * results and permission are the server's: the `combine` intent carries only
 * the two slots, and the server looks the recipe up from its own registry.
 */

export interface CombineRecipe {
    a: string
    b: string
    label: string
}

export interface CombineConfig {
    enabled: boolean
    recipes: CombineRecipe[]
}

/** Mirrors the shipped config.lua so the dev harness (which pushes no config) behaves like a fresh install. */
export const DEFAULT_COMBINE: CombineConfig = {
    enabled: true,
    recipes: [{ a: "rolling_paper", b: "weed", label: "Roll a joint" }],
}

interface Named {
    name: string
}

const normalise = (name: string) => name.trim().toLowerCase()

/**
 * The recipe for dropping `dragged` onto `target`, or null when the drop is an
 * ordinary move/swap/stack. Order does not matter (a + b is b + a), and the two
 * items must differ: dropping an item on its own kind stacks as always.
 */
export function findCombination(dragged: Named | undefined, target: Named | undefined, config: CombineConfig): CombineRecipe | null {
    if (!config.enabled || !dragged || !target) return null
    if (typeof dragged.name !== "string" || typeof target.name !== "string") return null
    const first = normalise(dragged.name)
    const second = normalise(target.name)
    if (first === "" || second === "" || first === second) return null
    for (const recipe of config.recipes) {
        const a = normalise(recipe.a)
        const b = normalise(recipe.b)
        if ((a === first && b === second) || (a === second && b === first)) return recipe
    }
    return null
}

const MAX_RECIPES = 200

/** Keeps only well-formed `{ a, b, label }` rows from a pushed value. */
export function sanitizeRecipes(value: unknown): CombineRecipe[] {
    if (!Array.isArray(value)) return []
    const out: CombineRecipe[] = []
    for (const row of value.slice(0, MAX_RECIPES)) {
        if (!row || typeof row !== "object") continue
        const { a, b, label } = row as Partial<Record<keyof CombineRecipe, unknown>>
        if (typeof a !== "string" || typeof b !== "string" || a === "" || b === "") continue
        out.push({ a, b, label: typeof label === "string" && label !== "" ? label : "Combine" })
    }
    return out
}

/** A pushed `combine` table onto the current one; an absent or malformed push keeps what is there. */
export function mergeCombine(current: CombineConfig, pushed: unknown): CombineConfig {
    if (!pushed || typeof pushed !== "object") return current
    const { enabled, recipes } = pushed as { enabled?: unknown; recipes?: unknown }
    return {
        enabled: typeof enabled === "boolean" ? enabled : current.enabled,
        recipes: Array.isArray(recipes) ? sanitizeRecipes(recipes) : current.recipes,
    }
}
