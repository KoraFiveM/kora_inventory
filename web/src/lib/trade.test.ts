import { describe, expect, it } from "vitest"
import { DEFAULT_TRADE_CONFIG, canConfirm, canEdit, canReady, confirmRemaining, dropOfferAmount, formatDuration, hasFreeOfferCell, mergeTradeConfig, normalizeTradeView, offerCells, offeredSlots, parseCash, parseOfferAmount, tradeStatus } from "./trade"

const base = {
    id: "trade-1-1", phase: "open", revision: 3, slots: 4, allowCash: true,
    you: { offers: [{ slot: 2, amount: 3, name: "bread", label: "Bread" }], cash: 0, ready: false, confirmed: false, balance: 500 },
    them: { offers: {}, cash: 40, ready: false, confirmed: false },
}

describe("normalizeTradeView", () => {
    it("accepts the server view and Lua's empty-table offers", () => {
        const view = normalizeTradeView(base)!
        expect(view.you.offers).toHaveLength(1)
        expect(view.them.offers).toEqual([])
        expect(view.them.cash).toBe(40)
        expect(view.you.balance).toBe(500)
    })

    it("rejects anything that is not a trade view", () => {
        expect(normalizeTradeView(null)).toBeNull()
        expect(normalizeTradeView({ ...base, id: 5 })).toBeNull()
        expect(normalizeTradeView({ ...base, phase: "done" })).toBeNull()
        expect(normalizeTradeView({ ...base, revision: 1.5 })).toBeNull()
    })

    it("drops malformed offers and clamps cash", () => {
        const view = normalizeTradeView({ ...base, you: { offers: [{ slot: 0, amount: 1, name: "x" }, { slot: 1, amount: 2.5, name: "y" }, { slot: 1, amount: 2, name: "ok" }], cash: -3 } })!
        expect(view.you.offers.map((offer) => offer.name)).toEqual(["ok"])
        expect(view.you.cash).toBe(0)
    })
})

describe("trade helpers", () => {
    const view = normalizeTradeView(base)!

    it("merges pushed config onto defaults", () => {
        expect(mergeTradeConfig(DEFAULT_TRADE_CONFIG, { slots: 4, enabled: false })).toEqual({ enabled: false, slots: 4, allowCash: true })
        expect(mergeTradeConfig(DEFAULT_TRADE_CONFIG, { slots: 0 as number })).toEqual(DEFAULT_TRADE_CONFIG)
        expect(mergeTradeConfig(DEFAULT_TRADE_CONFIG, undefined)).toBe(DEFAULT_TRADE_CONFIG)
    })

    it("marks offered own slots", () => {
        expect(offeredSlots(view).get(2)).toBe(3)
        expect(offeredSlots(null).size).toBe(0)
    })

    it("draws one cell per offer slot", () => {
        const cells = offerCells(view.you, view.slots)
        expect(cells).toHaveLength(4)
        expect(cells[0]?.name).toBe("bread")
        expect(cells[1]).toBeUndefined()
    })

    it("knows when there is room for another stack", () => {
        const full = { ...view, slots: 1 }
        expect(hasFreeOfferCell(full, 2)).toBe(true)
        expect(hasFreeOfferCell(full, 3)).toBe(false)
    })

    it("only edits and readies while open with something offered", () => {
        expect(canEdit(view)).toBe(true)
        expect(canReady(view)).toBe(true)
        expect(canReady({ ...view, you: { ...view.you, offers: [] }, them: { ...view.them, cash: 0 } })).toBe(false)
        expect(canReady({ ...view, you: { ...view.you, ready: true } })).toBe(false)
        expect(canEdit({ ...view, phase: "locked" })).toBe(false)
    })

    it("counts the confirm delay down from when the view arrived", () => {
        const locked = { ...view, phase: "locked" as const, confirmInMs: 3000 }
        expect(confirmRemaining(locked, 1000, 1000)).toBe(3000)
        expect(confirmRemaining(locked, 1000, 2500)).toBe(1500)
        expect(confirmRemaining(locked, 1000, 9000)).toBe(0)
        expect(canConfirm(locked, 1000, 2500)).toBe(false)
        expect(canConfirm(locked, 1000, 4000)).toBe(true)
        expect(canConfirm({ ...locked, you: { ...locked.you, confirmed: true } }, 1000, 4000)).toBe(false)
        expect(canConfirm(view, 0, 99999)).toBe(false)
    })

    it("reports one headline status", () => {
        expect(tradeStatus(view, 0)).toBe("editing")
        expect(tradeStatus({ ...view, you: { ...view.you, ready: true } }, 0)).toBe("you_ready")
        expect(tradeStatus({ ...view, them: { ...view.them, ready: true } }, 0)).toBe("partner_ready")
        expect(tradeStatus({ ...view, phase: "locked" }, 500)).toBe("countdown")
        expect(tradeStatus({ ...view, phase: "locked" }, 0)).toBe("confirm")
        expect(tradeStatus({ ...view, phase: "locked", you: { ...view.you, confirmed: true } }, 0)).toBe("you_confirmed")
    })

    it("asks for an amount only for real stacks", () => {
        expect(dropOfferAmount(1)).toBe(1)
        expect(dropOfferAmount(10)).toBeUndefined()
        expect(dropOfferAmount(10, 5)).toBe(5)
        expect(dropOfferAmount(10, 11)).toBeUndefined()
    })

    it("parses typed amounts strictly", () => {
        expect(parseOfferAmount("3", 5)).toEqual({ amount: 3 })
        for (const bad of ["0", "6", "2.5", "-1", "abc", ""]) expect(parseOfferAmount(bad, 5)).toEqual({ error: true })
        expect(parseCash("", 100)).toEqual({ amount: 0 })
        expect(parseCash("100", 100)).toEqual({ amount: 100 })
        expect(parseCash("101", 100)).toEqual({ error: true })
        expect(parseCash("1e3")).toEqual({ error: true })
        expect(parseCash("5000")).toEqual({ amount: 5000 })
    })

    it("formats countdowns", () => {
        expect(formatDuration(65_000)).toBe("1:05")
        expect(formatDuration(1)).toBe("0:01")
        expect(formatDuration(-5)).toBe("0:00")
    })
})
