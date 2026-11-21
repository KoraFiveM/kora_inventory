/**
 * Inventory layouts the NUI can render (web/src/layouts). The same ids are
 * whitelisted in client/ui.lua and Config.kora_inventory.ui.layout.
 */
export const LAYOUT_IDS = ["classic", "loadout", "compact", "dock"] as const

export type LayoutId = (typeof LAYOUT_IDS)[number]

export function isLayoutId(value: unknown): value is LayoutId {
    return typeof value === "string" && (LAYOUT_IDS as readonly string[]).includes(value)
}
