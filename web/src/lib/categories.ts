import type { InventoryItem } from "./types"

export type ItemCategory = "weapons" | "ammo" | "consumables" | "other"
export type CategoryFilter = "all" | ItemCategory
export const CATEGORY_FILTERS: readonly CategoryFilter[] = ["all", "weapons", "ammo", "consumables", "other"]

/** Presentation-only grouping from fields already on the view; never authority. */
export function classifyItem(item: Pick<InventoryItem, "name" | "useable"> & { ammo?: unknown; ammoType?: unknown; type?: unknown }): ItemCategory {
    const isWeapon = item.ammo !== undefined || item.type === "weapon" || (typeof item.name === "string" && item.name.toLowerCase().startsWith("weapon_"))
    if (isWeapon) return "weapons"
    if (item.ammoType !== undefined && item.ammoType !== null) return "ammo"
    if (item.useable) return "consumables"
    return "other"
}

export function matchesCategory(item: Parameters<typeof classifyItem>[0], filter: CategoryFilter): boolean {
    return filter === "all" || classifyItem(item) === filter
}

/** True when a slot should be dimmed by the category chip or the search text. */
export function isDimmed(item: (Parameters<typeof classifyItem>[0] & { label?: string }) | undefined, filter: CategoryFilter, query: string): boolean {
    if (!item) return false
    if (!matchesCategory(item, filter)) return true
    const needle = query.trim().toLowerCase()
    return needle !== "" && !(item.label ?? item.name).toLowerCase().includes(needle)
}
