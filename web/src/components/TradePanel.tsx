import { useContext, useEffect, useRef, useState } from "react"
import { useDrag, useDrop } from "react-dnd"
import { ArrowLeftRight, Check, CircleAlert, Clock, Handshake, Lock, X } from "lucide-react"
import { UiConfigContext } from "@/context"
import type { TradeState } from "@/hooks/useTrade"
import { findItem, type DragSlot } from "@/lib/inventory"
import { useLocale } from "@/lib/locales"
import { modifierDragAmount } from "@/lib/modifierDrag"
import { canEdit, canReady, formatDuration, hasFreeOfferCell, offerCells, parseCash, parseOfferAmount, tradeStatus } from "@/lib/trade"
import type { InventoryItem, InventoryView, TradeOffer, TradeSide } from "@/lib/types"
import { ItemArtwork } from "./ItemArtwork"
import { SLOT_DRAG_TYPE, TRADE_OFFER_DRAG_TYPE } from "./dnd"

/** Asks how many of a stack to offer (window.prompt would freeze CEF). */
function TradeAmountDialog({ item, onConfirm, onCancel }: { item: InventoryItem; onConfirm: (amount: number) => void; onCancel: () => void }) {
    const t = useLocale()
    const label = item.label ?? item.name
    const [value, setValue] = useState(String(Math.floor(item.amount)))
    const [invalid, setInvalid] = useState(false)
    const input = useRef<HTMLInputElement>(null)
    useEffect(() => { input.current?.focus(); input.current?.select() }, [])
    const submit = () => {
        const parsed = parseOfferAmount(value, item.amount)
        if ("error" in parsed) { setInvalid(true); return }
        onConfirm(parsed.amount)
    }
    return <div className="split-backdrop" data-testid="trade-amount-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }} onContextMenu={(event) => { event.preventDefault(); onCancel() }}>
        <form className="split-dialog trade-amount-dialog" role="dialog" aria-modal="true" aria-label={t("ui.trade_offer_amount", { item: label })} onSubmit={(event) => { event.preventDefault(); submit() }}
            onKeyDown={(event) => { if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onCancel() } }}>
            <h3>{t("ui.trade_offer_amount", { item: label })}</h3>
            <label>{t("ui.amount_to_move", { amount: Math.floor(item.amount) })}
                <input ref={input} type="number" inputMode="numeric" min={1} max={Math.floor(item.amount)} value={value} onChange={(event) => { setValue(event.target.value); setInvalid(false) }} />
            </label>
            {invalid && <p className="split-error" role="alert">{t("ui.choose_split_amount", { amount: Math.floor(item.amount) })}</p>}
            <div className="split-actions">
                <button type="button" className="quiet-action" onClick={onCancel}>{t("ui.cancel")}</button>
                <button type="submit" className="quiet-action split-confirm">{t("ui.trade_offer")}</button>
            </div>
        </form>
    </div>
}

/** One offered stack. Own offers can be dragged away or right-clicked to withdraw them. */
function OfferCell({ offer, own, playerId, editable, onRemove }: { offer?: TradeOffer; own: boolean; playerId: string; editable: boolean; onRemove: (slot: number) => void }) {
    const t = useLocale()
    const [{ dragging }, dragRef] = useDrag<DragSlot, unknown, { dragging: boolean }>(() => ({
        type: TRADE_OFFER_DRAG_TYPE,
        item: () => ({ inventoryId: playerId, slot: offer?.slot ?? 0 }),
        canDrag: own && editable && Boolean(offer),
        // Released anywhere but back on the offer area: withdraw the offer.
        end: (_, monitor) => { if (offer && !monitor.didDrop()) onRemove(offer.slot) },
        collect: (monitor) => ({ dragging: monitor.isDragging() }),
    }), [editable, offer, onRemove, own, playerId])
    if (!offer) return <div className="slot trade-cell trade-cell-empty" aria-label={t("ui.trade_empty_offer")}><span className="trade-cell-hint">{own && editable ? "+" : ""}</span></div>
    const label = offer.label ?? offer.name
    return <div
        ref={(node) => { dragRef(node) }}
        className={`slot slot-filled trade-cell${dragging ? " slot-drag-source" : ""}${own && editable ? " trade-cell-own" : ""}`}
        role="listitem"
        aria-label={t("ui.slot_item", { item: label, slot: offer.slot })}
        title={own && editable ? t("ui.trade_remove_offer") : label}
        data-testid={own ? "trade-own-offer" : "trade-partner-offer"}
        onContextMenu={(event) => {
            event.preventDefault()
            if (own && editable) onRemove(offer.slot)
        }}
    >
        <ItemArtwork item={offer} className="item-art" />
        <span className="item-footer"><span className="item-label">{label}</span></span>
        <span className="item-amount">×{offer.amount}</span>
    </div>
}

function SideHeader({ title, side, phase, partner }: { title: string; side: TradeSide; phase: string; partner: boolean }) {
    const t = useLocale()
    const state = side.confirmed ? "confirmed" : side.ready ? "ready" : "waiting"
    const text = partner
        ? side.confirmed ? t("ui.trade_partner_confirmed") : side.ready ? t("ui.trade_partner_ready") : t("ui.trade_partner_not_ready")
        : side.confirmed ? t("ui.trade_you_confirmed") : side.ready ? t("ui.trade_you_ready") : t("ui.trade_unready")
    return <header className="trade-side-header">
        <h3>{title}</h3>
        <span className={`trade-flag trade-flag-${state}`} data-testid={partner ? "trade-partner-flag" : "trade-own-flag"} data-state={state}>
            {state === "confirmed" ? <Check size={12} /> : state === "ready" ? (phase === "locked" ? <Lock size={12} /> : <Check size={12} />) : <Clock size={12} />}
            {text}
        </span>
    </header>
}

function CashField({ side, editable, onSet }: { side: TradeSide; editable: boolean; onSet: (amount: number) => void }) {
    const t = useLocale()
    const [value, setValue] = useState(String(side.cash || ""))
    const [invalid, setInvalid] = useState(false)
    // The server's figure wins whenever it changes (an offer reset, a refusal).
    useEffect(() => { setValue(side.cash ? String(side.cash) : ""); setInvalid(false) }, [side.cash])
    const apply = () => {
        const parsed = parseCash(value, side.balance)
        if ("error" in parsed) { setInvalid(true); return }
        if (parsed.amount !== side.cash) onSet(parsed.amount)
    }
    return <form className={`trade-cash${invalid ? " trade-cash-invalid" : ""}`} onSubmit={(event) => { event.preventDefault(); apply() }}>
        <label>
            <span>{t("ui.trade_cash")}</span>
            <input type="number" inputMode="numeric" min={0} max={side.balance} step={1} value={value} disabled={!editable} placeholder="0"
                aria-invalid={invalid || undefined} onChange={(event) => { setValue(event.target.value); setInvalid(false) }} onBlur={() => { if (editable) apply() }} />
        </label>
        {side.balance !== undefined && <small>{t("ui.trade_cash_balance", { amount: side.balance.toLocaleString() })}</small>}
        <button type="submit" className="quiet-action" disabled={!editable}>{t("ui.trade_set_cash")}</button>
    </form>
}

/**
 * The trade window, rendered as the secondary panel of every layout. Your
 * side takes drops from your own inventory (offers are references the server
 * re-checks; nothing moves until both confirm). The partner's side is
 * read-only and shows only what the server describes.
 */
export function TradePanel({ trade, player, busy }: { trade: TradeState; player: InventoryView; busy: boolean }) {
    const t = useLocale()
    const { modifierDrag } = useContext(UiConfigContext)
    const view = trade.view
    const editable = Boolean(view && canEdit(view)) && !busy
    const [{ over, droppable }, dropRef] = useDrop<DragSlot, unknown, { over: boolean; droppable: boolean }>(() => ({
        accept: [SLOT_DRAG_TYPE, TRADE_OFFER_DRAG_TYPE],
        canDrop: (source, monitor) => {
            if (!view || !editable || !source || source.inventoryId !== player.id) return false
            if (monitor.getItemType() === TRADE_OFFER_DRAG_TYPE) return true
            return Boolean(findItem(player, source.slot)) && hasFreeOfferCell(view, source.slot)
        },
        drop: (source, monitor) => {
            // Dropping an offer back on the offer area keeps it.
            if (monitor.getItemType() === TRADE_OFFER_DRAG_TYPE) return { kept: true }
            const item = findItem(player, source.slot)
            if (item) trade.offerItem(item, modifierDrag ? modifierDragAmount(source.modifiers, item.amount) : undefined)
            return { offered: true }
        },
        collect: (monitor) => ({ over: monitor.isOver(), droppable: monitor.canDrop() }),
    }), [editable, modifierDrag, player, trade.offerItem, view])
    if (!view) return null
    const status = tradeStatus(view, trade.remaining)
    const seconds = Math.ceil(trade.remaining / 1000)
    const yours = offerCells(view.you, view.slots)
    const theirs = offerCells(view.them, view.slots)
    const statusText = {
        editing: t("ui.trade_waiting"),
        you_ready: t("ui.trade_waiting"),
        partner_ready: t("ui.trade_partner_ready"),
        countdown: t("ui.trade_countdown", { seconds }),
        confirm: t("ui.trade_locked"),
        you_confirmed: t("ui.trade_waiting"),
        committing: t("ui.updating_inventory"),
    }[status]

    return <section className="inventory-panel trade-panel" aria-label={t("ui.trade")} data-phase={view.phase} data-testid="trade-panel">
        <header className="panel-header trade-header">
            <div><p className="eyebrow">{t("ui.trade")}</p><h2><Handshake size={16} /> {t("ui.trade")}</h2></div>
            {trade.endsInMs !== undefined && <span className="trade-timer"><Clock size={12} />{t("ui.trade_ends_in", { time: formatDuration(trade.endsInMs) })}</span>}
        </header>
        <div className="trade-sides">
            <div className={`trade-side trade-side-own${over && droppable ? " trade-side-target" : ""}${over && !droppable ? " trade-side-invalid" : ""}`} ref={(node) => { dropRef(node) }} data-testid="trade-own-side">
                <SideHeader title={t("ui.trade_you_offer")} side={view.you} phase={view.phase} partner={false} />
                <div className="trade-grid" role="list" aria-label={t("ui.trade_you_offer")}>
                    {yours.map((offer, index) => <OfferCell key={offer ? `o${offer.slot}` : `e${index}`} offer={offer} own playerId={player.id} editable={editable} onRemove={trade.unoffer} />)}
                </div>
                {editable && view.you.offers.length === 0 && <p className="trade-hint">{t("ui.trade_drop_here")}</p>}
                {view.allowCash && <CashField side={view.you} editable={editable} onSet={trade.setCash} />}
            </div>
            <div className="trade-divider" aria-hidden="true"><ArrowLeftRight size={16} /></div>
            <div className="trade-side trade-side-partner" data-testid="trade-partner-side">
                <SideHeader title={t("ui.trade_they_offer")} side={view.them} phase={view.phase} partner />
                <div className="trade-grid" role="list" aria-label={t("ui.trade_they_offer")}>
                    {theirs.map((offer, index) => <OfferCell key={offer ? `o${offer.slot}` : `e${index}`} offer={offer} own={false} playerId={player.id} editable={false} onRemove={trade.unoffer} />)}
                </div>
                {view.them.offers.length === 0 && view.them.cash === 0 && <p className="trade-hint">{t("ui.trade_nothing_offered")}</p>}
                {view.allowCash && <p className="trade-cash-readonly"><span>{t("ui.trade_cash")}</span><b>${view.them.cash.toLocaleString()}</b></p>}
            </div>
        </div>
        {view.lastError && <div className="notice trade-error" role="alert"><CircleAlert size={14} />{view.lastError}</div>}
        <p className={`trade-status trade-status-${status}`} role="status" data-testid="trade-status">{status === "countdown" ? <Clock size={13} /> : view.phase === "locked" ? <Lock size={13} /> : null}{statusText}</p>
        <footer className="trade-actions">
            <button type="button" className="quiet-action trade-cancel" onClick={trade.cancel} disabled={view.phase === "committing"}><X size={14} />{t("ui.trade_cancel")}</button>
            {view.phase === "open" && (view.you.ready
                ? <button type="button" className="quiet-action trade-unready" onClick={trade.unready}>{t("ui.trade_unready")}</button>
                : <button type="button" className="quiet-action trade-ready" onClick={trade.ready} disabled={!canReady(view) || busy}><Check size={14} />{t("ui.trade_ready")}</button>)}
            {view.phase === "locked" && <>
                <button type="button" className="quiet-action trade-unready" onClick={trade.unready} disabled={view.you.confirmed}>{t("ui.trade_unready")}</button>
                <button type="button" className="quiet-action trade-confirm" onClick={trade.confirm} disabled={!trade.confirmable || busy} data-testid="trade-confirm">
                    <Handshake size={14} />{status === "countdown" ? t("ui.trade_countdown", { seconds }) : t("ui.trade_confirm")}
                </button>
            </>}
        </footer>
        {trade.prompt && <TradeAmountDialog item={trade.prompt} onConfirm={(amount) => trade.confirmPrompt(amount)} onCancel={trade.cancelPrompt} />}
    </section>
}

