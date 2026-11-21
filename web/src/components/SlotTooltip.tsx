import { useLayoutEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { formatMetaValue } from "@/lib/format"
import { useLocale } from "@/lib/locales"
import type { InventoryItem } from "@/lib/types"

const MARGIN = 8
const OFFSET = 16

/** Hover details for a filled slot: label, amount, weight, description, durability, display rows. */
export function SlotTooltip({ item, x, y, decimals }: { item: InventoryItem; x: number; y: number; decimals: number }) {
    const t = useLocale()
    const ref = useRef<HTMLDivElement>(null)
    const [pos, setPos] = useState({ left: x + OFFSET, top: y + OFFSET })
    // Placed near the cursor, then clamped so it never leaves the viewport.
    useLayoutEffect(() => {
        const box = ref.current?.getBoundingClientRect()
        const width = box?.width ?? 0
        const height = box?.height ?? 0
        const left = Math.max(MARGIN, Math.min(x + OFFSET, window.innerWidth - width - MARGIN))
        const top = Math.max(MARGIN, Math.min(y + OFFSET, window.innerHeight - height - MARGIN))
        setPos({ left, top })
    }, [x, y, item])
    return createPortal(
        <div ref={ref} className="slot-tooltip" role="tooltip" style={{ left: pos.left, top: pos.top }}>
            <strong>{item.label ?? item.name}</strong>
            <dl>
                <dt>{t("ui.amount")}</dt><dd>×{item.amount}</dd>
                <dt>{t("ui.weight")}</dt><dd>{item.weight ?? 0} g</dd>
                {typeof item.durability === "number" && <><dt>{t("ui.durability")}</dt><dd>{Math.round(item.durability)}%</dd></>}
                {item.displayMeta?.map((meta, index) => <div key={index} className="slot-tooltip-row"><dt>{meta.label}</dt><dd>{formatMetaValue(meta.value, decimals)}</dd></div>)}
            </dl>
            {item.description && <p>{item.description}</p>}
        </div>,
        document.body,
    )
}
