import type { CSSProperties, ReactNode, RefObject } from "react"
import type { ResolvedUiConfig } from "@/context"
import type { DragSlot, Selection, SlotTarget } from "@/lib/inventory"
import type { LayoutId } from "@/lib/layoutIds"
import type { PlayerLayout } from "@/lib/playerLayout"
import type { InventoryItem, InventoryView, SessionSnapshot } from "@/lib/types"

export type { LayoutId }

/** Where a layout wants the quick-slot (hotbar) bar relative to the player panel. */
export type QuickSlotPosition = "side" | "top" | "bottom"

/**
 * Everything a layout receives from InventoryApp.
 *
 * A layout is presentation only: it arranges the pre-built nodes (or builds its
 * own from the same components and handlers) inside the `<main>` shell. It must
 * not hold session state, talk to the server or the NUI bridge itself.
 */
export interface LayoutProps {
    /** Which registry entry is being rendered; becomes `data-layout` on the shell. */
    layoutId: LayoutId

    // --- state ---
    session: SessionSnapshot
    selected: Selection | undefined
    /** `selected` filtered through the search box; what the inspector shows. */
    inspected: Selection | undefined
    /** No second inventory open and `centreWhenSolo` is on: compact personal view. */
    solo: boolean
    /** A second inventory (stash, trunk, shop...) is open. */
    transferView: boolean
    /** The player's /ui editor placement (side, scale, offsets). */
    playerLayout: PlayerLayout
    /** Solo drawer opens on the left because the window was moved to the right. */
    drawerLeft: boolean
    /** Locked behind an unanswered request (only without instant, queued moves). */
    busy: boolean
    /** A request is in flight. */
    movePending: boolean
    /** Config flags and values already merged onto the defaults. */
    uiConfig: ResolvedUiConfig

    // --- shell ---
    /** Attach to the `<main>` element: the on-screen nudge measures it. */
    shellRef: RefObject<HTMLElement>
    /** `--layout-x/-y/-scale` custom properties from the player's placement. */
    shellStyle: CSSProperties

    // --- handlers (for layouts that build their own panels) ---
    canDropSlot: (source: DragSlot, target: SlotTarget) => boolean
    onDrop: (source: DragSlot, target: SlotTarget) => void
    onDragEnd: () => void
    onSelect: (inventory: InventoryView, item: InventoryItem | undefined, slot: number) => void
    onActivate: (inventory: InventoryView, item: InventoryItem) => void
    onSplit: (inventory: InventoryView, item: InventoryItem) => void
    onClose: () => void
    onClearSelection: () => void

    // --- pre-built nodes ---
    /** Brand, search box, session state and close button, plus the refusal notice. */
    topbar: ReactNode
    /** The player's own inventory panel. */
    playerPanel: ReactNode
    /** The open secondary inventory panel, or the empty placeholder panel; null in solo view. */
    secondaryPanel: ReactNode
    /** The item inspector `aside`, or null when it is not mounted (solo view, nothing selected). */
    inspector: ReactNode
    /**
     * The inspector in its drawer form (close button included), whatever the
     * view, or null while nothing is selected. For layouts that float or slide
     * the inspector in only on demand instead of reserving a column for it.
     */
    drawerInspector: ReactNode
    /** Esc / Enter / Drag hints and the revision. */
    shortcutBar: ReactNode
    /** Builds the quick-slot bar for a position; layouts choose where it goes. */
    renderQuickSlots: (position: QuickSlotPosition) => ReactNode
    /** The floating drag preview; mount it inside the shell. */
    dragPreview: ReactNode
}
