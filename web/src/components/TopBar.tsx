import { useContext, useEffect, useRef, useState } from "react"
import { CircleAlert, Keyboard, PackageOpen, Search, X } from "lucide-react"
import { UiConfigContext } from "@/context"
import { controlsVisible, loadControlsChoice, saveControlsChoice } from "@/lib/controls"
import { useLocale } from "@/lib/locales"
import { setControls } from "@/lib/nui"

/** Brand, search box, session state, controls toggle, close button and the refusal notice. */
export function TopBar({ transfer, query, onQueryChange, error, onClose }: {
    transfer: boolean
    query: string
    onQueryChange: (query: string) => void
    error?: string
    onClose: () => void
}) {
    const t = useLocale()
    const { controls } = useContext(UiConfigContext)
    const [choice, setChoice] = useState<boolean | undefined>(() => loadControlsChoice())
    const visible = controlsVisible(controls, choice)
    const sent = useRef<boolean | undefined>(undefined)

    // The window mounts after the session opens (and again if the layout is
    // switched), so this re-shows the overlay the player left on. The Lua side
    // hides it whenever the session closes. It is only ever asked to show when
    // the button exists, and only asked to hide after it has been shown.
    useEffect(() => {
        if (sent.current === visible) return
        if (!visible && sent.current === undefined) { sent.current = false; return }
        sent.current = visible
        void setControls(visible)
    }, [visible])

    const toggle = () => {
        const next = !visible
        saveControlsChoice(next)
        setChoice(next)
    }

    return <div className="inventory-heading">
        <header className="inventory-topbar">
            <div className="brand"><span className="brand-mark"><PackageOpen size={18} /></span><span>{t("ui.inventory_label")}</span></div>
            <label className="search"><Search size={16} /><input value={query} onChange={(event) => onQueryChange(event.target.value)} placeholder={t("ui.filter_selected_item")} /></label>
            <div className="topbar-actions">
                <span className="session-state">{transfer ? t("ui.transfer_open") : t("ui.personal_inventory")}</span>
                {controls.button && <button type="button" className={`close controls-toggle${visible ? " controls-toggle-on" : ""}`} onClick={toggle} aria-pressed={visible} title={t(visible ? "ui.controls_hide" : "ui.controls_show")} aria-label={t(visible ? "ui.controls_hide" : "ui.controls_show")}><Keyboard size={18} /></button>}
                <button className="close" onClick={onClose} aria-label={t("ui.close_inventory")}><X size={18} /></button>
            </div>
        </header>
        {error && <div className="notice" role="alert"><CircleAlert size={16} />{error}</div>}
    </div>
}
