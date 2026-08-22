import type { IntentPayload } from "./types"

declare global {
    interface Window {
        GetParentResourceName?: () => string
        invokeNative?: (...args: unknown[]) => unknown
    }
}

const browser = typeof window.invokeNative !== "function"

function resourceName() {
    return window.GetParentResourceName?.() ?? "qbinventory"
}

/** The sole browser-to-Lua transport. Inventory state never bypasses this UI. */
export async function sendIntent(intent: IntentPayload) {
    if (browser) return { ok: true }

    const response = await fetch(`https://${resourceName()}/qbinventory:nui:intent`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify(intent),
    })
    return response.json() as Promise<{ ok: boolean; error?: string }>
}

export async function closeSession(sessionId: string, token: string) {
    if (browser) return
    await fetch(`https://${resourceName()}/qbinventory:nui:close`, {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=UTF-8" },
        body: JSON.stringify({ sessionId, token }),
    })
}
