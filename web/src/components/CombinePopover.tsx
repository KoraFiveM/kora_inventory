import { useEffect, useRef } from "react"
import { useLocale } from "@/lib/locales"

interface CombinePopoverProps {
    /** The recipe's question, e.g. "Roll a joint". */
    label: string
    fromLabel: string
    toLabel: string
    onConfirm: () => void
    onCancel: () => void
}

/**
 * Small confirm card shown when one item is dropped on another that a recipe
 * pairs it with. Cancel (or Escape, or a click outside) leaves both slots
 * exactly as they were; Combine sends the `combine` intent.
 */
export function CombinePopover({ label, fromLabel, toLabel, onConfirm, onCancel }: CombinePopoverProps) {
    const t = useLocale()
    const confirm = useRef<HTMLButtonElement>(null)
    useEffect(() => { confirm.current?.focus() }, [])

    return <div className="combine-backdrop" data-testid="combine-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) onCancel() }} onContextMenu={(event) => { event.preventDefault(); onCancel() }}>
        <div className="combine-popover" role="dialog" aria-modal="true" aria-label={t("ui.combine_title", { label })}
            onKeyDown={(event) => { if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onCancel() } }}>
            <h3>{t("ui.combine_title", { label })}</h3>
            <p className="combine-items">{t("ui.combine_items", { from: fromLabel, to: toLabel })}</p>
            <div className="combine-actions">
                <button type="button" className="quiet-action" onClick={onCancel}>{t("ui.cancel")}</button>
                <button ref={confirm} type="button" className="quiet-action combine-confirm" onClick={onConfirm}>{t("ui.combine")}</button>
            </div>
        </div>
    </div>
}
