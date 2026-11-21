import type { ReactNode } from "react"

/**
 * Wraps a layout's quick-slot strip. Renders nothing at all when the layout
 * got nothing back (null/false), and the wrapper itself has no frame, padding
 * or margin: a strip whose component renders no DOM leaves an `:empty` wrapper,
 * which layouts.css hides, so no empty box is ever painted.
 */
export function QuickSlots({ children, className }: { children: ReactNode; className?: string }) {
    if (children === null || children === undefined || children === false) return null
    return <div className={`layout-quick${className ? ` ${className}` : ""}`}>{children}</div>
}
