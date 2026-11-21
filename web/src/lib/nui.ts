import type { IntentPayload, IntentResponse } from "./types"

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
