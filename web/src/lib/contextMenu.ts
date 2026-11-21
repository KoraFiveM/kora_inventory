import { canOpenBag } from "./search"
import type { AmmoInfoConfig, InventoryItem, InventoryView } from "./types"

export type MenuEntry = "use" | "open" | "split" | "drop" | "give" | "ammo" | "copy"

/**
 * Which actions the right-click menu offers for an item, in display order.
 * Mirrors the rules the inspector and the split flow already apply: use, drop
 * and give are the player's own items only, a shop stack cannot be split, and
 * the ammo entry needs ammo fields plus `ammoInfo` pointing at the menu.
 */
export function contextMenuEntries(options: {
    inventory: Pick<InventoryView, "id" | "type">
    item: InventoryItem
    playerId: string
    giveAvailable: boolean
    inspectorCopy: boolean
    ammoInfo: AmmoInfoConfig
}): MenuEntry[] {
    const { inventory, item, playerId, giveAvailable, inspectorCopy, ammoInfo } = options
    const own = inventory.id === playerId
    const entries: MenuEntry[] = []
    if (own && (item.useable || item.container)) entries.push("use")
    // A closed bag in a searched player's inventory: open it (server re-checks everything).
    if (canOpenBag(inventory, item, playerId)) entries.push("open")
    if (inventory.type !== "shop" && item.amount >= 2) entries.push("split")
    if (own) entries.push("drop")
    if (own && giveAvailable) entries.push("give")
    if (ammoInfo.enabled && ammoInfo.where !== "inspector" && (item.ammo || item.ammoType)) entries.push("ammo")
    if (inspectorCopy) entries.push("copy")
    return entries
}

/** Places a menu at the cursor, pulled back so it stays fully inside the window. */
export function clampMenuPosition(point: { x: number; y: number }, size: { width: number; height: number }, viewport: { width: number; height: number }, margin = 6) {
    const x = Math.max(margin, Math.min(point.x, viewport.width - size.width - margin))
    const y = Math.max(margin, Math.min(point.y, viewport.height - size.height - margin))
    return { x, y }
}
