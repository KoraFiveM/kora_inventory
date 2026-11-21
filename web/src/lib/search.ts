import type { InventoryItem, InventoryView } from "./types"

/**
 * Presentation helpers for searching another player's inventory. The server
 * decides everything: `closedContainer` / `openable` / `waterDamaged` arrive as
 * view-only fields on the item and are never read back as authority. A bag the
 * server did not conceal simply has no `closedContainer` flag.
 */

/** A bag in someone else's pockets whose contents the server did not send. */
export function isClosedBag(item: InventoryItem | undefined): boolean {
    return item?.closedContainer === true
}

/**
 * Whether the "Open bag" action applies: a closed bag in ANOTHER player's
 * inventory that the server marked openable. The server re-checks all of it.
 */
export function canOpenBag(inventory: Pick<InventoryView, "id" | "type">, item: InventoryItem | undefined, playerId: string): boolean {
    return Boolean(item) && inventory.type === "player" && inventory.id !== playerId && item?.openable === true
}

/** The payload of the `openTargetContainer` intent: the granted inventory id and a slot, nothing else. */
export function openBagPayload(inventory: Pick<InventoryView, "id">, item: Pick<InventoryItem, "slot">): { inventory: string; slot: number } {
    return { inventory: inventory.id, slot: item.slot }
}

export function isWaterDamaged(item: InventoryItem | undefined): boolean {
    return item?.waterDamaged === true
}
