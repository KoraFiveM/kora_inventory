import { useCallback, useEffect, useRef, useState, type FormEvent } from "react"
import { Search, X } from "lucide-react"
import { AUDIT_RANGES, auditPlayer, emptyAuditFilter, formatAuditTime } from "@/lib/audit"
import { useLocale } from "@/lib/locales"
import { closeAudit, queryAudit } from "@/lib/nui"
import { useNuiEvent } from "@/lib/useNuiEvent"
import type { AuditFilter, AuditResult, AuditSummaryRow } from "@/lib/types"

function Summary({ title, rows }: { title: string; rows: AuditSummaryRow[] }) {
    return <section className="audit-summary-block" aria-label={title}>
        <h3>{title}</h3>
        <ol>{rows.length === 0 ? <li className="audit-muted">—</li> : rows.map((row) => <li key={row.name}><span>{row.name}</span><b>{row.amount.toLocaleString()}</b></li>)}</ol>
    </section>
}

/**
 * Admin item-creation audit viewer (/invaudit). Not an inventory session: it has
 * no token and cannot change anything. Data arrives through a server callback
 * that checks the admin permission on every request.
 */
export function AuditViewer() {
    const t = useLocale()
    const [open, setOpen] = useState(false)
    const [filter, setFilter] = useState<AuditFilter>(emptyAuditFilter())
    const [result, setResult] = useState<AuditResult | undefined>()
    const [loading, setLoading] = useState(false)
    const latest = useRef(0)

    const load = useCallback(async (next: AuditFilter) => {
        const ticket = ++latest.current
        setLoading(true)
        const answer = await queryAudit(next)
        // A slower, older answer must not replace a newer one.
        if (ticket !== latest.current) return
        setResult(answer)
        setLoading(false)
    }, [])

    useNuiEvent<{ filter?: Partial<AuditFilter> }>("kora_inventory:nui:auditOpen", (payload) => {
        const next = emptyAuditFilter(payload?.filter)
        setFilter(next)
        setResult(undefined)
        setOpen(true)
        void load(next)
    })
    useNuiEvent("kora_inventory:nui:auditClose", () => { latest.current++; setOpen(false); setLoading(false) })

    const close = useCallback(() => { latest.current++; setOpen(false); setLoading(false); void closeAudit() }, [])
    useEffect(() => {
        if (!open) return
        const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") close() }
        window.addEventListener("keydown", onKey)
        return () => window.removeEventListener("keydown", onKey)
    }, [open, close])

    if (!open) return null

    const submit = (event: FormEvent) => { event.preventDefault(); const next = { ...filter, page: 0 }; setFilter(next); void load(next) }
    const goTo = (page: number) => { const next = { ...filter, page }; setFilter(next); void load(next) }
    const field = (key: "player" | "item" | "resource", label: string) =>
        <label className="audit-field"><span>{label}</span><input value={filter[key]} maxLength={96} onChange={(event) => setFilter({ ...filter, [key]: event.target.value })} /></label>

    return <div className="audit-overlay" role="dialog" aria-modal="true" aria-label={t("ui.audit_title")}>
        <div className="audit-panel">
            <header className="audit-header">
                <h2>{t("ui.audit_title")}</h2>
                <button type="button" className="audit-close" onClick={close} aria-label={t("ui.audit_close")}><X size={16} /></button>
            </header>
            <form className="audit-filters" onSubmit={submit}>
                {field("player", t("ui.audit_filter_player"))}
                {field("item", t("ui.audit_filter_item"))}
                {field("resource", t("ui.audit_filter_resource"))}
                <label className="audit-field audit-field-range"><span>{t("ui.audit_range")}</span>
                    <select value={filter.range} onChange={(event) => setFilter({ ...filter, range: event.target.value as AuditFilter["range"] })}>
                        {AUDIT_RANGES.map((range) => <option key={range} value={range}>{t(`ui.audit_range_${range}`)}</option>)}
                    </select>
                </label>
                <button type="submit" className="primary-action audit-search"><Search size={14} /> {t("ui.audit_search")}</button>
            </form>
            {result?.summary && <div className="audit-summary">
                <Summary title={t("ui.audit_top_resources")} rows={result.summary.resources} />
                <Summary title={t("ui.audit_top_items")} rows={result.summary.items} />
            </div>}
            {result?.source === "memory" && <p className="audit-note">{t("ui.audit_memory_only")}</p>}
            {result?.error && <p className="audit-error" role="alert">{t("ui.audit_error", { error: result.error })}</p>}
            <div className="audit-table-wrap" aria-busy={loading || undefined}>
                <table className="audit-table">
                    <thead><tr>
                        <th>{t("ui.audit_col_time")}</th><th>{t("ui.audit_col_action")}</th><th>{t("ui.audit_col_player")}</th><th>{t("ui.audit_col_item")}</th>
                        <th className="audit-num">{t("ui.audit_col_amount")}</th><th>{t("ui.audit_col_inventory")}</th><th>{t("ui.audit_col_resource")}</th><th>{t("ui.audit_col_reason")}</th>
                    </tr></thead>
                    <tbody>
                        {(result?.rows ?? []).map((row, index) => <tr key={`${row.at}-${index}`}>
                            <td>{formatAuditTime(row.at)}</td><td>{row.action}</td><td>{auditPlayer(row)}</td><td>{row.item}</td>
                            <td className="audit-num">{(row.amount ?? 0).toLocaleString()}</td><td>{row.inventory ?? ""}</td><td>{row.resource ?? ""}</td><td>{row.reason ?? ""}</td>
                        </tr>)}
                    </tbody>
                </table>
                {!loading && result && !result.error && result.rows.length === 0 && <p className="audit-muted audit-empty">{t("ui.audit_empty")}</p>}
                {loading && <p className="audit-muted audit-empty">{t("ui.audit_loading")}</p>}
            </div>
            <footer className="audit-pager">
                <button type="button" className="quiet-action" disabled={loading || filter.page === 0} onClick={() => goTo(filter.page - 1)}>{t("ui.audit_prev")}</button>
                <span>{t("ui.audit_page", { page: filter.page + 1 })}</span>
                <button type="button" className="quiet-action" disabled={loading || !result?.hasMore} onClick={() => goTo(filter.page + 1)}>{t("ui.audit_next")}</button>
            </footer>
        </div>
    </div>
}
