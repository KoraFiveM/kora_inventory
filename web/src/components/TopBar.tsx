import { CircleAlert, Handshake, PackageOpen, Search, X } from "lucide-react"
import { useLocale } from "@/lib/locales"

/** Brand, search box, session state, close button and the refusal notice. */
export function TopBar({ transfer, query, onQueryChange, error, onClose, trading, onTrade }: {
    transfer: boolean
    query: string
    onQueryChange: (query: string) => void
    error?: string
    onClose: () => void
    /** A trade window is open (changes the session label). */
    trading?: boolean
    /** Shown only while a trade partner is in range and trading is enabled. */
    onTrade?: () => void
}) {
    const t = useLocale()
    return <div className="inventory-heading">
        <header className="inventory-topbar">
            <div className="brand"><span className="brand-mark"><PackageOpen size={18} /></span><span>{t("ui.inventory_label")}</span></div>
            <label className="search"><Search size={16} /><input value={query} onChange={(event) => onQueryChange(event.target.value)} placeholder={t("ui.filter_selected_item")} /></label>
            <div className="topbar-actions">{onTrade && <button type="button" className="quiet-action trade-request" onClick={onTrade} title={t("ui.trade_request")} data-testid="trade-request"><Handshake size={15} />{t("ui.trade")}</button>}<span className="session-state">{trading ? t("ui.trade") : transfer ? t("ui.transfer_open") : t("ui.personal_inventory")}</span><button className="close" onClick={onClose} aria-label={t("ui.close_inventory")}><X size={18} /></button></div>
        </header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
    </div>
}
