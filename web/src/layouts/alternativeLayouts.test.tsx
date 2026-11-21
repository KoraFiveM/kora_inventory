// @vitest-environment jsdom
import { createRef, type ReactNode } from "react"
import { act } from "react"
import { createRoot, type Root } from "react-dom/client"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

// The dock tabs are react-dnd drop targets. The panels here are stubs, so the
// only useDrop caller is a tab: let each test decide whether a drag is over it.
const dnd = vi.hoisted(() => ({ over: { value: false }, specs: [] as Array<Record<string, unknown>> }))
vi.mock("react-dnd", () => ({
    useDrop: (factory: () => Record<string, unknown>) => {
        const spec = factory()
        dnd.specs.push(spec)
        return [{ over: dnd.over.value }, () => undefined]
    },
}))

import { DEFAULT_PLAYER_LAYOUT } from "@/lib/playerLayout"
import { SLOT_DRAG_TYPE } from "@/components/dnd"
import { LAYOUTS } from "./index"
import { DOCK_TAB_HOVER_MS } from "./DockLayout"
import type { LayoutId, LayoutProps } from "./types"

function props(layoutId: LayoutId, overrides: Partial<LayoutProps> = {}): LayoutProps {
    const noop = () => undefined
    return {
        layoutId,
        session: {
            sessionId: "s1", token: "t", revision: 1,
            player: { id: "player:1", label: "Pockets", type: "player", slots: 5, weight: 0, maxWeight: 1000, items: [] },
        },
        selected: undefined,
        inspected: undefined,
        solo: true,
        transferView: false,
        playerLayout: DEFAULT_PLAYER_LAYOUT,
        drawerLeft: false,
        busy: false,
        movePending: false,
        uiConfig: {} as LayoutProps["uiConfig"],
        shellRef: createRef<HTMLElement>(),
        shellStyle: {},
        canDropSlot: () => true,
        onDrop: noop,
        onDragEnd: noop,
        onSelect: noop,
        onActivate: noop,
        onSplit: noop,
        onClose: noop,
        onClearSelection: noop,
        topbar: <header data-testid="topbar" />,
        playerPanel: <section data-testid="player" />,
        secondaryPanel: null,
        inspector: null,
        drawerInspector: null,
        shortcutBar: <footer data-testid="shortcuts" />,
        renderQuickSlots: () => null,
        dragPreview: null,
        ...overrides,
    }
}

const withSecondary = (overrides: Partial<LayoutProps> = {}) => {
    const base = props("classic")
    return {
        solo: false,
        transferView: true,
        session: { ...base.session, secondary: { id: "stash:a", label: "Garage stash", type: "stash", slots: 5, weight: 0, maxWeight: 1000, items: [{ slot: 1, name: "water", amount: 2 }, { slot: 3, name: "bread", amount: 1 }] } },
        secondaryPanel: <section data-testid="secondary" />,
        inspector: <aside data-testid="inspector" />,
        ...overrides,
    } as Partial<LayoutProps>
}

describe("loadout, compact and dock layouts", () => {
    let root: Root
    let host: HTMLElement
    const render = (id: LayoutId, overrides: Partial<LayoutProps> = {}) => {
        const Layout = LAYOUTS[id]
        act(() => root.render(<Layout {...props(id, overrides)} />))
    }
    const q = (testId: string) => host.querySelector(`[data-testid="${testId}"]`)
    const shell = () => host.querySelector("main.inventory-shell")!
    const quick: ReactNode = <div data-testid="quick">q</div>

    beforeEach(() => {
        dnd.over.value = false
        dnd.specs.length = 0
        host = document.createElement("div"); document.body.appendChild(host)
        root = createRoot(host)
    })
    afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers() })

    for (const id of ["loadout", "compact", "dock"] as const) {
        describe(id, () => {
            it("marks the shell and renders the shared nodes in solo view", () => {
                render(id)
                expect(shell().getAttribute("data-layout")).toBe(id)
                expect(q("topbar")).not.toBeNull()
                expect(q("player")).not.toBeNull()
                expect(q("shortcuts")).not.toBeNull()
                expect(q("secondary")).toBeNull()
                expect(q("inspector")).toBeNull()
            })

            it("renders the secondary panel in transfer view", () => {
                render(id, withSecondary())
                expect(q("player")).not.toBeNull()
                expect(host.querySelector('[data-testid="secondary"]')).not.toBeNull()
            })

            it("leaves no quick-slot frame when the strip renders nothing", () => {
                render(id, withSecondary({ renderQuickSlots: () => null }))
                expect(host.querySelector(".layout-quick")).toBeNull()
                render(id, { renderQuickSlots: () => false })
                expect(host.querySelector(".layout-quick")).toBeNull()
            })

            it("renders the quick-slot strip in a frameless wrapper", () => {
                const positions: string[] = []
                render(id, { renderQuickSlots: (position) => { positions.push(position); return quick } })
                expect(host.querySelectorAll(".layout-quick")).toHaveLength(1)
                expect(host.querySelector(".layout-quick")!.contains(q("quick"))).toBe(true)
                expect(positions).toEqual([{ loadout: "side", compact: "top", dock: "top" }[id]])
            })
        })
    }

    describe("loadout", () => {
        const order = () => Array.from(host.querySelector(".loadout-main")!.children).map((c) => c.className.split(" ").find((n) => /stage-(player|secondary)|loadout-centre/.test(n)))
        it("puts quick slots over the inspector in the centre column, between the panels", () => {
            render("loadout", withSecondary({ renderQuickSlots: () => quick }))
            expect(order()).toEqual(["inventory-stage-player", "loadout-centre", "inventory-stage-secondary"])
            const centre = host.querySelector(".loadout-centre")!
            expect(Array.from(centre.children).map((c) => c.getAttribute("data-testid") ?? c.className)).toEqual(["layout-quick", "inspector"])
        })
        it("swaps the columns when the personal side is right", () => {
            render("loadout", withSecondary({ playerLayout: { ...DEFAULT_PLAYER_LAYOUT, playerSide: "right" } }))
            expect(order()).toEqual(["inventory-stage-secondary", "loadout-centre", "inventory-stage-player"])
        })
        it("solo: pockets then centre, inspector only when given, mirrored with the drawer", () => {
            render("loadout")
            expect(shell().className).toContain("inventory-shell-solo")
            expect(host.querySelector(".loadout-centre")!.children).toHaveLength(0)
            render("loadout", { inspector: <aside data-testid="inspector" />, drawerLeft: true })
            expect(order()).toEqual(["loadout-centre", "inventory-stage-player"])
            expect(shell().className).toContain("inventory-shell-drawer-left")
            expect(host.querySelector(".loadout-centre")!.contains(q("inspector"))).toBe(true)
        })
    })

    describe("compact", () => {
        it("stacks the secondary under the player panel behind a divider", () => {
            render("compact", withSecondary())
            const stack = Array.from(host.querySelector(".compact-stack")!.children)
            expect(stack.map((c) => c.className.split(" ")[0])).toEqual(["compact-pane", "compact-divider", "compact-pane"])
            expect(stack[1].getAttribute("role")).toBe("separator")
            expect(shell().className).toContain("layout-transfer")
        })
        it("solo has no divider and no column inspector", () => {
            render("compact", { inspector: <aside data-testid="inspector" /> })
            expect(host.querySelector(".compact-divider")).toBeNull()
            expect(shell().className).toContain("layout-solo")
            expect(q("inspector")).toBeNull()
        })
        it("floats the drawer inspector as a popover only when something is selected", () => {
            render("compact", withSecondary())
            expect(host.querySelector(".compact-popover")).toBeNull()
            render("compact", withSecondary({ drawerInspector: <aside data-testid="drawer" /> }))
            const popover = host.querySelector(".compact-popover")!
            expect(popover.contains(q("drawer"))).toBe(true)
            expect(popover.className).not.toContain("compact-popover-left")
            // Not part of the stacked columns.
            expect(host.querySelector(".compact-stack")!.contains(popover)).toBe(false)
        })
        it("opens the popover on the left when the window sits on the right", () => {
            render("compact", { drawerInspector: <aside />, drawerLeft: true })
            expect(host.querySelector(".compact-popover")!.className).toContain("compact-popover-left")
            render("compact", { drawerInspector: <aside />, playerLayout: { ...DEFAULT_PLAYER_LAYOUT, playerSide: "right" } })
            expect(host.querySelector(".compact-popover")!.className).toContain("compact-popover-left")
        })
    })

    describe("dock", () => {
        const tabs = () => Array.from(host.querySelectorAll<HTMLElement>('[role="tab"]'))
        const panes = () => Array.from(host.querySelectorAll<HTMLElement>('[role="tabpanel"]'))
        const hidden = (el: Element) => el.className.includes("dock-pane-hidden")

        it("docks left by default and right for the right side", () => {
            render("dock")
            expect(shell().className).toContain("dock-left")
            render("dock", { playerLayout: { ...DEFAULT_PLAYER_LAYOUT, playerSide: "right" } })
            expect(shell().className).toContain("dock-right")
        })
        it("solo shows a Pockets tab only", () => {
            render("dock")
            expect(tabs().map((tab) => tab.textContent)).toEqual(["Pockets"])
            expect(panes()).toHaveLength(1)
        })
        it("transfer adds the secondary's tab with an item-count badge, pockets stays default", () => {
            render("dock", withSecondary())
            expect(tabs().map((tab) => tab.querySelector(".dock-tab-label")!.textContent)).toEqual(["Pockets", "Garage stash"])
            expect(tabs()[1].querySelector(".dock-tab-badge")!.textContent).toBe("2")
            expect(tabs()[0].getAttribute("aria-selected")).toBe("true")
            expect(tabs()[1].getAttribute("aria-selected")).toBe("false")
            expect(panes().map(hidden)).toEqual([false, true])
        })
        it("switches tabs on click and keeps both panels mounted", () => {
            render("dock", withSecondary())
            act(() => tabs()[1].click())
            expect(tabs()[1].getAttribute("aria-selected")).toBe("true")
            expect(panes().map(hidden)).toEqual([true, false])
            expect(q("player")).not.toBeNull()
            act(() => tabs()[0].click())
            expect(panes().map(hidden)).toEqual([false, true])
        })
        it("falls back to pockets when the secondary closes", () => {
            render("dock", withSecondary())
            act(() => tabs()[1].click())
            render("dock")
            expect(tabs()).toHaveLength(1)
            expect(hidden(panes()[0])).toBe(false)
        })
        it("registers tabs as non-dropping targets for slot drags", () => {
            render("dock", withSecondary())
            expect(dnd.specs.length).toBeGreaterThan(0)
            for (const spec of dnd.specs) {
                expect(spec.accept).toBe(SLOT_DRAG_TYPE)
                expect((spec.canDrop as () => boolean)()).toBe(false)
            }
        })
        it("switches to a tab a drag rests on, after a short delay", () => {
            vi.useFakeTimers()
            render("dock", withSecondary())
            dnd.over.value = true // every tab reports a drag over it; the active one ignores it
            render("dock", withSecondary())
            expect(tabs()[1].getAttribute("aria-selected")).toBe("false")
            act(() => { vi.advanceTimersByTime(DOCK_TAB_HOVER_MS - 10) })
            expect(tabs()[1].getAttribute("aria-selected")).toBe("false")
            act(() => { vi.advanceTimersByTime(20) })
            expect(tabs()[1].getAttribute("aria-selected")).toBe("true")
            expect(panes().map(hidden)).toEqual([true, false])
        })
        it("does not switch when the drag leaves the tab before the delay", () => {
            vi.useFakeTimers()
            render("dock", withSecondary())
            dnd.over.value = true
            render("dock", withSecondary())
            act(() => { vi.advanceTimersByTime(DOCK_TAB_HOVER_MS - 10) })
            dnd.over.value = false
            render("dock", withSecondary())
            act(() => { vi.advanceTimersByTime(500) })
            expect(tabs()[1].getAttribute("aria-selected")).toBe("false")
        })
        it("slides the inspector over the dock only when something is selected", () => {
            render("dock", withSecondary())
            expect(host.querySelector(".dock-inspector")).toBeNull()
            render("dock", withSecondary({ drawerInspector: <aside data-testid="drawer" /> }))
            expect(host.querySelector(".dock-body .dock-inspector")!.contains(q("drawer"))).toBe(true)
        })
    })
})
