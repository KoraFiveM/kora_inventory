import type { ComponentType } from "react"
import type { ResolvedUiConfig } from "@/context"
import { isLayoutId, LAYOUT_IDS, type LayoutId } from "@/lib/layoutIds"
import type { PlayerLayout } from "@/lib/playerLayout"
import { ClassicLayout } from "./ClassicLayout"
import type { LayoutProps } from "./types"

export { LAYOUT_IDS, isLayoutId }
export type { LayoutId, LayoutProps }

// TODO: loadout, compact and dock are implemented separately; until they
// exist each one renders the classic markup so every id in the config works.
export const LAYOUTS: Record<LayoutId, ComponentType<LayoutProps>> = {
    classic: ClassicLayout,
    loadout: ClassicLayout,
    compact: ClassicLayout,
    dock: ClassicLayout,
}

/** A missing key counts as allowed: only an explicit `false` hides a layout. */
function allowed(config: Pick<ResolvedUiConfig, "layouts">, id: unknown): id is LayoutId {
    return isLayoutId(id) && config.layouts?.[id] !== false
}

/**
 * The layout to render: the player's choice when choice is on and allowed, else
 * the server default if allowed, else classic. Anything unknown ends up classic.
 */
export function resolveLayout(
    config: Pick<ResolvedUiConfig, "layout" | "layouts" | "playerLayoutChoice">,
    player: Pick<PlayerLayout, "layout"> | undefined,
): LayoutId {
    if (config.playerLayoutChoice !== false && allowed(config, player?.layout)) return player!.layout as LayoutId
    if (allowed(config, config.layout)) return config.layout as LayoutId
    return "classic"
}
