import { describe, expect, it } from "vitest"
import { availableTips, chooseTip, dismissTips, EMPTY_TIPS_STATE, loadTipsState, markSeen, parseTipsState, registerOpening, saveTipsState, TIPS_STORAGE_KEY, tipsActive, type TipsContext } from "./tips"

const everything: TipsContext = {
    quickTransfer: true,
    modifierDrag: true,
    rightClick: "split",
    quickSlotsEnabled: true,
    organize: { enabled: true, sort: true, stack: true },
    playerLayoutChoice: true,
    layouts: { classic: true, loadout: true, compact: true, dock: true },
}

describe("availableTips", () => {
    it("offers only tips for features that are on, in a fixed order", () => {
        expect(availableTips(everything)).toEqual(["drag_drop", "quick_transfer", "modifier_drag", "right_click_split", "quick_slot", "organize", "layout"])
    })

    it("follows the right-click mode", () => {
        expect(availableTips({ ...everything, rightClick: "menu" })).toContain("right_click_menu")
        expect(availableTips({ ...everything, rightClick: "menu" })).not.toContain("right_click_split")
        const none = availableTips({ ...everything, rightClick: "none" })
        expect(none).not.toContain("right_click_menu")
        expect(none).not.toContain("right_click_split")
    })

    it("drops tips for disabled features", () => {
        const tips = availableTips({ ...everything, quickTransfer: false, modifierDrag: false, quickSlotsEnabled: false, organize: { enabled: false, sort: true, stack: true } })
        expect(tips).toEqual(["drag_drop", "right_click_split", "layout"])
    })

    it("needs sort or stack for the organize tip", () => {
        expect(availableTips({ ...everything, organize: { enabled: true, sort: false, stack: false } })).not.toContain("organize")
        expect(availableTips({ ...everything, organize: { enabled: true, sort: false, stack: true } })).toContain("organize")
    })

    it("only suggests the layout choice when there is more than one layout to pick", () => {
        expect(availableTips({ ...everything, playerLayoutChoice: false })).not.toContain("layout")
        expect(availableTips({ ...everything, layouts: { loadout: false, compact: false, dock: false } })).not.toContain("layout")
        expect(availableTips({ ...everything, layouts: { loadout: false, compact: false, dock: false, classic: false } })).not.toContain("layout")
        expect(availableTips({ ...everything, layouts: { loadout: true, compact: false, dock: false } })).toContain("layout")
    })
})

describe("chooseTip", () => {
    const list = ["drag_drop", "quick_transfer", "organize"] as const

    it("starts with the first unseen tip", () => {
        expect(chooseTip(list, [])).toBe("drag_drop")
        expect(chooseTip(list, ["drag_drop"])).toBe("quick_transfer")
    })

    it("moves on from the current tip, skipping seen ones", () => {
        expect(chooseTip(list, ["drag_drop"], "drag_drop")).toBe("quick_transfer")
        expect(chooseTip(list, ["drag_drop", "quick_transfer"], "quick_transfer")).toBe("organize")
        expect(chooseTip(list, ["quick_transfer"], "drag_drop")).toBe("organize")
    })

    it("cycles once everything has been seen", () => {
        const seen = ["drag_drop", "quick_transfer", "organize"]
        expect(chooseTip(list, seen, "organize")).toBe("drag_drop")
        expect(chooseTip(list, seen, "drag_drop")).toBe("quick_transfer")
        expect(chooseTip(list, seen)).toBe("drag_drop")
    })

    it("handles one tip and none", () => {
        expect(chooseTip(["drag_drop"], ["drag_drop"], "drag_drop")).toBe("drag_drop")
        expect(chooseTip([], [])).toBeUndefined()
    })

    it("restarts from the top when the current tip is no longer available", () => {
        expect(chooseTip(list, [], "layout")).toBe("drag_drop")
    })
})

describe("progress", () => {
    it("shows on at most maxShows openings", () => {
        let state = EMPTY_TIPS_STATE
        const shown: boolean[] = []
        for (let open = 0; open < 4; open++) {
            state = registerOpening(state)
            shown.push(tipsActive({ enabled: true, maxShows: 2 }, state))
        }
        expect(shown).toEqual([true, true, false, false])
    })

    it("never shows when disabled or dismissed", () => {
        expect(tipsActive({ enabled: false, maxShows: 5 }, registerOpening(EMPTY_TIPS_STATE))).toBe(false)
        expect(tipsActive({ enabled: true, maxShows: 5 }, dismissTips(registerOpening(EMPTY_TIPS_STATE)))).toBe(false)
    })

    it("records seen tips once", () => {
        const state = markSeen(markSeen(EMPTY_TIPS_STATE, "organize"), "organize")
        expect(state.seen).toEqual(["organize"])
    })

    it("does not modify the state it is given", () => {
        const state = { seen: [], dismissed: false, opens: 0 }
        registerOpening(state); markSeen(state, "organize"); dismissTips(state)
        expect(state).toEqual({ seen: [], dismissed: false, opens: 0 })
    })
})

describe("storage", () => {
    const memory = () => {
        const data = new Map<string, string>()
        return { data, getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => void data.set(key, value) }
    }

    it("round-trips under kora_inventory:tips", () => {
        const storage = memory()
        saveTipsState({ seen: ["organize"], dismissed: true, opens: 3 }, storage)
        expect(storage.data.has("kora_inventory:tips")).toBe(true)
        expect(TIPS_STORAGE_KEY).toBe("kora_inventory:tips")
        expect(loadTipsState(storage)).toEqual({ seen: ["organize"], dismissed: true, opens: 3 })
    })

    it("treats malformed data as a fresh start", () => {
        expect(parseTipsState("not json")).toEqual(EMPTY_TIPS_STATE)
        expect(parseTipsState("42")).toEqual(EMPTY_TIPS_STATE)
        expect(parseTipsState(null)).toEqual(EMPTY_TIPS_STATE)
        expect(parseTipsState(JSON.stringify({ seen: [1, "organize", null], dismissed: "yes", opens: -4 }))).toEqual({ seen: ["organize"], dismissed: false, opens: 0 })
    })

    it("survives storage that throws", () => {
        const broken = { getItem: () => { throw new Error("denied") }, setItem: () => { throw new Error("full") } }
        expect(loadTipsState(broken)).toEqual(EMPTY_TIPS_STATE)
        expect(() => saveTipsState(EMPTY_TIPS_STATE, broken)).not.toThrow()
    })
})
