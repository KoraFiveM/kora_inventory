import type { LayoutProps } from "./types"

/**
 * The original window: topbar, player panel | inspector | secondary panel,
 * shortcut bar, with the quick slots as a drawer on the window's edge. The
 * drawer goes on the personal side; in solo view the inspector slides out on
 * the opposite edge, so the drawer takes the other one when that edge is the
 * left.
 */
export function ClassicLayout({ layoutId, solo, drawerLeft, playerLayout, shellRef, shellStyle, dragPreview, topbar, playerPanel, inspector, secondaryPanel, shortcutBar, renderQuickSlots }: LayoutProps) {
    const side = (solo ? drawerLeft : playerLayout.playerSide === "right") ? "right" : "left"
    return <main ref={shellRef} style={shellStyle} data-layout={layoutId} className={`inventory-shell${solo ? " inventory-shell-solo" : ""}${solo && drawerLeft ? " inventory-shell-drawer-left" : ""}`}>
        {dragPreview}
        {topbar}
        <div className={`inventory-layout${solo ? " inventory-layout-solo" : ""}${!solo && playerLayout.playerSide === "right" ? " inventory-layout-swapped" : ""}`}>
            <section className="inventory-stage inventory-stage-player">{playerPanel}</section>
            {inspector}
            {secondaryPanel && <section className="inventory-stage inventory-stage-secondary">{secondaryPanel}</section>}
        </div>
        {shortcutBar}
        {renderQuickSlots("drawer", { side })}
    </main>
}
