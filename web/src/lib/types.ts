export interface NuiWireMessage<T = unknown> {
    action: string
    data: T
}

export type ThemeTokens = Record<string, string>

export interface InventoryItem {
    slot: number
    name: string
    label?: string
    amount: number
    weight?: number
    description?: string
    image?: string
    imageUrl?: string
    /** True when imageUrl came from item metadata rather than the definition. */
    imageOverride?: boolean
    metadata?: Record<string, unknown>
    displayMeta?: Array<{ key: string; label: string; value: unknown }>
    durability?: number
    price?: number
    stack?: boolean
    container?: boolean
    useable?: boolean
    /** Ms the client runs kora_lib's progress bar for before a use resolves. */
    useTime?: number
    /** When true, using this item leaves the inventory panel open. */
    preventClose?: boolean
}

export interface InventoryView {
    id: string
    label?: string
    type?: string
    slots: number
    maxWeight?: number
    weight?: number
    items: Record<string, InventoryItem> | InventoryItem[]
}

export interface SessionSnapshot {
    sessionId: string
    token: string
    revision?: number
    secondaryRevision?: number
    player: InventoryView
    secondary?: InventoryView
}

export interface SessionPatch {
    sessionId: string
    revision?: number
    secondaryRevision?: number
    player?: Partial<InventoryView>
    secondary?: Partial<InventoryView> | null
    snapshot?: SessionSnapshot
}

export interface IntentPayload {
    sessionId: string
    token: string
    intent: "close" | "move" | "use" | "drop" | "give" | "buy" | "split" | "action" | "sync"
    payload: Record<string, unknown>
}

/** Server-authored receipt sent only when Config.qbinventory.itemBoxes allows it. */
export interface ItemBoxReceipt {
    name: string
    label?: string
    image?: string
    imageUrl?: string
    amount: number
    action: "add" | "purchase" | "remove" | "use"
    imageOverride?: boolean
    duration?: number
}

/**
 * The presentation half of `Config.qbinventory`, pushed on
 * `qbinventory:nui:config`. Everything here is a rendering choice -- nothing in
 * it is authority, and the server never reads it back.
 */
export interface UiConfig {
    /** Slots 1..hotbarSlots are the hotbar; the same range client/hotbar.lua binds. */
    hotbarSlots?: number
    /** Show a compact player grid with a selection drawer when no second inventory is open. */
    centreWhenSolo?: boolean
    /** Outline the hotbar slots in the accent colour. */
    showHotbar?: boolean
    /** Size multiplier for text and slots (Config.qbinventory.ui.scale), 1 = default. */
    scale?: number
    /** Right-clicking a stack opens the split dialog (Config.qbinventory.ui.rightClickSplit). */
    rightClickSplit?: boolean
    /** Paint a move before the server answers and roll back if refused (Config.qbinventory.ui.optimisticMoves). */
    optimisticMoves?: boolean
    /** Queue drags made while a move is pending instead of refusing them (Config.qbinventory.ui.queueMoves). */
    queueMoves?: boolean
    /** Milliseconds before an unanswered move is rolled back (Config.qbinventory.ui.moveTimeout, in seconds). */
    moveTimeoutMs?: number
    images?: {
        /** e.g. `nui://kora_inventory/images` */
        localPath?: string
        /** Tried in order for `<localPath>/<name>.<ext>`. */
        extensions?: string[]
        /** Try the local file before the item's own remote `imageUrl`. */
        preferLocal?: boolean
        /** When false, no outbound image request is ever made. */
        allowRemote?: boolean
    }
}
