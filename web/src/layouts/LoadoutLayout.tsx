import type { LayoutProps } from "./types"

/**
 * Character-loadout window: pockets | centre column | secondary. The centre
 * column is the Loadout panel (the quick slots as rich rows) with the inspector
 * under it, filling what is left. It does not use the side drawer: the panel
 * replaces it. Solo view is pockets + the centre column, and the column only
 * takes room while it has something to show (quick slots or a selected item);
 * the window shrink-wraps what is there, no empty frame area.
 */
export function LoadoutLayout({ layoutId, solo, drawerLeft, playerLayout, shellRef, shellStyle, dragPreview, topbar, playerPanel, inspector, secondaryPanel, shortcutBar, renderQuickSlots }: LayoutProps) {
    const player = <section key="player" className="inventory-stage inventory-stage-player">{playerPanel}</section>
    // Nothing but the panel and the inspector in here, so a column with neither is an :empty box that layouts.css hides.
    const centre = <div key="centre" className="loadout-centre">{renderQuickSlots("panel")}{inspector}</div>
    const secondary = secondaryPanel ? <section key="secondary" className="inventory-stage inventory-stage-secondary">{secondaryPanel}</section> : null
    // Solo: the centre column opens on the side away from the screen edge the
    // window was moved towards (drawerLeft). Transfer: /ui "personal side".
    const mirrored = solo ? drawerLeft : playerLayout.playerSide === "right"
    const columns = solo ? [player, centre] : [player, centre, secondary]
    if (mirrored) columns.reverse()
    return <main ref={shellRef} style={shellStyle} data-layout={layoutId} className={`inventory-shell${solo ? " inventory-shell-solo" : ""}${solo && drawerLeft ? " inventory-shell-drawer-left" : ""}`}>
        {dragPreview}
        {topbar}
        <div className={`loadout-main${solo ? " loadout-main-solo" : ""}`}>{columns}</div>
        {shortcutBar}
    </main>
}
