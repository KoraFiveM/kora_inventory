import type { AuditFilter, AuditResult, IntentPayload, IntentResponse } from "./types"

declare global {
    interface Window {
        GetParentResourceName?: () => string
        invokeNative?: (...args: unknown[]) => unknown
    }
}

const browser = typeof window.invokeNative !== "function"

function resourceName() {
    return window.GetParentResourceName?.() ?? "kora_inventory"
}

/** The sole browser-to-Lua transport. Inventory state never bypasses this UI. */
export async function sendIntent(intent: IntentPayload): Promise<IntentResponse> {
    if (browser) return { ok: true }

    const response = await fetch(`https://${resourceName()}/kora_inventory:nui:intent`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(intent),
    })
    return response.json() as Promise<IntentResponse>
}

export async function closeSession(sessionId: string, token: string) {
    if (browser) return
    await fetch(`https://${resourceName()}/kora_inventory:nui:close`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify({ sessionId, token }),
    })
}

/**
 * Pins (or, with `slot: null`, unpins) a quick slot to a real player slot. A
 * local display preference answered by the Lua client; nothing reaches the
 * server. Never throws: a failed request is reported as `{ ok: false }`.
 */
export async function pinQuickSlot(id: string, slot: number | null): Promise<{ ok: boolean; error?: string }> {
    if (browser) return { ok: true }
    try {
        const response = await fetch(`https://${resourceName()}/kora_inventory:pinQuickSlot`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify({ id, slot }),
        })
        const result = await response.json() as { ok?: boolean; error?: string } | null
        return { ok: result?.ok === true, error: typeof result?.error === "string" ? result.error : undefined }
    } catch {
        return { ok: false }
    }
}

/**
 * Asks the server for a page of the item-creation audit log through the Lua
 * bridge. Read-only; the server re-checks the admin permission on every call.
 * Never throws: a failure is reported as `{ error }`.
 */
export async function queryAudit(filter: AuditFilter): Promise<AuditResult> {
    if (browser) return { rows: [], hasMore: false, page: filter.page, pageSize: 100 }
    try {
        const response = await fetch(`https://${resourceName()}/kora_inventory:audit:query`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify(filter),
        })
        const result = await response.json() as Partial<AuditResult> | null
        if (!result || typeof result !== "object") return { rows: [], hasMore: false, page: filter.page, pageSize: 100, error: "request failed" }
        return { rows: [], hasMore: false, page: filter.page, pageSize: 100, ...result }
    } catch {
        return { rows: [], hasMore: false, page: filter.page, pageSize: 100, error: "request failed" }
    }
}

export async function closeAudit() {
    if (browser) return
    await fetch(`https://${resourceName()}/kora_inventory:audit:close`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: "{}",
    })
}

/**
 * Shows or hides GTA's native instructional buttons (the controls overlay).
 * Client-local presentation answered by the Lua client; nothing reaches the
 * server. Never throws: a failed request is reported as `{ ok: false }`.
 */
export async function setControls(show: boolean): Promise<{ ok: boolean }> {
    if (browser) return { ok: true }
    try {
        const response = await fetch(`https://${resourceName()}/kora_inventory:controls`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify({ show }),
        })
        const result = await response.json() as { ok?: boolean } | null
        return { ok: result?.ok === true }
    } catch {
        return { ok: false }
    }
}
