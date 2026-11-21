import { CircleAlert, PackageOpen, Search, X } from "lucide-react"
import { useLocale } from "@/lib/locales"

/** Brand, search box, session state, close button and the refusal notice. */
export function TopBar({ transfer, query, onQueryChange, error, onClose }: {
    transfer: boolean
    query: string
    onQueryChange: (query: string) => void
    error?: string
    onClose: () => void
}) {
    const t = useLocale()
    return <div className="inventory-heading">
        <header className="inventory-topbar">
            <div className="brand"><span className="brand-mark"><PackageOpen size={18} /></span><span>{t("ui.inventory_label")}</span></div>
            <label className="search"><Search size={16} /><input value={query} onChange={(event) => onQueryChange(event.target.value)} placeholder={t("ui.filter_selected_item")} /></label>
            <div className="topbar-actions"><span className="session-state">{transfer ? t("ui.transfer_open") : t("ui.personal_inventory")}</span><button className="close" onClick={onClose} aria-label={t("ui.close_inventory")}><X size={18} /></button></div>
        </header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
    </div>
}
