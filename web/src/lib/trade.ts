import type { TradeOffer, TradePhase, TradeSide, TradeUiConfig, TradeView } from "./types"

/** What the page assumes before `kora_inventory:nui:config` arrives (mirrors config.lua). */
export const DEFAULT_TRADE_CONFIG: TradeUiConfig = { enabled: true, slots: 8, allowCash: true }

const MAX_SLOTS = 32
const MAX_CASH = 1_000_000_000
const PHASES: TradePhase[] = ["open", "locked", "committing"]

const wholeNumber = (value: unknown, min: number, max: number): value is number =>
    typeof value === "number" && Number.isInteger(value) && value >= min && value <= max

export function mergeTradeConfig(current: TradeUiConfig, pushed: Partial<TradeUiConfig> | undefined): TradeUiConfig {
    if (!pushed || typeof pushed !== "object") return current
    return {
        enabled: typeof pushed.enabled === "boolean" ? pushed.enabled : current.enabled,
        slots: wholeNumber(pushed.slots, 1, MAX_SLOTS) ? pushed.slots : current.slots,
        allowCash: typeof pushed.allowCash === "boolean" ? pushed.allowCash : current.allowCash,
    }
}

function normalizeOffer(raw: unknown): TradeOffer | null {
    if (!raw || typeof raw !== "object") return null
    const offer = raw as Record<string, unknown>
    if (!wholeNumber(offer.slot, 1, 10_000) || !wholeNumber(offer.amount, 1, MAX_CASH) || typeof offer.name !== "string") return null
    const text = (value: unknown) => typeof value === "string" ? value : undefined
    return {
        slot: offer.slot,
        amount: offer.amount,
        name: offer.name,
        label: text(offer.label),
        image: text(offer.image),
        imageUrl: text(offer.imageUrl),
        imageOverride: offer.imageOverride === true,
        weight: typeof offer.weight === "number" && Number.isFinite(offer.weight) ? offer.weight : undefined,
        description: text(offer.description),
        displayMeta: Array.isArray(offer.displayMeta) ? offer.displayMeta.filter((row): row is { key: string; label: string; value: unknown } =>
            Boolean(row) && typeof row === "object" && typeof (row as { label?: unknown }).label === "string") : undefined,
        unique: offer.unique === true,
    }
}

function normalizeSide(raw: unknown): TradeSide {
    const side = raw && typeof raw === "object" ? raw as Record<string, unknown> : {}
    // Lua sends an empty table as `{}` rather than `[]`; both mean no offers.
    const list = Array.isArray(side.offers) ? side.offers : side.offers && typeof side.offers === "object" ? Object.values(side.offers) : []
    return {
        offers: list.map(normalizeOffer).filter((offer): offer is TradeOffer => offer !== null),
        cash: wholeNumber(side.cash, 0, MAX_CASH) ? side.cash : 0,
        ready: side.ready === true,
        confirmed: side.confirmed === true,
        balance: typeof side.balance === "number" && Number.isFinite(side.balance) ? Math.max(0, Math.floor(side.balance)) : undefined,
    }
}

/** Accepts the server's trade view, or null for anything that is not one. */
export function normalizeTradeView(raw: unknown): TradeView | null {
    if (!raw || typeof raw !== "object") return null
    const view = raw as Record<string, unknown>
    if (typeof view.id !== "string" || !PHASES.includes(view.phase as TradePhase) || !wholeNumber(view.revision, 0, Number.MAX_SAFE_INTEGER)) return null
    const ms = (value: unknown) => typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined
    return {
        id: view.id,
        phase: view.phase as TradePhase,
        revision: view.revision,
        slots: wholeNumber(view.slots, 1, MAX_SLOTS) ? view.slots : DEFAULT_TRADE_CONFIG.slots,
        allowCash: view.allowCash === true,
        you: normalizeSide(view.you),
        them: normalizeSide(view.them),
        confirmInMs: ms(view.confirmInMs),
        confirmDelayMs: ms(view.confirmDelayMs),
        endsInMs: ms(view.endsInMs),
        lastError: typeof view.lastError === "string" ? view.lastError : undefined,
    }
}

/** Own inventory slot -> amount offered, for marking the player panel. */
export function offeredSlots(view: TradeView | null | undefined): Map<number, number> {
    return new Map((view?.you.offers ?? []).map((offer) => [offer.slot, offer.amount]))
}

/** `slots` cells for one side: the offer in each, or undefined for an empty cell. */
export function offerCells(side: TradeSide, slots: number): Array<TradeOffer | undefined> {
    return Array.from({ length: Math.max(slots, side.offers.length) }, (_, index) => side.offers[index])
}

export const canEdit = (view: TradeView) => view.phase === "open"

function sideHasSomething(side: TradeSide) {
    return side.offers.length > 0 || side.cash > 0
}

export const canReady = (view: TradeView) => view.phase === "open" && !view.you.ready && (sideHasSomething(view.you) || sideHasSomething(view.them))

/** Milliseconds left before Confirm is accepted, counted from when the view arrived. */
export function confirmRemaining(view: TradeView, receivedAt: number, now: number): number {
    if (view.phase !== "locked") return 0
    return Math.max(0, (view.confirmInMs ?? 0) - Math.max(0, now - receivedAt))
}

export const canConfirm = (view: TradeView, receivedAt: number, now: number) =>
    view.phase === "locked" && !view.you.confirmed && confirmRemaining(view, receivedAt, now) === 0

/** Whether there is room for one more distinct stack (re-offering an offered slot only changes its amount). */
export function hasFreeOfferCell(view: TradeView, slot: number) {
    return view.you.offers.some((offer) => offer.slot === slot) || view.you.offers.length < view.slots
}

/**
 * How many to offer for a drop: an explicit amount (modifier drag), the whole
 * stack for a single item, or undefined when the player should be asked.
 */
export function dropOfferAmount(stack: number, modifierAmount?: number): number | undefined {
    if (modifierAmount !== undefined && wholeNumber(modifierAmount, 1, stack)) return modifierAmount
    if (stack <= 1) return 1
    return undefined
}

/** A typed amount for an offer: a whole number from 1 to the stack. */
export function parseOfferAmount(value: string, stack: number): { amount: number } | { error: true } {
    const trimmed = value.trim()
    if (!/^\d+$/.test(trimmed)) return { error: true }
    const amount = Number(trimmed)
    return wholeNumber(amount, 1, Math.floor(stack)) ? { amount } : { error: true }
}

/** A typed cash amount: a whole number from 0 to the known balance. */
export function parseCash(value: string, balance?: number): { amount: number } | { error: true } {
    const trimmed = value.trim()
    if (trimmed === "") return { amount: 0 }
    if (!/^\d+$/.test(trimmed)) return { error: true }
    const amount = Number(trimmed)
    const max = balance === undefined ? MAX_CASH : Math.min(MAX_CASH, balance)
    return wholeNumber(amount, 0, max) ? { amount } : { error: true }
}

/** `m:ss` for a countdown. */
export function formatDuration(ms: number) {
    const total = Math.max(0, Math.ceil(ms / 1000))
    return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`
}

export type TradeStatus = "editing" | "you_ready" | "partner_ready" | "countdown" | "confirm" | "you_confirmed" | "committing"

/** The single headline state the panel shows. */
export function tradeStatus(view: TradeView, remaining: number): TradeStatus {
    if (view.phase === "committing") return "committing"
    if (view.phase === "locked") {
        if (view.you.confirmed) return "you_confirmed"
        return remaining > 0 ? "countdown" : "confirm"
    }
    if (view.you.ready) return "you_ready"
    if (view.them.ready) return "partner_ready"
    return "editing"
}
