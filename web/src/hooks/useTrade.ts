import { useCallback, useEffect, useRef, useState } from "react"
import { canConfirm, canEdit, confirmRemaining, dropOfferAmount, normalizeTradeView } from "@/lib/trade"
import type { InventoryItem, SessionSnapshot, TradeView } from "@/lib/types"
import { useNuiEvent } from "@/lib/useNuiEvent"

/** How often an open trade window renews the inventory lease (well under sessionTtl). */
const TRADE_KEEPALIVE_MS = 30_000

type Submit = (intent: "trade" | "tradeRequest", payload?: Record<string, unknown>) => void

/**
 * The open trade, as the server last described it, and the intents the
 * window sends. Nothing here is authority: every action is a `trade` intent
 * the server validates against its own state, and the view is replaced by
 * whatever the server sends next.
 */
export function useTrade({ session, submit }: { session: SessionSnapshot | null; submit: Submit }) {
    const [view, setView] = useState<TradeView | null>(null)
    const [receivedAt, setReceivedAt] = useState(0)
    const [now, setNow] = useState(() => Date.now())
    // The stack waiting on the "offer how many?" dialog.
    const [prompt, setPrompt] = useState<InventoryItem | undefined>()
    const viewRef = useRef<TradeView | null>(null)
    viewRef.current = view

    useNuiEvent<unknown>("kora_inventory:nui:trade", (raw) => {
        const next = normalizeTradeView(raw)
        if (!next) return
        setView(next)
        const stamp = Date.now()
        setReceivedAt(stamp)
        setNow(stamp)
    })
    useNuiEvent<{ id?: string }>("kora_inventory:nui:tradeEnded", ({ id }) => {
        setView((current) => current && current.id === id ? null : current)
    })
    // No inventory session, no trade window: the server ends the trade when its
    // session closes, and the panel must not outlive it in between.
    useEffect(() => { if (!session) setView(null) }, [session])
    // A dialog never outlives the open phase it was asked in.
    useEffect(() => { if (!view || !canEdit(view)) setPrompt(undefined) }, [view])

    // Clock for the confirm countdown and the time-left display.
    useEffect(() => {
        if (!view) return
        const timer = window.setInterval(() => setNow(Date.now()), 250)
        return () => window.clearInterval(timer)
    }, [view])

    const send = useCallback((op: string, extra: Record<string, unknown> = {}) => {
        const current = viewRef.current
        if (!current) return
        submit("trade", { op, id: current.id, ...extra })
    }, [submit])

    // Keep the lease alive while the window is open, even if this player only watches.
    useEffect(() => {
        if (!view?.id) return
        const timer = window.setInterval(() => send("keepalive"), TRADE_KEEPALIVE_MS)
        return () => window.clearInterval(timer)
    }, [send, view?.id])

    const offer = useCallback((slot: number, amount: number) => send("offer", { slot, amount }), [send])
    const unoffer = useCallback((slot: number) => send("unoffer", { slot }), [send])
    const setCash = useCallback((cash: number) => send("cash", { cash }), [send])
    // Ready and Confirm echo the revision the player is looking at; the server
    // refuses them if the offers changed since.
    const ready = useCallback(() => { const current = viewRef.current; if (current) send("ready", { revision: current.revision }) }, [send])
    const unready = useCallback(() => send("unready"), [send])
    const confirm = useCallback(() => { const current = viewRef.current; if (current) send("confirm", { revision: current.revision }) }, [send])
    const cancel = useCallback(() => send("cancel"), [send])
    const request = useCallback(() => submit("tradeRequest", {}), [submit])
    /** Drop or Shift+click from your inventory: a single item (or a modifier amount) is offered at once, a stack asks how many. */
    const offerItem = useCallback((item: InventoryItem, modifierAmount?: number) => {
        const current = viewRef.current
        if (!current || !canEdit(current)) return
        const amount = dropOfferAmount(item.amount, modifierAmount)
        if (amount === undefined) setPrompt(item)
        else offer(item.slot, amount)
    }, [offer])
    const promptRef = useRef(prompt)
    promptRef.current = prompt
    const confirmPrompt = useCallback((amount: number) => {
        const current = promptRef.current
        setPrompt(undefined)
        if (current) offer(current.slot, amount)
    }, [offer])
    const cancelPrompt = useCallback(() => setPrompt(undefined), [])

    const remaining = view ? confirmRemaining(view, receivedAt, now) : 0
    return {
        view,
        active: Boolean(view),
        remaining,
        confirmable: view ? canConfirm(view, receivedAt, now) : false,
        endsInMs: view?.endsInMs !== undefined ? Math.max(0, view.endsInMs - Math.max(0, now - receivedAt)) : undefined,
        prompt, offerItem, confirmPrompt, cancelPrompt,
        offer, unoffer, setCash, ready, unready, confirm, cancel, request,
    }
}

export type TradeState = ReturnType<typeof useTrade>
