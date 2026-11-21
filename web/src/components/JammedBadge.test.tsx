// @vitest-environment jsdom
import { act } from "react"
import { createRoot } from "react-dom/client"
import { afterEach, describe, expect, it } from "vitest"
import { LocaleProvider } from "@/lib/locales"
import { JammedBadge } from "./JammedBadge"
import { SlotTooltip } from "./SlotTooltip"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

function render(node: React.ReactNode) {
    const host = document.createElement("div")
    document.body.appendChild(host)
    act(() => createRoot(host).render(<LocaleProvider>{node}</LocaleProvider>))
    return host
}

describe("JammedBadge", () => {
    afterEach(() => { document.body.innerHTML = "" })
    it("shows a badge only for a weapon the server flagged as jammed", () => {
        expect(render(<JammedBadge item={{ jammed: true }} />).textContent).toBe("Jammed")
        expect(render(<JammedBadge item={{ jammed: false }} />).textContent).toBe("")
        expect(render(<JammedBadge item={{}} />).textContent).toBe("")
    })
    it("adds a Jammed row to the tooltip", () => {
        render(<SlotTooltip decimals={1} x={0} y={0} item={{ slot: 1, name: "weapon_pistol", amount: 1, durability: 40, jammed: true }} />)
        expect(document.body.querySelector(".slot-tooltip")!.textContent).toContain("Jammed")
    })
})
