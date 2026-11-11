import { describe, expect, it } from "vitest"
import { createIntentResults } from "./intentResults"

describe("intent results", () => {
    it("resolves a waiter when the verdict arrives afterwards", async () => {
        const results = createIntentResults()
        const verdict = results.wait(1)
        results.deliver(1, { ok: true })
        await expect(verdict).resolves.toEqual({ ok: true })
    })

    it("hands over a verdict that beat the fetch response", async () => {
        const results = createIntentResults()
        results.deliver(2, { ok: false, error: "over weight" })
        await expect(results.wait(2)).resolves.toEqual({ ok: false, error: "over weight" })
    })

    it("keeps verdicts apart by request id", async () => {
        const results = createIntentResults()
        const first = results.wait(1)
        const second = results.wait(2)
        results.deliver(2, { ok: false, error: "no" })
        results.deliver(1, { ok: true })
        await expect(first).resolves.toEqual({ ok: true })
        await expect(second).resolves.toEqual({ ok: false, error: "no" })
    })

    it("bounds the verdicts nobody asked for", async () => {
        const results = createIntentResults()
        for (let id = 1; id <= 100; id++) results.deliver(id, { ok: true })
        const oldest = results.wait(1)
        const newest = results.wait(100)
        await expect(newest).resolves.toEqual({ ok: true })
        results.deliver(1, { ok: false, error: "late" })
        await expect(oldest).resolves.toEqual({ ok: false, error: "late" })
    })

    it("forgets everything on reset", async () => {
        const results = createIntentResults()
        results.deliver(3, { ok: true })
        results.reset()
        let settled = false
        void results.wait(3).then(() => { settled = true })
        await Promise.resolve()
        expect(settled).toBe(false)
    })
})
