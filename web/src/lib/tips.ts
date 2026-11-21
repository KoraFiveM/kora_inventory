import type { LayoutId } from "./layoutIds"
import type { RightClickMode, UiConfig } from "./types"

/** localStorage key holding the player's tip progress. */
export const TIPS_STORAGE_KEY = "kora_inventory:tips"

export type TipId = "drag_drop" | "quick_transfer" | "modifier_drag" | "right_click_split" | "right_click_menu" | "quick_slot" | "organize" | "layout" | "controls"

/** The order tips are offered in. */
export const TIP_ORDER: readonly TipId[] = ["drag_drop", "quick_transfer", "modifier_drag", "right_click_split", "right_click_menu", "quick_slot", "organize", "layout", "controls"]

export interface TipsState {
    /** Tips already shown. */
    seen: string[]
    /** "Got it": never show again. */
    dismissed: boolean
    /** How many times the inventory was opened with tips on (compared with maxShows). */
    opens: number
}

export const EMPTY_TIPS_STATE: TipsState = { seen: [], dismissed: false, opens: 0 }

/** What decides which tips apply: only features that are switched on get a tip. */
export interface TipsContext {
    quickTransfer: boolean
    modifierDrag: boolean
    rightClick: RightClickMode
    quickSlotsEnabled: boolean
    organize: { enabled: boolean; sort: boolean; stack: boolean }
    playerLayoutChoice: boolean
    layouts: Partial<Record<LayoutId, boolean>>
    /** The keyboard button that toggles the controls overlay is shown. */
    controlsButton: boolean
}

/** Layouts a player may pick: missing counts as allowed, `classic` always is. */
export function allowedLayoutCount(layouts: TipsContext["layouts"]): number {
    const ids: LayoutId[] = ["classic", "loadout", "compact", "dock"]
    const count = ids.filter((id) => layouts[id] !== false).length
    return count === 0 ? 1 : count
}

/** Tips for the features enabled in `context`, in offering order. */
export function availableTips(context: TipsContext): TipId[] {
    const wanted: Record<TipId, boolean> = {
        drag_drop: true,
        quick_transfer: context.quickTransfer,
        modifier_drag: context.modifierDrag,
        right_click_split: context.rightClick === "split",
        right_click_menu: context.rightClick === "menu",
        quick_slot: context.quickSlotsEnabled,
        organize: context.organize.enabled && (context.organize.sort || context.organize.stack),
        layout: context.playerLayoutChoice && allowedLayoutCount(context.layouts) > 1,
        controls: context.controlsButton,
    }
    return TIP_ORDER.filter((id) => wanted[id])
}

/**
 * The next tip to show: the first available tip not seen yet (after `current`
 * when one is on screen). When everything has been seen it cycles on to the one
 * after `current`, so "Next" never gets stuck. Returns undefined with no tips.
 */
export function chooseTip(available: readonly TipId[], seen: readonly string[], current?: TipId): TipId | undefined {
    if (available.length === 0) return undefined
    const start = current ? available.indexOf(current) : -1
    const ordered = [...available.slice(start + 1), ...available.slice(0, start + 1)].filter((id) => id !== current || available.length === 1)
    return ordered.find((id) => !seen.includes(id)) ?? ordered[0]
}

/** True when the card may appear: enabled, not dismissed, and within `maxShows` openings. */
export function tipsActive(config: { enabled: boolean; maxShows: number }, state: TipsState): boolean {
    return config.enabled && !state.dismissed && state.opens <= Math.max(0, Math.floor(config.maxShows))
}

/** Counts one opening of the inventory. */
export function registerOpening(state: TipsState): TipsState {
    return { ...state, opens: state.opens + 1 }
}

export function markSeen(state: TipsState, id: TipId): TipsState {
    return state.seen.includes(id) ? state : { ...state, seen: [...state.seen, id] }
}

export function dismissTips(state: TipsState): TipsState {
    return { ...state, dismissed: true }
}

/** Reads stored progress; anything malformed is treated as a fresh start. */
export function parseTipsState(raw: string | null | undefined): TipsState {
    if (!raw) return EMPTY_TIPS_STATE
    try {
        const value = JSON.parse(raw) as Partial<TipsState> | null
        if (!value || typeof value !== "object") return EMPTY_TIPS_STATE
        return {
            seen: Array.isArray(value.seen) ? value.seen.filter((entry): entry is string => typeof entry === "string") : [],
            dismissed: value.dismissed === true,
            opens: Number.isFinite(value.opens) && Number(value.opens) > 0 ? Math.floor(Number(value.opens)) : 0,
        }
    } catch {
        return EMPTY_TIPS_STATE
    }
}

type TipsStorage = Pick<Storage, "getItem" | "setItem">

function defaultStorage(): TipsStorage | undefined {
    try {
        return typeof window !== "undefined" ? window.localStorage : undefined
    } catch {
        return undefined
    }
}

export function loadTipsState(storage: TipsStorage | undefined = defaultStorage()): TipsState {
    try {
        return parseTipsState(storage?.getItem(TIPS_STORAGE_KEY))
    } catch {
        return EMPTY_TIPS_STATE
    }
}

export function saveTipsState(state: TipsState, storage: TipsStorage | undefined = defaultStorage()): void {
    try {
        storage?.setItem(TIPS_STORAGE_KEY, JSON.stringify(state))
    } catch {
        // Storage can be unavailable or full; tips then simply restart next time.
    }
}

/** Builds the context from the merged UI config. */
export function tipsContext(config: Pick<Required<UiConfig>, "quickTransfer" | "modifierDrag" | "rightClick" | "organize" | "playerLayoutChoice" | "layouts" | "controls">, quickSlotsEnabled: boolean): TipsContext {
    return {
        quickTransfer: config.quickTransfer,
        modifierDrag: config.modifierDrag,
        rightClick: config.rightClick,
        quickSlotsEnabled,
        organize: config.organize as TipsContext["organize"],
        playerLayoutChoice: config.playerLayoutChoice,
        layouts: config.layouts,
        controlsButton: config.controls.button !== false,
    }
}
