import type { LayoutId } from "@/lib/layoutIds"
import type { CombineRecipe } from "@/lib/combine"

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
    /** Legacy field preserved on the wire; built-in art uses `image` only. */
    imageUrl?: string
    /** True when `info.image` overrides the definition's image filename. */
    imageOverride?: boolean
    metadata?: Record<string, unknown>
    /** qb-style metadata table; items carry this or `metadata`. */
    info?: Record<string, unknown>
    displayMeta?: Array<{ key: string; label: string; value: unknown }>
    durability?: number
    /** Weapons only: the server marked this weapon jammed (weapons.jams). View-only, never sent by the browser. */
    jammed?: boolean
    price?: number
    stack?: boolean
    /** Instance-unique items (weapons, serialled items) never stack. */
    unique?: boolean
    /** Set by the browser on an item it painted ahead of the server; never sent by it. */
    pending?: boolean
    container?: boolean
    useable?: boolean
    /** Ms the client runs kora_lib's progress bar for before a use resolves. */
    useTime?: number
    /** When true, using this item leaves the inventory panel open. */
    preventClose?: boolean
    /** Weapons only (weapons.ammoInfo): the ammunition it takes and what is loaded. View-only. */
    ammo?: { type: string; item: string; label: string; loaded?: number }
    /** Ammo items only: the ammo type; matches a weapon's `ammo.type`. */
    ammoType?: string
    /** Ammo items only: rounds one item holds. */
    rounds?: number
    /** Ammo items only: labels of the weapons it fits (may end in a "+N more" entry). */
    fits?: string[]
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
    intent: "close" | "move" | "use" | "drop" | "give" | "buy" | "split" | "action" | "sync" | "organize" | "combine"
    payload: Record<string, unknown>
    /** Lets the Lua bridge answer the fetch at once and deliver the verdict as `kora_inventory:nui:intentResult`. */
    requestId?: number
}

/** What the intent callback answers: a verdict, or an acknowledgement that one will follow. */
export interface IntentResponse {
    ok: boolean
    error?: string
    pending?: boolean
}

/** Server-authored receipt sent only when Config.kora_inventory.itemBoxes allows it. */
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

/** Sort / Stack all / per-panel search switches (Config.kora_inventory.organize). */
export interface OrganizeConfig {
    /** Master switch; false hides every organize control. */
    enabled: boolean
    /** Show the Sort button. */
    sort: boolean
    /** Show the Stack all button. */
    stack: boolean
    /** Show a search box in every panel header. */
    panelSearch: boolean
}

/** First-time tip card (Config.kora_inventory.ui.tips). */
export interface TipsConfig {
    enabled: boolean
    /** The card appears on at most this many openings of the inventory. */
    maxShows: number
}

export type RightClickMode = "split" | "menu" | "none"

export interface AmmoInfoConfig {
    enabled: boolean
    where: "inspector" | "menu" | "both"
    showLoaded: boolean
    showCompatible: boolean
}

/** One resolved quick slot from `kora_inventory:nui:quickSlots`. */
export interface QuickSlotEntry {
    id: string
    label: string
    /** The real player inventory slot this shortcut points at; null = unresolved. */
    slot: number | null
    name?: string | null
    /** Linked ammo: total rounds/magazines of that ammo across the inventory. */
    total?: number | null
    pinned?: boolean
    key?: string
    /** Linked slots follow another quick slot and cannot be pinned. */
    linked?: boolean
}

export interface QuickSlotsMessage {
    enabled?: boolean
    hideWhenMissing?: boolean
    showKeyHints?: boolean
    slots?: QuickSlotEntry[]
}

/** The `quick` entries of `kora_inventory:nui:hotbar`. */
export interface HotbarQuickEntry {
    id?: string
    label?: string
    slotLabel?: string
    slot?: number
    name?: string
    amount?: number
    image?: string
    imageUrl?: string
    key?: string
}

/**
 * The presentation half of `Config.kora_inventory`, pushed on
 * `kora_inventory:nui:config`. Everything here is a rendering choice -- nothing in
 * it is authority, and the server never reads it back.
 */
export interface UiConfig {
    /** Slots 1..hotbarSlots are the hotbar; the same range client/hotbar.lua binds. */
    hotbarSlots?: number
    /** Show a compact player grid with a selection drawer when no second inventory is open. */
    centreWhenSolo?: boolean
    /** Outline the hotbar slots in the accent colour. */
    showHotbar?: boolean
    /** Size multiplier for text and slots (Config.kora_inventory.ui.scale), 1 = default. */
    scale?: number
    /** Right-clicking a stack opens the split dialog (legacy form of `rightClick`; Config.kora_inventory.ui.rightClickSplit). */
    rightClickSplit?: boolean
    /** What right-click does: split dialog, a context menu, or nothing (Config.kora_inventory.ui.rightClick). */
    rightClick?: RightClickMode
    /** Weapon/ammo compatibility presentation hints (Config.kora_inventory.weapons.ammoInfo). */
    ammoInfo?: Partial<AmmoInfoConfig>
    /** Paint a move before the server answers and roll back if refused (Config.kora_inventory.ui.optimisticMoves). */
    optimisticMoves?: boolean
    /** Queue drags made while a move is pending instead of refusing them (Config.kora_inventory.ui.queueMoves). */
    queueMoves?: boolean
    /** Decimals shown for fractional inspector values (Config.Inspector.decimals). */
    inspectorDecimals?: number
    /** Inspector details are selectable and a Copy button copies the item as JSON (Config.Inspector.allowCopy). */
    inspectorCopy?: boolean
    /** Slot border thickness in px (Config.Slots.borderWidth). */
    slotBorderWidth?: number
    /** Milliseconds before an unanswered move is rolled back (Config.kora_inventory.ui.moveTimeoutMs). */
    moveTimeoutMs?: number
    /** The bridge delivers verdicts as messages instead of holding the fetch (Config.kora_inventory.ui.directTransport). */
    directTransport?: boolean
    /** Server default inventory layout (Config.kora_inventory.ui.layout). */
    layout?: LayoutId
    /** Which layouts may be used; a missing key counts as allowed (Config.kora_inventory.ui.layouts). */
    layouts?: Partial<Record<LayoutId, boolean>>
    /** The player's own layout choice from the /ui editor is honoured (Config.kora_inventory.ui.playerLayoutChoice). */
    playerLayoutChoice?: boolean
    /** Shift+click moves a whole stack to the other open inventory (Config.kora_inventory.ui.quickTransfer). */
    quickTransfer?: boolean
    /** Ctrl+drag moves half a stack, Alt+drag moves one (Config.kora_inventory.ui.modifierDrag). */
    modifierDrag?: boolean
    /** Preset amount buttons beside the amount slider (Config.kora_inventory.ui.quickAmounts). */
    quickAmounts?: boolean
    /** Category chips that dim non-matching slots (Config.kora_inventory.ui.filters). */
    filters?: boolean
    /** Weight bar turns warning/destructive near capacity (Config.kora_inventory.ui.weightWarnings). */
    weightWarnings?: { enabled?: boolean; warnAt?: number; dangerAt?: number }
    /** Hover tooltip on filled slots (Config.kora_inventory.ui.tooltips). */
    tooltips?: boolean
    /** Sort / Stack all buttons and per-panel search (Config.kora_inventory.organize). */
    organize?: Partial<OrganizeConfig>
    /** First-time tip card (Config.kora_inventory.ui.tips). */
    tips?: Partial<TipsConfig>
    /** Drag-to-combine presentation list: item names + label only (Config.kora_inventory.combine). */
    combine?: { enabled?: boolean; recipes?: CombineRecipe[] }
    images?: {
        /** e.g. `nui://kora_inventory/images` */
        localPath?: string
        /** Tried in order for `<localPath>/<name>.<ext>`. */
        extensions?: string[]
    }
}
