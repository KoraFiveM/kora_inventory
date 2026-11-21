import { useLayoutEffect, useEffect, useRef, useState } from "react"
import { useNuiEvent } from "@/lib/useNuiEvent"
import { DEFAULT_PLAYER_LAYOUT, layoutOffsetPx, normalizePlayerLayout, onScreenNudge, type PlayerLayout } from "@/lib/playerLayout"

/** Same factor main.tsx scales the root by. */
function rootScale() {
    return Math.min(2, Math.max(0.5, Math.min(window.innerWidth / 1920, window.innerHeight / 1080)))
}

/**
 * The player's window placement from kora_hud's /ui editor (relayed by
 * client/ui.lua as `kora_inventory:nui:layout`): position, scale, side and
 * layout choice, plus the shell ref/style that apply it and keep it on screen.
 */
export function useShellLayout({ hasSession, transferView }: { hasSession: boolean; transferView: boolean }) {
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
    // Keep the window on screen after a resolution/aspect change or a large
    // scale: measured once per layout/resize/view change, never persisted.
    useLayoutEffect(() => {
        const shell = shellRef.current
        if (!shell) return
        const next = onScreenNudge(shell.getBoundingClientRect(), nudge, viewport, rootScale())
        if (Math.abs(next.x - nudge.x) > 0.5 || Math.abs(next.y - nudge.y) > 0.5) setNudge(next)
    }, [nudge, offsetPx.x, offsetPx.y, playerLayout.scale, transferView, viewport, hasSession])
    const shellStyle = {
        "--layout-x": `${offsetPx.x + nudge.x}px`,
        "--layout-y": `${offsetPx.y + nudge.y}px`,
        "--layout-scale": String(playerLayout.scale),
    } as React.CSSProperties
    return { playerLayout, shellRef, shellStyle, offsetPx }
}
