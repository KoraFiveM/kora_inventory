import type { LayoutId } from "@/lib/layoutIds"
import type { CombineRecipe } from "@/lib/combine"

export interface NuiWireMessage<T = unknown> {
    action: string
    data: T
}

export interface InventoryItem {
    slot: number
    /** Current footprint when placed in a shaped grid. */
    gridWidth?: number
    gridHeight?: number
    gridRotated?: boolean
    /** Authored footprint, including when the item is in a classic inventory. */
    gridBaseWidth?: number
    gridBaseHeight?: number
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
    /** View-only (search): a bag in another player's inventory whose contents were not sent. */
    closedContainer?: boolean
    /** View-only (search): the server would let this viewer open the closed bag. */
    openable?: boolean
    /** View-only (waterDamage): electronics that stopped working until repaired. */
    waterDamaged?: boolean
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
    /** Items that decay (decay.enabled): seconds of life left and 0..1 of it. Server-computed, view-only. */
    decay?: { remaining: number; fraction: number }
}

/** Item decay presentation (Config.kora_inventory.decay). The server decides which items carry `decay`. */
export interface DecayConfig {
    enabled: boolean
    /** Draw the freshness bar on the slot. */
    showOnSlot: boolean
    /** Bar turns --warning below this fraction of life left (and --destructive below 10%). */
    warnBelow: number
}

export interface InventoryView {
    id: string
    /** When present, slots are row-major grid cells and item slots are anchors. */
    gridColumns?: number
    label?: string
    type?: string
    slots: number
    maxWeight?: number
    weight?: number
    items: Record<string, InventoryItem> | InventoryItem[]
    /** Admin omnipack: a free, infinite, read-only catalogue (search + paging in the panel). */
    omnipack?: boolean
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
    intent: "close" | "move" | "use" | "drop" | "give" | "buy" | "split" | "action" | "sync" | "organize" | "combine" | "openTargetContainer" | "trade" | "tradeRequest"
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

/** Native controls overlay toggle (Config.kora_inventory.ui.controls). */
export interface ControlsConfig {
    /** Show the keyboard button in the top bar. */
    button: boolean
    /** Show the overlay on the first opening, before the player has chosen. */
    defaultVisible: boolean
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
    /** Presentation of the side drawer; the player's own toggle (localStorage) wins after the first use. */
    drawer?: { startCollapsed?: boolean }
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
    /** Controls overlay toggle (Config.kora_inventory.ui.controls). */
    controls?: Partial<ControlsConfig>
    /** Drag-to-combine presentation list: item names + label only (Config.kora_inventory.combine). */
    combine?: { enabled?: boolean; recipes?: CombineRecipe[] }
    /** Item decay presentation (Config.kora_inventory.decay). */
    decay?: Partial<DecayConfig>
    /** Player trade presentation (Config.kora_inventory.trade); the server enforces all of it. */
    trade?: Partial<TradeUiConfig>
    images?: {
        /** e.g. `nui://kora_inventory/images` */
        localPath?: string
        /** Tried in order for `<localPath>/<name>.<ext>`. */
        extensions?: string[]
    }
}

/** One row of the item-creation audit log (server/audit_log.lua). Read-only. */
export interface AuditRow {
    at: number
    action: string
    citizenid?: string
    source?: number
    item?: string
    amount?: number
    inventory?: string
    resource?: string
    reason?: string
}

export interface AuditSummaryRow {
    name: string
    amount: number
    count: number
}

export type AuditRange = "1h" | "24h" | "7d"

/** The filter the viewer sends; the server normalises and re-checks everything. */
export interface AuditFilter {
    player: string
    item: string
    resource: string
    range: AuditRange
    page: number
}

export interface AuditResult {
    error?: string
    rows: AuditRow[]
    hasMore: boolean
    page: number
    pageSize: number
    source?: "database" | "memory"
    summary?: { resources: AuditSummaryRow[]; items: AuditSummaryRow[] }
}

/** Config.kora_inventory.trade as the page needs it. */
export interface TradeUiConfig {
    enabled: boolean
    /** Offer slots drawn per side. */
    slots: number
    allowCash: boolean
}

/** One offered stack as the server describes it. Partner offers carry display fields only (no raw metadata). */
export interface TradeOffer {
    /** The offerer's own inventory slot this offer points at. */
    slot: number
    amount: number
    name: string
    label?: string
    image?: string
    imageUrl?: string
    imageOverride?: boolean
    weight?: number
    description?: string
    displayMeta?: Array<{ key: string; label: string; value: unknown }>
    unique?: boolean
}

export interface TradeSide {
    offers: TradeOffer[]
    cash: number
    ready: boolean
    confirmed: boolean
    /** Own side only: the cash the server says you hold. */
    balance?: number
}

export type TradePhase = "open" | "locked" | "committing"

/** `kora_inventory:nui:trade`: the server's view of the trade for this player. */
export interface TradeView {
    id: string
    phase: TradePhase
    /** Echoed back on Ready/Confirm; a mismatch means the player has not seen the latest offers. */
    revision: number
    slots: number
    allowCash: boolean
    you: TradeSide
    them: TradeSide
    /** Milliseconds until Confirm is accepted, when locked. */
    confirmInMs?: number
    confirmDelayMs?: number
    /** Milliseconds until the trade is cancelled for running too long. */
    endsInMs?: number
    lastError?: string
}
