import { Check, ClipboardCopy, PackageOpen, X } from "lucide-react"
import { Fragment } from "react"
import { quickAmounts } from "@/lib/quickAmounts"
import { clampGiveAmount } from "@/lib/giveAmount"
import { formatMetaValue } from "@/lib/format"
import { useLocale } from "@/lib/locales"
import type { Selection } from "@/lib/inventory"
import type { InventoryItem, InventoryView } from "@/lib/types"
import { ItemArtwork } from "./ItemArtwork"

export interface InspectorProps {
    /** The selection after the search filter; undefined renders the empty state. */
    inspected: Selection | undefined
    /** The raw selection, only used to explain an item hidden by the search. */
    selected: Selection | undefined
    solo: boolean
    playerId: string
    movePending: boolean
    giveAvailable: boolean
    inspectorCopy: boolean
    /** Preset amount buttons (Config ui.quickAmounts). */
    quickAmounts?: boolean
    inspectorDecimals: number
    copyState: "idle" | "copied" | "failed"
    /** Amount slider/number state for the inspected stack. */
    selectedMax: number
    selectedCount: number
    onAmountChange: (amount: number) => void
    onCopy: (selection: Selection) => void | Promise<void>
    onCloseDrawer: () => void
    onBuy: (inventory: InventoryView, item: InventoryItem, amount: number) => void
    onUse: (inventory: InventoryView, item: InventoryItem) => void
    onSplitSelected: (inventory: InventoryView, item: InventoryItem) => void
    onSubmit: (intent: "drop" | "give", payload: Record<string, unknown>) => void
}

/** The `item-detail` aside: header, artwork, details and the item's actions. */
export function Inspector({ inspected, selected, solo, playerId, movePending, giveAvailable, inspectorCopy, quickAmounts: showQuickAmounts, inspectorDecimals, copyState, selectedMax, selectedCount, onAmountChange, onCopy, onCloseDrawer, onBuy, onUse, onSplitSelected, onSubmit }: InspectorProps) {
    const t = useLocale()
    const presets = showQuickAmounts && selectedMax > 1 ? <div className="quick-amounts" role="group" aria-label={t("ui.quick_amounts")}>{quickAmounts(selectedMax).map((entry) => <button key={entry.key} type="button" className={`quick-amount${entry.value === selectedCount ? " quick-amount-active" : ""}`} disabled={movePending} onClick={() => onAmountChange(entry.value)}>{entry.key === "half" ? "½" : entry.key === "all" ? t("ui.all") : entry.key}</button>)}</div> : null
    return <aside className={`item-detail${solo ? " item-detail-drawer" : ""}${inspected ? "" : " item-detail-empty"}${inspected && inspectorCopy ? " item-detail-copyable" : ""}`} aria-label={t("ui.selected_item_actions")}>
                <header className="detail-header"><span>{t("ui.item_inspector")}</span><span className="detail-header-actions"><em>{inspected ? t("ui.selected") : t("ui.select_an_item")}</em>{inspected && inspectorCopy && <button className={`detail-copy${copyState === "idle" ? "" : ` detail-copy-${copyState}`}`} onClick={() => void onCopy(inspected)} aria-label={t("ui.copy_item_details")} title={`${t("ui.copy_item_details")} (JSON)`}>{copyState === "copied" ? <Check size={12} /> : <ClipboardCopy size={12} />}<span>{copyState === "copied" ? t("ui.copied") : copyState === "failed" ? t("ui.copy_failed") : t("ui.copy")}</span></button>}{solo && <button className="detail-close" onClick={onCloseDrawer} aria-label={t("ui.close_item_drawer")}><X size={14} /></button>}</span></header>
                {inspected ? <>
                <ItemArtwork item={inspected.item} className="detail-art" />
                <p className="eyebrow">{inspected.inventory.type === "shop" ? t("ui.shop_item") : t("ui.slot_number", { slot: inspected.item.slot })}</p>
                <h1>{inspected.item.label ?? inspected.item.name}</h1>
                <p>{inspected.item.description ?? t("ui.no_item_description")}</p>
                <dl><dt>{t("ui.amount")}</dt><dd>×{inspected.item.amount}</dd><dt>{t("ui.weight")}</dt><dd>{inspected.item.weight ?? 0} g</dd>{inspected.item.displayMeta?.map((meta, index) => <Fragment key={index}><dt>{meta.label}</dt><dd>{formatMetaValue(meta.value, inspectorDecimals)}</dd></Fragment>)}{inspected.inventory.type === "shop" && <><dt>{t("ui.price")}</dt><dd>${(inspected.item.price ?? 0).toLocaleString()}</dd></>}</dl>
                {inspected.inventory.type === "shop" ? <div className="amount-action">
                    {selectedMax > 1 && <input data-fft-kind="quantity" className="amount-slider" type="range" min={1} max={selectedMax} step={1} value={selectedCount} disabled={movePending} aria-label={t("ui.quantity_to_buy", { amount: selectedMax })} onChange={(event) => onAmountChange(Number(event.target.value))} />}
                    {presets}
                    <button data-fft-kind="buy" data-fft-item={inspected.item.name} data-fft-quantity={selectedCount} className="primary-action" disabled={movePending} onClick={() => onBuy(inspected.inventory, inspected.item, selectedCount)}>{t("ui.buy_amount_price", { amount: selectedCount, price: ((inspected.item.price ?? 0) * selectedCount).toLocaleString() })}</button>
                </div> : <>
                    {(inspected.item.useable || inspected.item.container) && <button className="primary-action" disabled={movePending} onClick={() => onUse(inspected.inventory, inspected.item)}>{inspected.item.container ? t("ui.open_container", { item: inspected.item.label ?? "container" }) : t("ui.use_item")}</button>}
                    {selectedMax > 1 && <div className="amount-picker"><input className="amount-slider" type="range" min={1} max={selectedMax} step={1} value={selectedCount} disabled={movePending} aria-label={t("ui.amount_to_move", { amount: selectedMax })} onChange={(event) => onAmountChange(Number(event.target.value))} /><input className="amount-input" type="number" min={1} max={selectedMax} value={selectedCount} disabled={movePending} aria-label={t("ui.amount_to_move", { amount: selectedMax })} onChange={(event) => onAmountChange(Number(event.target.value))} /></div>}
                    {presets}
                    {selectedMax > 1 && <button className="quiet-action" disabled={movePending} onClick={() => onSplitSelected(inspected.inventory, inspected.item)}>{t("ui.split_amount", { amount: selectedCount, remaining: selectedMax - selectedCount })}</button>}
                    {inspected.inventory.id === playerId && <>
                        <div className="amount-action">
                            <button className="quiet-action" disabled={movePending} onClick={() => void onSubmit("drop", { inventory: inspected.inventory.id, slot: inspected.item.slot, amount: selectedCount })}>{t("ui.drop_amount", { amount: selectedCount })}</button>
                        </div>
                        {giveAvailable && <button className="quiet-action" disabled={movePending} onClick={() => void onSubmit("give", { inventory: inspected.inventory.id, slot: inspected.item.slot, amount: clampGiveAmount(selectedCount, inspected.item.amount) })}>{t("ui.give_amount", { amount: selectedCount })}</button>}
                    </>}
                </>}
            </> : <div className="empty-detail"><span className="empty-detail-icon"><PackageOpen size={30} /></span><h1>{t("ui.inspect_item")}</h1><p>{selected ? t("ui.hidden_by_search", { item: selected.item.label ?? selected.item.name }) : t("ui.select_item_help")}</p></div>}</aside>
}
