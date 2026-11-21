// @vitest-environment jsdom
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { DndProvider, useDrop } from "react-dnd"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

const { sendIntent, closeSession, pinQuickSlot } = vi.hoisted(() => ({
    sendIntent: vi.fn(async (..._args: unknown[]) => ({ ok: true })),
    closeSession: vi.fn(async (..._args: unknown[]) => undefined),
    pinQuickSlot: vi.fn(async (..._args: unknown[]) => ({ ok: true })),
}))
vi.mock("@/lib/nui", () => ({ sendIntent, closeSession, pinQuickSlot }))

import type { BackendFactory, DragDropManager, Identifier } from "dnd-core"
import App from "../App"
import { SLOT_DRAG_TYPE } from "./dnd"
import { QuickSlotBar, type QuickSlotBarProps } from "./QuickSlotBar"
import { HotbarHud } from "./HotbarHud"
import { normalizeQuickSlots } from "@/lib/quickSlots"
import type { InventoryView } from "@/lib/types"

const player: InventoryView = {
    id: "player:1", label: "Pockets", type: "player", slots: 10, weight: 0, maxWeight: 1000,
    items: [
        { slot: 2, name: "weapon_pistol", label: "Pistol", amount: 1, ammo: { type: "AMMO_PISTOL", item: "pistol_ammo", label: "Pistol Ammo", loaded: 12 } },
        { slot: 3, name: "pistol_ammo", label: "Pistol Ammo", amount: 3, ammoType: "AMMO_PISTOL", rounds: 24, fits: ["Pistol"] },
        { slot: 4, name: "rifle_ammo", label: "Rifle Ammo", amount: 1, ammoType: "AMMO_RIFLE" },
        { slot: 6, name: "bandage", label: "Bandage", amount: 4, useable: true },
    ],
}
const snapshot = { sessionId: "s1", token: "t", revision: 1, player }

// A drag backend that only records what is registered, so tests can run a drag
// through react-dnd's own manager without pointer events.
function fakeBackend() {
    const sources = new Map<Identifier, unknown>()
    const targets = new Map<Identifier, unknown>()
    let manager: DragDropManager | undefined
    const factory: BackendFactory = (m) => {
        manager = m
        return {
            setup() {}, teardown() {},
            connectDragSource(id: Identifier, node?: unknown) { sources.set(id, node); return () => sources.delete(id) },
            connectDragPreview() { return () => undefined },
            connectDropTarget(id: Identifier, node?: unknown) { targets.set(id, node); return () => targets.delete(id) },
            profile: () => ({}),
        }
    }
    const idOf = (map: Map<Identifier, unknown>, node: Element | null) => [...map.entries()].find(([, n]) => n === node)?.[0]
    return {
        factory,
        /** Drag from one element and release over another, through the real manager. */
        drag(from: Element | null, to: Element | null) {
            const sourceId = idOf(sources, from)
            const targetId = idOf(targets, to)
            expect(sourceId).toBeDefined()
            expect(targetId).toBeDefined()
            const actions = manager!.getActions()
            act(() => { actions.beginDrag([sourceId!]) })
            // A busy tile refuses to be dragged at all.
            if (!manager!.getMonitor().isDragging()) return false
            act(() => { actions.hover([targetId!]) })
            act(() => { actions.drop() })
            act(() => { actions.endDrag() })
            return true
        },
    }
}

let root: Root
let host: HTMLElement
beforeEach(() => { host = document.createElement("div"); document.body.appendChild(host); root = createRoot(host); pinQuickSlot.mockClear(); sendIntent.mockClear() })
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks() })

const entries = [
    { id: "weapon", label: "Weapon", slot: 2, name: "weapon_pistol", key: "F5", pinned: true },
    { id: "ammo", label: "Ammo", slot: 3, name: "pistol_ammo", total: 36, linked: true, key: "" },
    { id: "med", label: "Medical", slot: 6, name: "bandage", key: "F6", pinned: false },
    { id: "gone", label: "Missing", slot: null },
]

function mount(props: Partial<QuickSlotBarProps> = {}, backend = fakeBackend()) {
    const handlers = { onSelect: vi.fn(), onActivate: vi.fn(), onPin: vi.fn(), onFlash: vi.fn() }
    const state = props.state ?? normalizeQuickSlots({ enabled: true, slots: entries })
    act(() => {
        root.render(<DndProvider backend={backend.factory}>
            <QuickSlotBar position="side" state={state} player={player} busy={false} {...handlers} {...props} />
        </DndProvider>)
    })
    return { ...handlers, backend }
}
const tile = (id: string) => host.querySelector<HTMLButtonElement>(`[data-quickslot="${id}"]`)!

describe("QuickSlotBar rendering", () => {
    it("shows a tile per resolved quick slot and hides unresolved ones by default", () => {
        mount()
        expect([...host.querySelectorAll("[data-quickslot]")].map((node) => node.getAttribute("data-quickslot"))).toEqual(["weapon", "ammo", "med"])
        expect(host.querySelector(".quickslot-bar-side")).not.toBeNull()
    })

    it("renders nothing at all when every tile is hidden or quick slots are disabled", () => {
        mount({ state: normalizeQuickSlots({ enabled: true, slots: [{ id: "a", label: "A", slot: null }, { id: "b", label: "B", slot: 9, name: "ghost" }] }) })
        expect(host.innerHTML).not.toContain("quickslot")
        mount({ state: normalizeQuickSlots({ enabled: false }) })
        expect(host.querySelector(".quickslot-bar")).toBeNull()
    })

    it("shows greyed placeholder tiles with the label when hideWhenMissing is off", () => {
        mount({ state: normalizeQuickSlots({ enabled: true, hideWhenMissing: false, slots: entries }) })
        const gone = tile("gone")
        expect(gone).not.toBeNull()
        expect(gone.classList.contains("quickslot-empty")).toBe(true)
        expect(gone.textContent).toContain("Missing")
        expect(gone.getAttribute("aria-label")).toBe("Missing: nothing assigned")
    })

    it("shows key hints only when enabled and the key is set", () => {
        mount()
        expect(tile("weapon").querySelector(".quickslot-key")?.textContent).toBe("F5")
        expect(tile("ammo").querySelector(".quickslot-key")).toBeNull()
        mount({ state: normalizeQuickSlots({ enabled: true, showKeyHints: false, slots: entries }) })
        expect(host.querySelector(".quickslot-key")).toBeNull()
    })

    it("shows the ammo total for linked ammo, the stack amount for others, and a pin for pinned tiles", () => {
        mount()
        expect(tile("ammo").querySelector(".quickslot-count")?.textContent).toBe("×36")
        expect(tile("med").querySelector(".quickslot-count")?.textContent).toBe("×4")
        expect(tile("weapon").querySelector(".quickslot-count")).toBeNull()
        expect(tile("weapon").querySelector(".quickslot-pin")).not.toBeNull()
        expect(tile("med").querySelector(".quickslot-pin")).toBeNull()
    })

    it("labels tiles for assistive tech with the real item and slot", () => {
        mount()
        expect(tile("weapon").getAttribute("aria-label")).toBe("Weapon: Pistol, inventory slot 2")
        expect(host.querySelector('[role="group"]')?.getAttribute("aria-label")).toBe("Quick slots")
    })
})

describe("QuickSlotBar drawer", () => {
    const drawer = () => host.querySelector<HTMLElement>(".quickslot-drawer")
    const handle = () => host.querySelector<HTMLButtonElement>(".quickslot-drawer-handle")!
    beforeEach(() => { window.localStorage.clear() })
    afterEach(() => { window.localStorage.clear() })

    it("stacks the tiles in a drawer on the left, expanded, with a labelled handle", () => {
        mount({ position: "drawer" })
        expect(drawer()!.getAttribute("data-side")).toBe("left")
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(false)
        expect(drawer()!.querySelectorAll("[data-quickslot]")).toHaveLength(3)
        expect(handle().getAttribute("aria-expanded")).toBe("true")
        expect(handle().getAttribute("aria-label")).toBe("Collapse quick slots")
        expect(host.querySelector('[role="group"]')?.getAttribute("aria-label")).toBe("Quick slots")
    })

    it("attaches to the right edge when asked, and when the window has no room on its side", () => {
        mount({ position: "drawer", side: "right" })
        expect(drawer()!.getAttribute("data-side")).toBe("right")
        expect(drawer()!.classList.contains("quickslot-drawer-right")).toBe(true)
        mount({ position: "drawer", side: "left", flipped: true })
        expect(drawer()!.getAttribute("data-side")).toBe("right")
        expect(drawer()!.getAttribute("data-preferred-side")).toBe("left")
    })

    it("collapses and expands from the handle and remembers the choice", () => {
        mount({ position: "drawer" })
        act(() => handle().click())
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(true)
        expect(handle().getAttribute("aria-expanded")).toBe("false")
        expect(handle().getAttribute("aria-label")).toBe("Expand quick slots")
        expect(window.localStorage.getItem("kora_inventory:quickDrawerCollapsed")).toBe("1")
        act(() => handle().click())
        expect(handle().getAttribute("aria-expanded")).toBe("true")
        expect(window.localStorage.getItem("kora_inventory:quickDrawerCollapsed")).toBe("0")
    })

    it("starts collapsed with startCollapsed, until the player's stored choice says otherwise", () => {
        const collapsed = normalizeQuickSlots({ enabled: true, drawer: { startCollapsed: true }, slots: entries })
        mount({ position: "drawer", state: collapsed })
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(true)
        act(() => root.unmount()); root = createRoot(host)
        window.localStorage.setItem("kora_inventory:quickDrawerCollapsed", "0")
        mount({ position: "drawer", state: collapsed })
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(false)
        act(() => root.unmount()); root = createRoot(host)
        window.localStorage.setItem("kora_inventory:quickDrawerCollapsed", "1")
        mount({ position: "drawer" })
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(true)
    })

    it("still works when localStorage throws", () => {
        vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => { throw new Error("denied") })
        vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => { throw new Error("denied") })
        mount({ position: "drawer" })
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(false)
        act(() => handle().click())
        expect(drawer()!.classList.contains("quickslot-drawer-collapsed")).toBe(true)
    })

    it("renders nothing at all, no handle and no frame, when there are no tiles", () => {
        mount({ position: "drawer", state: normalizeQuickSlots({ enabled: true, slots: [{ id: "a", label: "A", slot: null }] }) })
        expect(host.innerHTML).toBe("")
        mount({ position: "drawer", state: normalizeQuickSlots({ enabled: false }) })
        expect(host.innerHTML).toBe("")
    })

    it("keeps the tile interactions inside the drawer, even when it is collapsed", () => {
        const { onSelect, onFlash } = mount({ position: "drawer" })
        act(() => tile("med").click())
        expect(onSelect).toHaveBeenCalledWith(player, player.items[3], 6)
        expect(onFlash).toHaveBeenCalledWith(6)
    })
})

describe("QuickSlotBar panel", () => {
    const row = (id: string) => tile(id)
    const figures = (id: string) => [...row(id).querySelectorAll(".quickslot-row-figure")].map((node) => node.textContent)

    it("draws a Loadout panel with one full-width row per quick slot", () => {
        mount({ position: "panel" })
        expect(host.querySelector(".quickslot-panel")?.getAttribute("aria-label")).toBe("Loadout")
        expect(host.querySelector(".quickslot-panel-header h2")?.textContent).toBe("Loadout")
        expect([...host.querySelectorAll(".quickslot-row")].map((node) => node.getAttribute("data-quickslot"))).toEqual(["weapon", "ammo", "med"])
        expect(row("weapon").querySelector(".quickslot-row-eyebrow")?.textContent).toBe("Weapon")
        expect(row("weapon").querySelector(".quickslot-row-name")?.textContent).toBe("Pistol")
        expect(row("weapon").querySelector(".quickslot-art")).not.toBeNull()
    })

    it("shows magazines for linked ammo, rounds loaded for a weapon, and the stack amount otherwise", () => {
        mount({ position: "panel" })
        expect(figures("ammo")).toEqual(["36 mags"])
        expect(figures("weapon")).toEqual(["12 loaded"])
        expect(figures("med")).toEqual(["×4"])
    })

    it("shows the key hint badge only when enabled and bound", () => {
        mount({ position: "panel" })
        expect(row("weapon").querySelector(".quickslot-key")?.textContent).toBe("F5")
        expect(row("ammo").querySelector(".quickslot-key")).toBeNull()
        mount({ position: "panel", state: normalizeQuickSlots({ enabled: true, showKeyHints: false, slots: entries }) })
        expect(host.querySelector(".quickslot-key")).toBeNull()
    })

    it("shows dashed placeholder rows for unresolved slots when hideWhenMissing is off", () => {
        const { onSelect } = mount({ position: "panel", state: normalizeQuickSlots({ enabled: true, hideWhenMissing: false, slots: entries }) })
        const gone = row("gone")
        expect(gone.classList.contains("quickslot-empty")).toBe(true)
        expect(gone.querySelector(".quickslot-row-eyebrow")?.textContent).toBe("Missing")
        expect(gone.querySelector(".quickslot-row-figure")).toBeNull()
        act(() => gone.click())
        expect(onSelect).not.toHaveBeenCalled()
    })

    it("renders nothing when there are no quick slots", () => {
        mount({ position: "panel", state: normalizeQuickSlots({ enabled: false }) })
        expect(host.innerHTML).toBe("")
    })

    it("has the tile interactions: click selects and flashes, double-click uses, right-click unpins, drop pins", () => {
        const backend = fakeBackend()
        const { onSelect, onFlash, onActivate, onPin } = mount({ position: "panel" }, backend)
        act(() => row("med").click())
        expect(onSelect).toHaveBeenCalledWith(player, player.items[3], 6)
        expect(onFlash).toHaveBeenCalledWith(6)
        act(() => { row("med").dispatchEvent(new MouseEvent("dblclick", { bubbles: true })) })
        expect(onActivate).toHaveBeenCalledWith(player, player.items[3])
        act(() => { row("weapon").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
        expect(onPin).toHaveBeenCalledWith("weapon", null)
        onPin.mockClear()
        expect(backend.drag(row("weapon"), row("med"))).toBe(true)
        expect(onPin).toHaveBeenCalledWith("med", 2)
    })
})

describe("QuickSlotBar interactions", () => {
    it("click selects the real item and flashes its slot; double-click activates it", () => {
        const { onSelect, onFlash, onActivate } = mount()
        act(() => tile("med").click())
        expect(onSelect).toHaveBeenCalledWith(player, player.items[3], 6)
        expect(onFlash).toHaveBeenCalledWith(6)
        act(() => { tile("med").dispatchEvent(new MouseEvent("dblclick", { bubbles: true })) })
        expect(onActivate).toHaveBeenCalledWith(player, player.items[3])
    })

    it("does nothing on a placeholder or while busy", () => {
        const first = mount({ state: normalizeQuickSlots({ enabled: true, hideWhenMissing: false, slots: entries }) })
        act(() => tile("gone").click())
        expect(first.onSelect).not.toHaveBeenCalled()
        const busy = mount({ busy: true })
        act(() => tile("med").click())
        expect(busy.onSelect).not.toHaveBeenCalled()
    })

    it("right-click unpins a pinned tile only", () => {
        const { onPin } = mount()
        act(() => { tile("med").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
        expect(onPin).not.toHaveBeenCalled()
        act(() => { tile("weapon").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
        expect(onPin).toHaveBeenCalledWith("weapon", null)
    })

    it("dropping an item from the player's inventory onto a tile pins it", () => {
        const backend = fakeBackend()
        const onPin = vi.fn()
        const { onSelect } = mount({ onPin }, backend)
        // A tile is a drag source for its real item (slot 2), so dragging it onto the "med" tile stands in for a grid slot drag.
        expect(backend.drag(tile("weapon"), tile("med"))).toBe(true)
        expect(onPin).toHaveBeenCalledWith("med", 2)
        expect(onSelect).not.toHaveBeenCalled()
    })

    it("refuses pin drops on linked ammo tiles", () => {
        const backend = fakeBackend()
        const onPin = vi.fn()
        mount({ onPin }, backend)
        backend.drag(tile("weapon"), tile("ammo"))
        expect(onPin).not.toHaveBeenCalled()
    })

    it("refuses pin drops while busy", () => {
        const backend = fakeBackend()
        const onPin = vi.fn()
        mount({ onPin, busy: true }, backend)
        expect(backend.drag(tile("weapon"), tile("med"))).toBe(false)
        expect(onPin).not.toHaveBeenCalled()
    })
})

describe("drag source", () => {
    it("drags the real item (player inventory + real slot) with the normal slot drag type", () => {
        const backend = fakeBackend()
        let dropped: unknown
        const Landing = () => {
            const [, ref] = useDrop(() => ({ accept: SLOT_DRAG_TYPE, drop: (item) => { dropped = item } }))
            return <div id="landing" ref={(node) => { ref(node) }} />
        }
        const handlers = { onSelect: vi.fn(), onActivate: vi.fn(), onPin: vi.fn(), onFlash: vi.fn() }
        act(() => {
            root.render(<DndProvider backend={backend.factory}>
                <QuickSlotBar position="side" state={normalizeQuickSlots({ enabled: true, slots: entries })} player={player} busy={false} {...handlers} />
                <Landing />
            </DndProvider>)
        })
        expect(backend.drag(tile("med"), host.querySelector("#landing"))).toBe(true)
        expect(dropped).toEqual({ inventoryId: "player:1", slot: 6 })
        expect(handlers.onPin).not.toHaveBeenCalled()
        // A drag is not a click: it must not also select the item.
        expect(handlers.onSelect).not.toHaveBeenCalled()
    })

    it("does not start a drag from a placeholder", () => {
        const backend = fakeBackend()
        mount({ state: normalizeQuickSlots({ enabled: true, hideWhenMissing: false, slots: entries }) }, backend)
        expect(backend.drag(tile("gone"), tile("med"))).toBe(false)
    })
})

describe("hotbar HUD quick entries", () => {
    const hotbar = { id: 1, slots: [{ slot: 1, name: "bread", label: "Bread", amount: 1 }] }
    it("renders quick entries after the numbered slots with their key and a divider", () => {
        act(() => { root.render(<HotbarHud hotbar={{ ...hotbar, quick: [{ id: "weapon", slotLabel: "Weapon", slot: 2, name: "weapon_pistol", label: "Pistol", amount: 1, key: "F5" }, { id: "ammo", slotLabel: "Ammo", name: "pistol_ammo", label: "Pistol Ammo", amount: 36, key: "" }] }} />) })
        const slots = [...host.querySelectorAll(".hotbar-slot")]
        expect(slots).toHaveLength(3)
        expect(host.querySelector(".hotbar-divider")).not.toBeNull()
        expect(slots[1].querySelector("kbd")?.textContent).toBe("F5")
        expect(slots[1].textContent).toContain("Pistol")
        expect(slots[2].querySelector("kbd")).toBeNull()
        expect(slots[2].querySelector("b")?.textContent).toBe("×36")
    })
    it("renders unchanged without quick entries", () => {
        act(() => { root.render(<HotbarHud hotbar={hotbar} />) })
        expect(host.querySelectorAll(".hotbar-slot")).toHaveLength(1)
        expect(host.querySelector(".hotbar-divider")).toBeNull()
    })
})

describe("in the app", () => {
    const post = (action: string, data: unknown) => act(() => { window.dispatchEvent(new MessageEvent("message", { data: { action, data } })) })
    const slotBtn = (label: string) => host.querySelector<HTMLButtonElement>(`.slot[aria-label^="${label}"]`)!
    const rightClick = (node: Element, x = 40, y = 50) => act(() => { node.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: x, clientY: y })) })
    const menu = () => host.ownerDocument.querySelector<HTMLElement>(".item-menu")
    const menuEntries = () => [...document.querySelectorAll<HTMLElement>("[data-menu-entry]")].map((node) => node.dataset.menuEntry)

    beforeEach(async () => {
        await act(async () => { root.render(<App />) })
        await post("kora_inventory:nui:sessionOpened", snapshot)
    })

    it("draws the quick slots as a drawer on the shell's left edge and pulses the real slot on click", async () => {
        await post("kora_inventory:nui:quickSlots", { enabled: true, hideWhenMissing: true, showKeyHints: true, slots: entries })
        expect(host.querySelector("main.inventory-shell > .quickslot-drawer-left .quickslot-bar-drawer")).not.toBeNull()
        expect(host.querySelector(".inventory-stage-player .quickslot")).toBeNull()
        act(() => tile("med").click())
        expect(slotBtn("Bandage").classList.contains("slot-flash")).toBe(true)
        expect(slotBtn("Bandage").getAttribute("aria-pressed")).toBe("true")
    })

    it("pins through the NUI helper and surfaces a refusal", async () => {
        await post("kora_inventory:nui:quickSlots", { enabled: true, slots: entries })
        pinQuickSlot.mockResolvedValueOnce({ ok: false, error: "item does not fit this quick slot" })
        await act(async () => { tile("weapon").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })) })
        expect(pinQuickSlot).toHaveBeenCalledWith("weapon", null)
        expect(host.textContent).toContain("item does not fit this quick slot")
    })

    it("marks the matching ammo when a weapon is selected, and weapons when ammo is", () => {
        act(() => slotBtn("Pistol,").click())
        expect(slotBtn("Pistol Ammo").classList.contains("slot-compatible")).toBe(true)
        expect(slotBtn("Rifle Ammo").classList.contains("slot-compatible")).toBe(false)
        expect(slotBtn("Bandage").classList.contains("slot-compatible")).toBe(false)
        expect(slotBtn("Pistol,").classList.contains("slot-compatible")).toBe(false)
        act(() => slotBtn("Pistol,").click())
        act(() => slotBtn("Pistol Ammo").click())
        expect(slotBtn("Pistol,").classList.contains("slot-compatible")).toBe(true)
        expect(slotBtn("Rifle Ammo").classList.contains("slot-compatible")).toBe(false)
    })

    it("does not mark compatible slots when ammoInfo is disabled", async () => {
        await post("kora_inventory:nui:config", { ammoInfo: { enabled: false } })
        act(() => slotBtn("Pistol,").click())
        expect(host.querySelector(".slot-compatible")).toBeNull()
    })

    it("opens the context menu in menu mode with only the entries that apply, instead of the split dialog", async () => {
        await post("kora_inventory:nui:config", { rightClick: "menu" })
        rightClick(slotBtn("Bandage"))
        expect(menu()).not.toBeNull()
        expect(document.querySelector('[role="dialog"]')).toBeNull()
        expect(menuEntries()).toEqual(["use", "split", "drop", "copy"])
        await post("kora_inventory:nui:giveAvailability", { available: true })
        rightClick(slotBtn("Pistol,"))
        expect(menuEntries()).toEqual(["drop", "give", "ammo", "copy"])
    })

    it("shows ammo info in the menu for weapons and ammo", async () => {
        await post("kora_inventory:nui:config", { rightClick: "menu" })
        rightClick(slotBtn("Pistol,"))
        act(() => document.querySelector<HTMLElement>('[data-menu-entry="ammo"]')!.click())
        expect(menu()!.textContent).toContain("Takes")
        expect(menu()!.textContent).toContain("Pistol Ammo (AMMO_PISTOL)")
        expect(menu()!.textContent).toContain("12 rounds")
    })

    it("runs menu actions through the existing intents and closes", async () => {
        await post("kora_inventory:nui:config", { rightClick: "menu" })
        rightClick(slotBtn("Bandage"))
        await act(async () => { document.querySelector<HTMLElement>('[data-menu-entry="drop"]')!.click() })
        expect(menu()).toBeNull()
        expect(sendIntent).toHaveBeenCalledWith(expect.objectContaining({ intent: "drop", payload: { inventory: "player:1", slot: 6, amount: 4 } }))
        rightClick(slotBtn("Bandage"))
        await act(async () => { document.querySelector<HTMLElement>('[data-menu-entry="use"]')!.click() })
        expect(sendIntent).toHaveBeenCalledWith(expect.objectContaining({ intent: "use", payload: { inventory: "player:1", slot: 6 } }))
        rightClick(slotBtn("Bandage"))
        act(() => document.querySelector<HTMLElement>('[data-menu-entry="split"]')!.click())
        expect(document.querySelector('[role="dialog"]')).not.toBeNull()
    })

    it("closes on Escape (without closing the inventory), on an outside click and on a session patch", async () => {
        await post("kora_inventory:nui:config", { rightClick: "menu" })
        rightClick(slotBtn("Bandage"))
        act(() => { window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })) })
        expect(menu()).toBeNull()
        expect(closeSession).not.toHaveBeenCalled()
        rightClick(slotBtn("Bandage"))
        act(() => { document.body.dispatchEvent(new MouseEvent("mousedown", { bubbles: true })) })
        expect(menu()).toBeNull()
        rightClick(slotBtn("Bandage"))
        await post("kora_inventory:nui:sessionPatched", { sessionId: "s1", revision: 2, player: { items: player.items } })
        expect(menu()).toBeNull()
    })

    it("keeps the split dialog in split mode and does nothing in none mode", async () => {
        rightClick(slotBtn("Bandage"))
        expect(document.querySelector('[role="dialog"]')).not.toBeNull()
        expect(menu()).toBeNull()
        act(() => { window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })) })
        await post("kora_inventory:nui:config", { rightClick: "none" })
        rightClick(slotBtn("Bandage"))
        expect(document.querySelector('[role="dialog"]')).toBeNull()
        expect(menu()).toBeNull()
    })

    it("falls back to the legacy rightClickSplit when rightClick is not pushed", async () => {
        await post("kora_inventory:nui:config", { rightClickSplit: false })
        rightClick(slotBtn("Bandage"))
        expect(document.querySelector('[role="dialog"]')).toBeNull()
    })

    it("shows quick entries in the hotbar HUD only for the pushed payload", async () => {
        await act(async () => { root.render(<App />) })
        await post("kora_inventory:nui:sessionClosed", { sessionId: "s1" })
        await post("kora_inventory:nui:hotbar", { seconds: 5, slots: [{ slot: 1 }], quick: [{ id: "weapon", slotLabel: "Weapon", name: "weapon_pistol", label: "Pistol", key: "F5" }, "junk", null] })
        expect(host.querySelectorAll(".hotbar-slot-quick")).toHaveLength(1)
        await post("kora_inventory:nui:hotbar", { seconds: 5, slots: [{ slot: 1 }] })
        expect(host.querySelectorAll(".hotbar-slot-quick")).toHaveLength(0)
    })
})
