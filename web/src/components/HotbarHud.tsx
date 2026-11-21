import type { InventoryItem } from "@/lib/types"
import { useLocale } from "@/lib/locales"
import { ItemArtwork } from "./ItemArtwork"

export interface HotbarState { id: number; bottom?: number; slots: Array<Partial<InventoryItem> & { slot: number }> }

export function HotbarHud({ hotbar }: { hotbar: HotbarState }) {
    const t = useLocale()
    return <aside className="hotbar-hud" aria-label={t("ui.hotbar")} style={Number.isFinite(hotbar.bottom) ? { bottom: `${hotbar.bottom}px` } : undefined}>
        {hotbar.slots.map((item) => <div className={`hotbar-slot${item.name ? "" : " hotbar-slot-empty"}`} key={item.slot}>
            <kbd>{item.slot}</kbd>
            {item.name ? <>
                <ItemArtwork item={item as InventoryItem} className="hotbar-art" />
                <strong>{item.label ?? item.name}</strong>
                {(item.amount ?? 1) > 1 && <b>×{item.amount}</b>}
            </> : null}
        </div>)}
    </aside>
}
