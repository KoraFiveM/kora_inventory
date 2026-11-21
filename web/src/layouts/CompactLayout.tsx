import type { LayoutProps } from "./types"

/**
 * Narrow single-column window: top bar, the player
 * grid, and (transfer view) the secondary under it behind a divider. The
 * inspector is a popover beside the window, not a column, and the quick slots
 * are a drawer on the opposite edge.
 */
export function CompactLayout({ layoutId, drawerLeft, playerLayout, shellRef, shellStyle, dragPreview, topbar, playerPanel, drawerInspector, secondaryPanel, shortcutBar, renderQuickSlots }: LayoutProps) {
    const popLeft = drawerLeft || playerLayout.playerSide === "right"
    return <main ref={shellRef} style={shellStyle} data-layout={layoutId} className={`inventory-shell ${secondaryPanel ? "layout-transfer" : "layout-solo"}`}>
        {dragPreview}
        {topbar}
        <div className="compact-stack">
            <section className="compact-pane compact-pane-player">{playerPanel}</section>
            {secondaryPanel && <>
                <div className="compact-divider" role="separator" />
                <section className="compact-pane compact-pane-secondary">{secondaryPanel}</section>
            </>}
        </div>
        {drawerInspector && <div className={`compact-popover${popLeft ? " compact-popover-left" : ""}`}>{drawerInspector}</div>}
        {shortcutBar}
        {renderQuickSlots("drawer", { side: popLeft ? "right" : "left" })}
    </main>
}
