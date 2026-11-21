import { useLocale } from "@/lib/locales"
import type { InventoryItem } from "@/lib/types"

/** Red "Jammed" badge for a weapon whose server-set `jammed` view field is true. View-only. */
export function JammedBadge({ item, className }: { item: Pick<InventoryItem, "jammed">; className?: string }) {
    const t = useLocale()
    if (item.jammed !== true) return null
    return <span className={`jammed-badge${className ? ` ${className}` : ""}`} role="status">{t("ui.jammed")}</span>
}
