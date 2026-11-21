import { useLayoutEffect, useEffect, useRef, useState } from "react"
import { useNuiEvent } from "@/lib/useNuiEvent"
import { DEFAULT_PLAYER_LAYOUT, drawerPlacement, layoutOffsetPx, normalizePlayerLayout, onScreenNudge, type PlayerLayout } from "@/lib/playerLayout"

/** Same factor main.tsx scales the root by. */
function rootScale() {
    return Math.min(2, Math.max(0.5, Math.min(window.innerWidth / 1920, window.innerHeight / 1080)))
}

/**
 * The player's window placement from kora_hud's /ui editor (relayed by
 * client/ui.lua as `kora_inventory:nui:layout`): position, scale, side and
 * layout choice, plus the shell ref/style that apply it and keep it on screen.
 */
export function useShellLayout({ transferView }: { transferView: boolean }) {
    // Per-player position/size/side from kora_hud's /ui editor (client/ui.lua
    // relays it). Defaults render exactly the shipped layout.
    const [playerLayout, setPlayerLayout] = useState<PlayerLayout>(DEFAULT_PLAYER_LAYOUT)
    useNuiEvent<unknown>("kora_inventory:nui:layout", (raw) => setPlayerLayout(normalizePlayerLayout(raw)))
    const [viewport, setViewport] = useState({ width: window.innerWidth, height: window.innerHeight })
    useEffect(() => {
        const onResize = () => setViewport({ width: window.innerWidth, height: window.innerHeight })
        window.addEventListener("resize", onResize)
        return () => window.removeEventListener("resize", onResize)
    }, [])
    const shellRef = useRef<HTMLElement>(null)
    const [nudge, setNudge] = useState({ x: 0, y: 0 })
    const offsetPx = layoutOffsetPx(playerLayout, transferView, { width: viewport.width / rootScale(), height: viewport.height / rootScale() })
    const [drawerFlip, setDrawerFlip] = useState(false)
    // Keep the window, and the quick-slot drawer hanging on its edge, on screen
    // after a resolution/aspect change or a large scale: measured after every
    // render (it only sets state when something changed), never persisted. The
    // drawer sits on its preferred edge unless that edge is off screen and the
    // other has room; either way its (expanded) width counts as part of the window.
    useLayoutEffect(() => {
        const shell = shellRef.current
        if (!shell) return
        let rect: { left: number; top: number; width: number; height: number } = shell.getBoundingClientRect()
        let flip = false
        const drawer = shell.querySelector<HTMLElement>(".quickslot-drawer")
        const handle = drawer?.querySelector<HTMLElement>(".quickslot-drawer-handle")
        const bar = drawer?.querySelector<HTMLElement>(".quickslot-bar-drawer")
        if (drawer && handle && bar && shell.offsetWidth > 0) {
            // Layout px -> viewport px (layout scale times the root scale).
            const factor = rect.width / shell.offsetWidth
            const placement = drawerPlacement(rect, nudge, (handle.offsetWidth + bar.offsetWidth + 1) * factor, drawer.dataset.preferredSide === "right" ? "right" : "left", viewport, rootScale())
            rect = placement.rect
            flip = placement.flipped
        }
        if (flip !== drawerFlip) setDrawerFlip(flip)
        const next = onScreenNudge(rect, nudge, viewport, rootScale())
        if (Math.abs(next.x - nudge.x) > 0.5 || Math.abs(next.y - nudge.y) > 0.5) setNudge(next)
    })
    const shellStyle = {
        "--layout-x": `${offsetPx.x + nudge.x}px`,
        "--layout-y": `${offsetPx.y + nudge.y}px`,
        "--layout-scale": String(playerLayout.scale),
    } as React.CSSProperties
    return { playerLayout, shellRef, shellStyle, offsetPx, drawerFlip }
}
