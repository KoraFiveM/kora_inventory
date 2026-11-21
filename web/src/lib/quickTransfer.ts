import { asSlots } from "./inventory"
import type { InventoryItem, InventoryView } from "./types"

const sameMeta = (a: InventoryItem, b: InventoryItem) =>
    JSON.stringify(a.info ?? a.metadata ?? null) === JSON.stringify(b.info ?? b.metadata ?? null)

/**
 * First slot of `target` that can take `item`: a same-item stackable stack
 * first, else the first empty slot. Never targets a shop. The server still
 * validates the move; this only chooses where to ask.
 */
export function pickTransferSlot(target: InventoryView, item: InventoryItem): number | undefined {
    if (target.type === "shop") return undefined
    const items = asSlots(target.items)
    if (item.stack !== false && !item.unique) {
        const stackable = items
            .filter((other) => other.name === item.name && other.stack !== false && !other.unique && sameMeta(other, item))
            .sort((a, b) => a.slot - b.slot)[0]
        if (stackable) return stackable.slot
    }
    const taken = new Set(items.map((other) => other.slot))
    for (let slot = 1; slot <= target.slots; slot++) if (!taken.has(slot)) return slot
    return undefined
}
