import type { InventoryItem, InventoryView, SessionPatch, SessionSnapshot } from "@/lib/types"

/** What a drag carries: the slot it started from. */
export interface DragSlot { inventoryId: string; slot: number; /** Ctrl/Alt held when the drag started. */ modifiers?: { ctrl?: boolean; alt?: boolean } }
/** Where a drag can land. */
export interface SlotTarget { inventoryId: string; slot: number }
/** The inspected item together with the inventory it sits in. */
export interface Selection { inventory: InventoryView; item: InventoryItem }

export function asSlots(items: InventoryView["items"]): InventoryItem[] {
    // FiveM JSON serialises a sparse Lua slot table as an array with `null`
    // holes (e.g. item in slot 1, nothing in slots 2-4, item in slot 5).
    // Never let an empty slot enter a render/map pass that reads `.slot`.
    const values = Array.isArray(items) ? items : Object.values(items ?? {})
    return values.filter((item): item is InventoryItem =>
        item !== null && typeof item === "object" && Number.isInteger(item.slot) && item.slot > 0,
    )
}

export function mergeInventory(current: InventoryView | undefined, patch: Partial<InventoryView> | null | undefined) {
    if (patch === null) return undefined
    if (patch === undefined) return current
    if (!current) return patch as InventoryView | undefined
    return { ...current, ...patch, items: patch.items ?? current.items }
}

export function applyPatch(current: SessionSnapshot, patch: SessionPatch): SessionSnapshot {
    if (patch.snapshot) return patch.snapshot
    return {
        ...current,
        revision: patch.revision ?? current.revision,
        secondaryRevision: patch.secondaryRevision ?? current.secondaryRevision,
        player: mergeInventory(current.player, patch.player) ?? current.player,
        secondary: mergeInventory(current.secondary, patch.secondary),
    }
}

export function findInventory(session: SessionSnapshot, id: string) {
    if (session.player.id === id) return session.player
    if (session.secondary?.id === id) return session.secondary
}

export function findItem(inventory: InventoryView | undefined, slot: number) {
    return inventory && asSlots(inventory.items).find((item) => item.slot === slot)
}
