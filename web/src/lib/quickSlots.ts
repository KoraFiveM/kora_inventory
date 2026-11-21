import { asSlots } from "./inventory"
import type { InventoryItem, InventoryView, QuickSlotEntry, QuickSlotsMessage } from "./types"

export interface QuickSlotsState {
    enabled: boolean
    hideWhenMissing: boolean
    showKeyHints: boolean
    drawer: { startCollapsed: boolean }
    slots: QuickSlotEntry[]
}

export const EMPTY_QUICK_SLOTS: QuickSlotsState = { enabled: false, hideWhenMissing: true, showKeyHints: true, drawer: { startCollapsed: false }, slots: [] }

/** Validates the `kora_inventory:nui:quickSlots` payload; anything malformed is dropped. */
export function normalizeQuickSlots(data: QuickSlotsMessage | null | undefined): QuickSlotsState {
    if (!data || typeof data !== "object" || data.enabled !== true) return EMPTY_QUICK_SLOTS
    const slots: QuickSlotEntry[] = []
    for (const entry of Array.isArray(data.slots) ? data.slots : []) {
        if (!entry || typeof entry !== "object" || typeof entry.id !== "string" || entry.id === "") continue
        slots.push({
            id: entry.id,
            label: typeof entry.label === "string" && entry.label !== "" ? entry.label : entry.id,
            slot: Number.isInteger(entry.slot) && Number(entry.slot) > 0 ? Number(entry.slot) : null,
            name: typeof entry.name === "string" ? entry.name : null,
            total: Number.isFinite(entry.total) ? Number(entry.total) : null,
            pinned: entry.pinned === true,
            key: typeof entry.key === "string" ? entry.key : "",
            linked: entry.linked === true,
        })
    }
    return { enabled: true, hideWhenMissing: data.hideWhenMissing !== false, showKeyHints: data.showKeyHints !== false, drawer: { startCollapsed: data.drawer?.startCollapsed === true }, slots }
}

export interface QuickTile {
    id: string
    label: string
    /** The real inventory slot, or null for a placeholder. */
    slot: number | null
    item: InventoryItem | undefined
    /** Total rounds/magazines for linked ammo. */
    total: number | null
    pinned: boolean
    key: string
    /** Follows another quick slot (ammo); cannot be pinned. */
    linked: boolean
}

/**
 * The tiles to draw. A tile resolves to the item the player really holds in
 * its slot; if the message is stale (nothing there, or a different item than
 * the one it named) it counts as missing. Missing tiles are dropped with
 * `hideWhenMissing` and otherwise kept as placeholders. Quick slots are only
 * shortcuts, so nothing here ever moves or creates an item.
 */
export function buildQuickTiles(state: QuickSlotsState, player: InventoryView | undefined): QuickTile[] {
    if (!state.enabled || !player) return []
    const bySlot = new Map(asSlots(player.items).map((item) => [item.slot, item]))
    const tiles: QuickTile[] = []
    for (const entry of state.slots) {
        const found = entry.slot !== null ? bySlot.get(entry.slot) : undefined
        const item = found && (!entry.name || entry.name === found.name) ? found : undefined
        if (!item && state.hideWhenMissing) continue
        tiles.push({
            id: entry.id,
            label: entry.label,
            slot: item ? entry.slot : null,
            item,
            total: entry.total ?? null,
            pinned: entry.pinned === true,
            key: entry.key ?? "",
            linked: entry.linked === true,
        })
    }
    return tiles
}

/** What the tile shows as its count: the ammo total for linked ammo, otherwise the stack amount. */
export function tileCount(tile: Pick<QuickTile, "item" | "total">): number | undefined {
    if (tile.total !== null) return tile.total
    return tile.item && tile.item.amount > 1 ? tile.item.amount : undefined
}
