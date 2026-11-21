import type { ItemBoxReceipt } from "@/lib/types"
import { useLocale } from "@/lib/locales"
import { ItemArtwork } from "./ItemArtwork"

export interface ActiveItemBox extends ItemBoxReceipt { id: number }

const ITEM_BOX_ACTIONS = {
    add: { key: "ui.received", sign: "+", tone: "gain" },
    purchase: { key: "ui.purchased", sign: "+", tone: "gain" },
    remove: { key: "ui.removed", sign: "-", tone: "loss" },
    use: { key: "ui.used", sign: "-", tone: "loss" },
} as const

export function ItemBoxStack({ boxes }: { boxes: ActiveItemBox[] }) {
    const t = useLocale()
    if (!boxes.length) return null
    return <aside className="item-box-stack" aria-live="polite" aria-label={t("ui.item_receipts")}>
        {boxes.map((box) => {
            // A receipt for an action this build does not know about still
            // reads correctly as an unsigned change rather than a false gain. A signed
            // receipt shows +1 / -1 only; the x multiplier is for unsigned ones.
            const action = ITEM_BOX_ACTIONS[box.action] ?? { key: "ui.updated", sign: "", tone: "neutral" }
            return <div className={`item-box item-box-${action.tone}`} key={box.id}>
                <ItemArtwork item={box} className="item-box-art" />
                <div><p>{t(action.key)}</p><strong>{box.label ?? box.name}</strong></div>
                <b>{action.sign ? `${action.sign}${box.amount}` : `×${box.amount}`}</b>
            </div>
        })}
    </aside>
}
