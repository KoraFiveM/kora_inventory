import type { InventoryItem, InventoryView } from "./types"

/**
 * Item inspector "Copy" (Config.Inspector.allowCopy): the selected item as
 * pretty JSON, for bug reports and development. `info` is the qb-style
 * metadata table, `metadata` the ox-style one; whichever the item carries is
 * copied as `metadata`. Only what the NUI was already sent is included.
 */
export function itemCopyText(inventory: Pick<InventoryView, "id" | "type">, item: InventoryItem): string {
    const metadata = item.info ?? item.metadata ?? {}
    return JSON.stringify({
        label: item.label ?? item.name,
        name: item.name,
        amount: item.amount,
        slot: item.slot,
        inventory: inventory.id,
        ...(inventory.type ? { inventoryType: inventory.type } : {}),
        ...(item.weight !== undefined ? { weight: item.weight } : {}),
        ...(item.price !== undefined ? { price: item.price } : {}),
        metadata,
    }, null, 2)
}

/**
 * Copies text from inside FiveM's NUI. CEF often has no usable
 * `navigator.clipboard` there (missing, or it rejects for want of a permission),
 * so the synchronous hidden-textarea + `execCommand("copy")` path runs first,
 * while the click's user activation is still live; the async API is only the
 * fallback. Focus goes back to whatever had it.
 */
export async function copyText(text: string, doc: Document = document): Promise<boolean> {
    const previous = doc.activeElement as HTMLElement | null
    const area = doc.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.setAttribute("aria-hidden", "true")
    // The UI disables selection on everything else (styles.css); the copy
    // source must stay selectable or execCommand copies nothing.
    area.style.cssText = "position:fixed;top:0;left:-9999px;width:1px;height:1px;opacity:0;-webkit-user-select:text;user-select:text;"
    doc.body.appendChild(area)
    let copied = false
    try {
        area.focus()
        area.select()
        area.setSelectionRange(0, text.length)
        copied = typeof doc.execCommand === "function" && doc.execCommand("copy") === true
    } catch {
        copied = false
    } finally {
        area.remove()
        previous?.focus?.()
    }
    if (copied) return true
    const clipboard = doc.defaultView?.navigator?.clipboard
    if (!clipboard || typeof clipboard.writeText !== "function") return false
    try {
        await clipboard.writeText(text)
        return true
    } catch {
        return false
    }
}
