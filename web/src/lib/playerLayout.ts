/**
 * Per-player window layout from kora_hud's /ui editor, relayed by
 * client/ui.lua as `qbinventory:nui:layout`. Offsets are viewport fractions
 * (resolution independent); scale grows the window from its centre.
 */
export interface PlayerLayout {
    x: number
    y: number
    scale: number
    /** Personal inventory column in the transfer (stash/trunk) view. */
    playerSide: "left" | "right"
    /** Apply the offset to the transfer view too, not only the personal one. */
    useForTransfer: boolean
}

export const DEFAULT_PLAYER_LAYOUT: PlayerLayout = { x: 0, y: 0, scale: 1, playerSide: "left", useForTransfer: false }

function clamp(value: unknown, min: number, max: number, fallback: number): number {
    return typeof value === "number" && Number.isFinite(value) ? Math.max(min, Math.min(max, value)) : fallback
}

/** Re-validated in the page as well: nothing invalid may reach CSS. */
export function normalizePlayerLayout(raw: unknown): PlayerLayout {
    if (!raw || typeof raw !== "object") return DEFAULT_PLAYER_LAYOUT
    const value = raw as Record<string, unknown>
    return {
        x: clamp(value.x, -1, 1, 0),
        y: clamp(value.y, -1, 1, 0),
        scale: clamp(value.scale, 0.75, 1.25, 1),
        playerSide: value.playerSide === "right" ? "right" : "left",
        useForTransfer: value.useForTransfer === true,
    }
}

/**
 * The offset in root pixels for this view: the transfer view stays centred
 * (the default two-panel layout) unless the player chose otherwise.
 */
export function layoutOffsetPx(layout: PlayerLayout, transfer: boolean, root: { width: number; height: number }) {
    if (transfer && !layout.useForTransfer) return { x: 0, y: 0 }
    return { x: layout.x * root.width, y: layout.y * root.height }
}

/**
 * How far (root pixels) a box must move to be fully on screen. `current` is
 * the nudge already applied; `scale` converts screen to root pixels.
 */
export function onScreenNudge(
    rect: { left: number; top: number; width: number; height: number },
    current: { x: number; y: number },
    viewport: { width: number; height: number },
    scale: number,
) {
    const left = rect.left - current.x * scale
    const top = rect.top - current.y * scale
    const fix = (start: number, size: number, limit: number) => {
        if (size >= limit || start < 0) return -start
        if (start + size > limit) return limit - (start + size)
        return 0
    }
    return { x: fix(left, rect.width, viewport.width) / scale, y: fix(top, rect.height, viewport.height) / scale }
}
