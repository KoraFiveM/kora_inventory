import { createContext } from "react"
import type { InventoryItem, InventoryView } from "@/lib/types"

/**
 * Cross-cutting slot decorations that are not part of a layout's handlers, so
 * every layout's panels pick them up without new props: the transient flash
 * set by quick slots, the weapon/ammo highlight, and the right-click menu.
 */
export interface SlotUi {
    /** A real player slot to pulse; `nonce` changes on every request so the same slot can flash twice. */
    flash?: { inventoryId: string; slot: number; nonce: number }
    /** True when the item should carry the compatible ring for the current selection. */
    isCompatible: (item: InventoryItem | undefined) => boolean
    /** Set only in `menu` mode: open the context menu at a client point. */
    openMenu?: (point: { x: number; y: number }, inventory: InventoryView, item: InventoryItem) => void
}

export const SlotUiContext = createContext<SlotUi>({ isCompatible: () => false })
