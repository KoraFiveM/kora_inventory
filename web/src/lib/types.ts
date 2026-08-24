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
    metadata?: Record<string, unknown>
    durability?: number
    price?: number
    stack?: boolean
    container?: boolean
    useable?: boolean
    /** Ms the client runs qblib's progress bar for before a use resolves. */
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
    intent: "close" | "move" | "use" | "drop" | "give" | "buy" | "split" | "action"
    payload: Record<string, unknown>
}

/** Server-authored receipt sent only when Config.qbinventory.itemBoxes allows it. */
export interface ItemBoxReceipt {
    name: string
    label?: string
    image?: string
    imageUrl?: string
    amount: number
    action: "add" | "purchase"
    duration?: number
}
