// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { DndProvider } from "react-dnd"
import { TouchBackend } from "react-dnd-touch-backend"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { queryAudit, closeAudit } = vi.hoisted(() => ({
    queryAudit: vi.fn(async (..._args: unknown[]) => ({
        rows: [{ at: 1700000000, action: "add", citizenid: "ABC123", source: 7, item: "bread", amount: 3, inventory: "player:7", resource: "kora_drugs", reason: "harvest" }],
        hasMore: true, page: 0, pageSize: 100,
        summary: { resources: [{ name: "kora_drugs", amount: 3, count: 1 }], items: [{ name: "bread", amount: 3, count: 1 }] },
    })),
    closeAudit: vi.fn(async () => undefined),
}))
vi.mock("@/lib/nui", () => ({ queryAudit, closeAudit, sendIntent: vi.fn(), closeSession: vi.fn(), pinQuickSlot: vi.fn() }))

import { AuditViewer } from "./AuditViewer"
import { InventoryPanel } from "./InventoryPanel"
import type { InventoryView } from "@/lib/types"

const omnipack: InventoryView = {
    id: "shop:omnipack", label: "Omnipack", type: "shop", omnipack: true, slots: 300, weight: 0, maxWeight: 1e15,
    items: Array.from({ length: 300 }, (_, index) => ({ slot: index + 1, name: index === 250 ? "weapon_pistol" : `item_${index + 1}`, label: index === 250 ? "Pistol" : `Item ${index + 1}`, amount: 100, price: 0, weight: 1 })),
}

let host: HTMLDivElement
let root: Root
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); queryAudit.mockClear(); closeAudit.mockClear() })
afterEach(() => { act(() => root.unmount()); host.remove() })

const noop = () => undefined
function renderPanel() {
    act(() => root.render(<DndProvider backend={TouchBackend} options={{ enableMouseEvents: true }}>
        <InventoryPanel inventory={omnipack} busy={false} canDropSlot={() => false} onDrop={noop} onDragEnd={noop} onSelect={noop} onActivate={noop} onSplit={noop} />
    </DndProvider>))
}
function type(input: HTMLInputElement, value: string) {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value")!.set!
    act(() => { setter.call(input, value); input.dispatchEvent(new Event("input", { bubbles: true })) })
}

describe("omnipack panel", () => {
    it("draws one page of the ~1000 item list, not every slot", () => {
        renderPanel()
        expect(host.querySelectorAll(".slot").length).toBe(120)
        expect(host.textContent).toContain("Show more")
    })
    it("searches the whole list, not just the drawn page, and keeps real slot numbers", () => {
        renderPanel()
        type(host.querySelector<HTMLInputElement>(".omnipack-search input")!, "pistol")
        const slots = host.querySelectorAll(".slot")
        expect(slots.length).toBe(1)
        expect(slots[0].getAttribute("aria-label")).toContain("slot 251")
    })
    it("says so when nothing matches and offers more matches in pages", () => {
        renderPanel()
        type(host.querySelector<HTMLInputElement>(".omnipack-search input")!, "zzz")
        expect(host.querySelector(".omnipack-empty")).not.toBeNull()
        type(host.querySelector<HTMLInputElement>(".omnipack-search input")!, "")
        act(() => host.querySelector<HTMLButtonElement>(".omnipack-more")!.click())
        expect(host.querySelectorAll(".slot").length).toBe(240)
    })
    it("hides the weight bar and category chips that mean nothing for a catalogue", () => {
        renderPanel()
        expect(host.querySelector(".weight")).toBeNull()
        expect(host.querySelector(".category-chips")).toBeNull()
    })
})

describe("audit viewer", () => {
    const send = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    it("renders nothing until the server opens it", () => {
        act(() => root.render(<AuditViewer />))
        expect(host.querySelector(".audit-overlay")).toBeNull()
    })
    it("opens on the server message, loads the first page, and shows rows and the summary", async () => {
        act(() => root.render(<AuditViewer />))
        send("kora_inventory:nui:auditOpen", { filter: { resource: "kora_drugs", range: "1h" } })
        await act(async () => { await Promise.resolve() })
        expect(queryAudit).toHaveBeenCalledWith(expect.objectContaining({ resource: "kora_drugs", range: "1h", page: 0 }))
        expect(host.querySelectorAll(".audit-table tbody tr").length).toBe(1)
        expect(host.textContent).toContain("ABC123 (#7)")
        expect(host.textContent).toContain("Top scripts, last hour")
        const next = [...host.querySelectorAll<HTMLButtonElement>(".audit-pager button")].find((button) => button.textContent === "Next")!
        expect(next.disabled).toBe(false)
        await act(async () => { next.click(); await Promise.resolve() })
        expect(queryAudit).toHaveBeenLastCalledWith(expect.objectContaining({ page: 1 }))
    })
    it("shows a server refusal and closes through the bridge", async () => {
        queryAudit.mockResolvedValueOnce({ rows: [], hasMore: false, page: 0, pageSize: 100, error: "not authorised" } as never)
        act(() => root.render(<AuditViewer />))
        send("kora_inventory:nui:auditOpen", {})
        await act(async () => { await Promise.resolve() })
        expect(host.querySelector(".audit-error")?.textContent).toContain("not authorised")
        act(() => host.querySelector<HTMLButtonElement>(".audit-close")!.click())
        expect(host.querySelector(".audit-overlay")).toBeNull()
        expect(closeAudit).toHaveBeenCalled()
    })
})
