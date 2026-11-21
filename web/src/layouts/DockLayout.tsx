import { useEffect, useState } from "react"
import { useDrop } from "react-dnd"
import { SLOT_DRAG_TYPE } from "@/components/dnd"
import { asSlots } from "@/lib/inventory"
import { useLocale } from "@/lib/locales"
import type { LayoutProps } from "./types"

type DockTabId = "pockets" | "secondary"

/** Pointer must rest on a tab this long mid-drag before it switches. */
export const DOCK_TAB_HOVER_MS = 180

function DockTab({ id, active, label, badge, badgeTitle, onSelect }: {
    id: DockTabId
    active: boolean
    label: string
    badge?: number
    badgeTitle?: string
    onSelect: (tab: DockTabId) => void
}) {
    // Never a drop target for items (canDrop false): hovering only switches the
    // tab so the item can then be dropped on a slot of the other panel.
    const [{ over }, drop] = useDrop(() => ({
        accept: SLOT_DRAG_TYPE,
        canDrop: () => false,
        collect: (monitor) => ({ over: monitor.isOver() }),
    }), [])
    useEffect(() => {
        if (!over || active) return
        const timer = setTimeout(() => onSelect(id), DOCK_TAB_HOVER_MS)
        return () => clearTimeout(timer)
    }, [over, active, id, onSelect])
    return <button
        ref={(node) => { drop(node) }}
        type="button"
        role="tab"
        id={`dock-tab-${id}`}
        aria-selected={active}
        aria-controls={`dock-pane-${id}`}
        className={`dock-tab${active ? " dock-tab-active" : ""}${over && !active ? " dock-tab-hover" : ""}`}
        onClick={() => onSelect(id)}
    >
        <span className="dock-tab-label">{label}</span>
        {badge !== undefined && <b className="dock-tab-badge" title={badgeTitle}>{badge}</b>}
    </button>
}

/**
 * Full-height panel docked to a screen edge. Pockets and the secondary
 * inventory are tabs of one panel (both stay mounted so a drag started in one
 * survives the switch to the other); the inspector slides up over the bottom.
 * The quick-slot drawer hangs on the inner edge, the one facing the screen centre.
 */
export function DockLayout({ layoutId, session, playerLayout, shellRef, shellStyle, dragPreview, topbar, playerPanel, drawerInspector, secondaryPanel, secondaryView, transferView, shortcutBar, renderQuickSlots }: LayoutProps) {
    const t = useLocale()
    const derived = session.secondary ? { kind: "inventory" as const, label: session.secondary.label ?? session.secondary.id, count: asSlots(session.secondary.items).length } : undefined
    const secondary = transferView ? (secondaryView ?? derived) : undefined
    // The choice belongs to one session: a new session starts on pockets.
    const [choice, setChoice] = useState<{ session: string; tab: DockTabId }>({ session: session.sessionId, tab: "pockets" })
    const tab: DockTabId = secondary && choice.session === session.sessionId ? choice.tab : "pockets"
    const select = (next: DockTabId) => setChoice((current) => current.session === session.sessionId && current.tab === next ? current : { session: session.sessionId, tab: next })
    const right = playerLayout.playerSide === "right"
    const count = secondary?.count ?? 0
    return <main ref={shellRef} style={shellStyle} data-layout={layoutId} className={`inventory-shell ${right ? "dock-right" : "dock-left"}`}>
        {dragPreview}
        {topbar}
        <div className="dock-tabs" role="tablist" aria-label={t("ui.dock_tabs")}>
            <DockTab id="pockets" active={tab === "pockets"} label={t("ui.dock_tab_pockets")} onSelect={select} />
            {secondary && <DockTab id="secondary" active={tab === "secondary"} label={secondary.label} badge={count} badgeTitle={t("ui.dock_tab_items", { count })} onSelect={select} />}
        </div>
        <div className="dock-body">
            <section id="dock-pane-pockets" role="tabpanel" aria-labelledby="dock-tab-pockets" className={`dock-pane${tab === "pockets" ? "" : " dock-pane-hidden"}`}>{playerPanel}</section>
            {secondary && <section id="dock-pane-secondary" role="tabpanel" aria-labelledby="dock-tab-secondary" className={`dock-pane${tab === "secondary" ? "" : " dock-pane-hidden"}`}>{secondaryPanel}</section>}
            {drawerInspector && <div className="dock-inspector">{drawerInspector}</div>}
        </div>
        {shortcutBar}
        {renderQuickSlots("drawer", { side: right ? "left" : "right" })}
    </main>
}
