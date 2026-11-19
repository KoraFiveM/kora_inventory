import { createContext, type ReactNode, useContext, useEffect, useMemo, useState } from "react"

export const DEFAULT_LOCALES: Record<string, string> = {
    "ui.inventory_label": "Inventory",
    "ui.revision": "Revision %{revision}",
    "ui.slot_item": "%{item}, slot %{slot}",
    "ui.slot_number": "Slot %{slot}",
    "ui.split_amount": "Split %{amount} / %{remaining}",
    "ui.drop_amount": "Drop %{amount}",
    "ui.amount": "Amount",
    "ui.weight": "Weight",
    "ui.price": "Price",
    "ui.empty_slot": "Empty slot %{slot}",
    "ui.received": "Received",
    "ui.purchased": "Purchased",
    "ui.removed": "Removed",
    "ui.used": "Used",
    "ui.updated": "Updated",
    "ui.item_receipts": "Item receipts",
    "ui.hotbar": "Hotbar",
    "ui.release_to_drop": "Release to drop on the ground",
    "ui.drag_out_to_drop": "Drag outside the window to drop",
    "ui.updating_inventory": "Updating inventory…",
    "ui.cannot_drop": "This item cannot be dropped",
    "ui.action_rejected": "Action rejected by inventory",
    "ui.inventory_timeout": "Inventory did not respond",
    "ui.too_many_moves": "Too many moves waiting for the server",
    "ui.item_unavailable": "That item is no longer available",
    "ui.shop_player_only": "Shop items can only be purchased into your inventory",
    "ui.shop_read_only": "Shop inventory is read only",
    "ui.choose_split_amount": "Choose an amount from 1 to %{amount}",
    "ui.no_empty_slot": "No empty slot available to split this stack",
    "ui.use_player_item_only": "Only items in your inventory can be used",
    "ui.shop_item_unavailable": "Shop item or player inventory is unavailable",
    "ui.no_destination_slot": "No destination slot available",
    "ui.player_slot_rejects_shop_item": "Player slot cannot accept the shop item",
    "ui.filter_selected_item": "Filter the selected item",
    "ui.transfer_open": "Transfer open",
    "ui.personal_inventory": "Personal inventory",
    "ui.close_inventory": "Close inventory",
    "ui.selected_item_actions": "Selected item actions",
    "ui.selected": "Selected",
    "ui.select_an_item": "Select an item",
    "ui.copy_item_details": "Copy item details and metadata",
    "ui.copied": "Copied",
    "ui.copy_failed": "Copy failed",
    "ui.copy": "Copy",
    "ui.close_item_drawer": "Close item drawer",
    "ui.shop_item": "shop item",
    "ui.quantity_to_buy": "Quantity to buy, 1 to %{amount}",
    "ui.amount_to_move": "Amount to move, 1 to %{amount}",
    "ui.use_item": "Use item",
    "ui.open_container": "Open %{item}",
    "ui.buy_amount_price": "Buy %{amount} · $%{price}",
    "ui.give_amount": "Give %{amount}",
    "ui.no_item_description": "No item description available.",
    "ui.item_inspector": "Item inspector",
    "ui.inspect_item": "Inspect an item",
    "ui.no_secondary_inventory": "No secondary inventory",
    "ui.open_secondary_inventory": "Open a stash, shop, container, or another player to use this panel.",
    "ui.hidden_by_search": "%{item} is hidden by the current search.",
    "ui.select_item_help": "Select an item to see its details. Drag it between slots to move or stack it, or drag it outside the window to drop it.",
    "ui.close": "Close",
    "ui.use_selected": "Use selected",
    "ui.move_or_stack": "Move or stack",
    "ui.drop": "Drop",
    "ui.split_dialog": "Split %{item}",
    "ui.split_title": "Split %{item}",
    "ui.move_how_many": "Move how many? (1–%{amount})",
    "ui.cancel": "Cancel",
    "ui.split": "Split",
}

type LocaleContextValue = (key: string, values?: Record<string, string | number>) => string
const LocaleContext = createContext<LocaleContextValue>((key, values = {}) => {
    const template = DEFAULT_LOCALES[key] ?? key
    return template.replace(/%\{(\w+)\}/g, (_, name: string) => String(values[name] ?? `%{${name}}`))
})

export function LocaleProvider({ children }: { children: ReactNode }) {
    const [locales, setLocales] = useState(DEFAULT_LOCALES)

    useEffect(() => {
        const receive = (event: MessageEvent<{ action?: string; data?: unknown }>) => {
            if (event.data?.action !== "kora_inventory:nui:locales" || !event.data.data || typeof event.data.data !== "object") return
            const incoming = event.data.data as Record<string, unknown>
            setLocales((current) => ({
                ...current,
                ...Object.fromEntries(Object.entries(incoming).filter((entry): entry is [string, string] => typeof entry[1] === "string")),
            }))
        }
        window.addEventListener("message", receive)
        return () => window.removeEventListener("message", receive)
    }, [])

    const translate = useMemo<LocaleContextValue>(() => (key, values = {}) => {
        const template = locales[key] ?? DEFAULT_LOCALES[key] ?? key
        return template.replace(/%\{(\w+)\}/g, (_, name: string) => String(values[name] ?? `%{${name}}`))
    }, [locales])

    return <LocaleContext.Provider value={translate}>{children}</LocaleContext.Provider>
}

export function useLocale() {
    return useContext(LocaleContext)
}
