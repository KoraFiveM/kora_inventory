// @vitest-environment jsdom
import { act } from "react"
import { createRoot } from "react-dom/client"
import { afterEach, describe, expect, it } from "vitest"
import { LocaleProvider } from "@/lib/locales"
import { SlotTooltip } from "./SlotTooltip"

;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true

describe("SlotTooltip", () => {
    afterEach(() => { document.body.innerHTML = "" })
    it("renders item details in a body portal and clamps into the viewport", () => {
        const host = document.createElement("div")
        document.body.appendChild(host)
        act(() => createRoot(host).render(<LocaleProvider><SlotTooltip decimals={1} x={99999} y={99999} item={{ slot: 1, name: "bandage", label: "Bandage", amount: 3, weight: 120, description: "Stops bleeding", durability: 80, displayMeta: [{ key: "q", label: "Quality", value: 92.7000004 }] }} /></LocaleProvider>))
        const tip = document.body.querySelector<HTMLElement>(".slot-tooltip")!
        expect(host.contains(tip)).toBe(false)
        for (const text of ["Bandage", "×3", "120 g", "80%", "Quality", "92.7", "Stops bleeding"]) expect(tip.textContent).toContain(text)
        expect(parseFloat(tip.style.left)).toBeLessThan(99999)
        expect(parseFloat(tip.style.top)).toBeLessThan(99999)
    })

    it("shows the placement footprint of a legacy item in grid mode", () => {
        const host = document.createElement("div")
        document.body.appendChild(host)
        const root = createRoot(host)
        const item = { slot: 1, name: "repairkit", amount: 1, weight: 2500, gridWidth: 1, gridHeight: 1, gridBaseWidth: 3, gridBaseHeight: 2 }
        act(() => root.render(<LocaleProvider><SlotTooltip decimals={1} x={0} y={0} item={item} showGridSize /></LocaleProvider>))
        expect(document.body.querySelector(".slot-tooltip")?.textContent).toContain("Grid size3 × 2")
        act(() => root.unmount())
    })
})
