import { useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { UiConfigContext } from "@/context"
import { ammoInfoRows } from "@/lib/ammo"
import { clampMenuPosition, contextMenuEntries, type MenuEntry } from "@/lib/contextMenu"
import { useLocale } from "@/lib/locales"
import type { InventoryItem, InventoryView } from "@/lib/types"

export interface MenuTarget { x: number; y: number; inventory: InventoryView; item: InventoryItem }

interface ItemContextMenuProps {
    target: MenuTarget
    playerId: string
    giveAvailable: boolean
    busy: boolean
    onClose: () => void
    onUse: (inventory: InventoryView, item: InventoryItem) => void
    onOpenBag: (inventory: InventoryView, item: InventoryItem) => void
    onSplit: (inventory: InventoryView, item: InventoryItem) => void
    onDrop: (inventory: InventoryView, item: InventoryItem) => void
    onGive: (inventory: InventoryView, item: InventoryItem) => void
    onCopy: (inventory: InventoryView, item: InventoryItem) => void
}

/**
 * The `rightClick = "menu"` context menu: a small popover at the cursor with
 * only the actions that apply to the item. It is a portal (like the drag
 * preview) so the NUI root's scale transform does not offset the cursor
 * coordinates. Escape and outside clicks close it; the session hook also drops
 * it on every server patch so it can never act on a stack that changed.
 */
export function ItemContextMenu({ target, playerId, giveAvailable, busy, onClose, onUse, onOpenBag, onSplit, onDrop, onGive, onCopy }: ItemContextMenuProps) {
    const t = useLocale()
    const { inspectorCopy, ammoInfo } = useContext(UiConfigContext)
    const { inventory, item } = target
    const ref = useRef<HTMLDivElement>(null)
    const [view, setView] = useState<"menu" | "ammo">("menu")
    const [position, setPosition] = useState({ x: target.x, y: target.y })
    const entries = useMemo(() => contextMenuEntries({ inventory, item, playerId, giveAvailable, inspectorCopy, ammoInfo }), [ammoInfo, giveAvailable, inspectorCopy, inventory, item, playerId])
    const rows = useMemo(() => ammoInfoRows(item, ammoInfo, t), [ammoInfo, item, t])

    // Measured after render so the real size is known: pull it back inside the window.
    useLayoutEffect(() => {
        const box = ref.current?.getBoundingClientRect()
        if (!box) return
        setPosition(clampMenuPosition({ x: target.x, y: target.y }, { width: box.width, height: box.height }, { width: window.innerWidth, height: window.innerHeight }))
    }, [target.x, target.y, view])

    useEffect(() => {
        const outside = (event: Event) => { if (!ref.current?.contains(event.target as Node)) onClose() }
        const key = (event: KeyboardEvent) => { if (event.key === "Escape") { event.stopPropagation(); onClose() } }
        // Capture phase: the slot under the cursor must not swallow the click that dismisses the menu.
        window.addEventListener("mousedown", outside, true)
        window.addEventListener("keydown", key, true)
        window.addEventListener("blur", onClose)
        return () => {
            window.removeEventListener("mousedown", outside, true)
            window.removeEventListener("keydown", key, true)
            window.removeEventListener("blur", onClose)
        }
    }, [onClose])

    const run = (entry: MenuEntry) => {
        if (entry === "ammo") { setView("ammo"); return }
        onClose()
        if (entry === "use") onUse(inventory, item)
        else if (entry === "open") onOpenBag(inventory, item)
        else if (entry === "split") onSplit(inventory, item)
        else if (entry === "drop") onDrop(inventory, item)
        else if (entry === "give") onGive(inventory, item)
        else onCopy(inventory, item)
    }
    const labels: Record<MenuEntry, string> = {
        use: t("ui.menu_use"), open: t("ui.open_bag"), split: t("ui.menu_split"), drop: t("ui.menu_drop"),
        give: t("ui.menu_give"), ammo: t("ui.menu_ammo_info"), copy: t("ui.menu_copy"),
    }
    if (entries.length === 0) return null

    return createPortal(<div
        ref={ref}
        className="item-menu"
        role="menu"
        aria-label={t("ui.item_menu")}
        style={{ left: position.x, top: position.y }}
        onContextMenu={(event) => event.preventDefault()}
    >
        <header className="item-menu-title">{item.label ?? item.name}</header>
        {view === "ammo"
            ? <dl className="item-menu-ammo" aria-label={t("ui.ammo_info")}>{rows.map((row) => <div key={row.key}><dt>{row.label}</dt><dd>{row.value}</dd></div>)}</dl>
            : entries.map((entry) => <button key={entry} type="button" role="menuitem" className="item-menu-entry" data-menu-entry={entry} disabled={busy && entry !== "ammo" && entry !== "copy"} onClick={() => run(entry)}>{labels[entry]}</button>)}
    </div>, document.body)
}
