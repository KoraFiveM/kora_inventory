import type { HotbarQuickEntry, InventoryItem } from "@/lib/types"
import { useLocale } from "@/lib/locales"
import { ItemArtwork } from "./ItemArtwork"

export interface HotbarState {
    id: number
    bottom?: number
    slots: Array<Partial<InventoryItem> & { slot: number }>
    /** Resolved quick slots (shortcuts to real items) shown after the numbered slots. */
    quick?: HotbarQuickEntry[]
}

/** Keeps only well-formed quick entries; anything else in the payload is ignored. */
export function sanitizeHotbarQuick(quick: unknown): HotbarQuickEntry[] {
    if (!Array.isArray(quick)) return []
    return quick.filter((entry): entry is HotbarQuickEntry => Boolean(entry) && typeof entry === "object" && typeof (entry as HotbarQuickEntry).name === "string" && (entry as HotbarQuickEntry).name !== "")
}

export function HotbarHud({ hotbar }: { hotbar: HotbarState }) {
    const t = useLocale()
    const quick = hotbar.quick ?? []
    return <aside className="hotbar-hud" aria-label={t("ui.hotbar")} style={Number.isFinite(hotbar.bottom) ? { bottom: `${hotbar.bottom}px` } : undefined}>
        {hotbar.slots.map((item) => <div className={`hotbar-slot${item.name ? "" : " hotbar-slot-empty"}`} key={item.slot}>
            <kbd>{item.slot}</kbd>
            {item.name ? <>
                <ItemArtwork item={item as InventoryItem} className="hotbar-art" />
                <strong>{item.label ?? item.name}</strong>
                {(item.amount ?? 1) > 1 && <b>×{item.amount}</b>}
            </> : null}
        </div>)}
        {quick.length > 0 && <span className="hotbar-divider" role="separator" aria-hidden="true" />}
        {quick.map((entry, index) => <div className="hotbar-slot hotbar-slot-quick" data-quick={entry.id} key={entry.id ?? index} title={entry.slotLabel}>
            {entry.key ? <kbd>{entry.key}</kbd> : null}
            <ItemArtwork item={{ name: entry.name ?? "", label: entry.label, image: entry.image }} className="hotbar-art" />
            <strong>{entry.label ?? entry.slotLabel ?? entry.name}</strong>
            {(entry.amount ?? 1) > 1 && <b>×{entry.amount}</b>}
        </div>)}
    </aside>
}
