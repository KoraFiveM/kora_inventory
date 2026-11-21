import type { AuditFilter, AuditRange, AuditRow, InventoryItem } from "./types"

export const AUDIT_RANGES: AuditRange[] = ["1h", "24h", "7d"]
export const AUDIT_PAGE_SIZE = 100

export function emptyAuditFilter(initial?: Partial<AuditFilter>): AuditFilter {
    const range = AUDIT_RANGES.includes(initial?.range as AuditRange) ? (initial!.range as AuditRange) : "24h"
    return {
        player: typeof initial?.player === "string" ? initial.player : "",
        item: typeof initial?.item === "string" ? initial.item : "",
        resource: typeof initial?.resource === "string" ? initial.resource : "",
        range,
        page: 0,
    }
}

/** "14:03:22" for today, "21 Nov 14:03" for older entries. `at` is unix seconds. */
export function formatAuditTime(at: number, now = Date.now()): string {
    const date = new Date(at * 1000)
    if (Number.isNaN(date.getTime())) return ""
    const pad = (value: number) => String(value).padStart(2, "0")
    const clock = `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`
    const today = new Date(now)
    if (date.toDateString() === today.toDateString()) return clock
    return `${date.getDate()} ${date.toLocaleString("en", { month: "short" })} ${pad(date.getHours())}:${pad(date.getMinutes())}`
}

/** Citizen id and server id together, whichever the row has. */
export function auditPlayer(row: AuditRow): string {
    if (row.citizenid && row.source !== undefined && row.source !== null) return `${row.citizenid} (#${row.source})`
    if (row.citizenid) return row.citizenid
    if (row.source !== undefined && row.source !== null) return `#${row.source}`
    return "—"
}

export interface OmnipackSlice {
    shown: InventoryItem[]
    /** Items matching the search, before the page limit. */
    total: number
    /** Matches not yet shown. */
    remaining: number
}

/**
 * The omnipack lists every registered item (~1000). The panel searches the
 * whole list, then draws only `limit` of the matches, so the grid stays small
 * and every drawn slot keeps its real server slot number.
 */
export function sliceOmnipack(items: InventoryItem[], query: string, limit: number): OmnipackSlice {
    const needle = query.trim().toLowerCase()
    const matches = needle
        ? items.filter((item) => item.name.toLowerCase().includes(needle) || (item.label ?? "").toLowerCase().includes(needle))
        : items
    const shown = matches.slice(0, Math.max(0, limit))
    return { shown, total: matches.length, remaining: matches.length - shown.length }
}
