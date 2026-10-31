import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { createMoveQueue, type MoveAnswer, type MoveJob } from "./moveQueue"

type Deferred = { resolve: (answer: MoveAnswer) => void; reject: (error: unknown) => void }

function harness(maxQueued = 8) {
    const log: string[] = []
    const failures: Array<[string, string]> = []
    const pendingStates: boolean[] = []
    const queue = createMoveQueue({ maxQueued, onPending: (p) => pendingStates.push(p), onFailure: (message, reason) => failures.push([reason, message]) })
    const deferreds: Record<string, Deferred> = {}
    const job = (name: string, extra: Partial<MoveJob> = {}) => () => ({
        send: () => { log.push(`send:${name}`); return new Promise<MoveAnswer>((resolve, reject) => { deferreds[name] = { resolve, reject } }) },
        rollback: (message: string) => { log.push(`rollback:${name}:${message}`) },
        timeoutMs: 1000,
        ...extra,
    })
    return { queue, log, failures, pendingStates, deferreds, job }
}
const tick = (ms = 1) => vi.advanceTimersByTimeAsync(ms)

beforeEach(() => { vi.useFakeTimers() })
afterEach(() => { vi.useRealTimers() })

describe("moveQueue", () => {
    it("runs jobs one at a time and in order", async () => {
        const h = harness()
        expect(h.queue.enqueue(h.job("a"))).toBe("started")
        expect(h.queue.enqueue(h.job("b"))).toBe("queued")
        expect(h.queue.enqueue(h.job("c"))).toBe("queued")
        expect(h.log).toEqual(["send:a"])
        h.deferreds.a.resolve({ ok: true }); await tick()
        expect(h.log).toEqual(["send:a", "send:b"])
        h.deferreds.b.resolve({ ok: true }); await tick()
        h.deferreds.c.resolve({ ok: true }); await tick()
        expect(h.log).toEqual(["send:a", "send:b", "send:c"])
        expect(h.queue.pending).toBe(false)
        expect(h.pendingStates.at(-1)).toBe(false)
    })

    it("rolls back a job that never gets an answer and carries on with the next", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a")); h.queue.enqueue(h.job("b"))
        await tick(1000); await tick()
        expect(h.log).toEqual(["send:a", "rollback:a:Inventory did not respond", "send:b"])
        expect(h.failures).toEqual([["timeout", "Inventory did not respond"]])
        h.deferreds.b.resolve({ ok: true }); await tick()
        expect(h.queue.pending).toBe(false)
    })

    it("ignores a late answer to a job that already timed out, however it arrives", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a")); h.queue.enqueue(h.job("b"))
        await tick(1000); await tick()
        h.deferreds.a.resolve({ ok: false, error: "ancient" }); await tick()
        expect(h.log.filter((entry) => entry.startsWith("rollback"))).toEqual(["rollback:a:Inventory did not respond"])
        expect(h.queue.pending).toBe(true) // b is still in flight, untouched by a
        h.deferreds.b.resolve({ ok: true }); await tick()
        expect(h.queue.pending).toBe(false)
    })

    it("a refusal rolls back only that job and the rest still run", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a")); h.queue.enqueue(h.job("b"))
        h.deferreds.a.resolve({ ok: false, error: "over weight" }); await tick()
        expect(h.log).toEqual(["send:a", "rollback:a:over weight", "send:b"])
        expect(h.failures).toEqual([["rejected", "over weight"]])
    })

    it("a transport error settles the job as failed", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a")); h.queue.enqueue(h.job("b"))
        h.deferreds.a.reject(new Error("net")); await tick()
        expect(h.log).toEqual(["send:a", "rollback:a:Inventory connection interrupted", "send:b"])
    })

    it("a send that throws synchronously does not wedge the queue", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a", { send: () => { throw new Error("boom") } })); h.queue.enqueue(h.job("b"))
        await tick()
        expect(h.log).toEqual(["rollback:a:Inventory connection interrupted", "send:b"])
    })

    it("settles exactly once when a rejected event and the answer both arrive", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a")); h.queue.enqueue(h.job("b"))
        h.queue.reject("denied")
        h.deferreds.a.resolve({ ok: false, error: "denied" }); await tick()
        expect(h.log.filter((entry) => entry.startsWith("rollback"))).toEqual(["rollback:a:denied"])
        expect(h.failures).toHaveLength(1)
        expect(h.log).toContain("send:b")
    })

    it("a rejected event with nothing in flight changes nothing", () => {
        const h = harness()
        h.queue.reject("stray")
        expect(h.log).toEqual([]); expect(h.failures).toEqual([])
    })

    it("skips a job that can no longer run instead of stalling the line", async () => {
        const h = harness()
        const spy = vi.spyOn(console, "error").mockImplementation(() => undefined)
        h.queue.enqueue(h.job("a"))
        h.queue.enqueue(() => undefined)
        h.queue.enqueue(() => { throw new Error("stale") })
        h.queue.enqueue(h.job("c"))
        h.deferreds.a.resolve({ ok: true }); await tick()
        expect(h.log).toEqual(["send:a", "send:c"])
        expect(h.queue.pending).toBe(true) // c
        h.deferreds.c.resolve({ ok: true }); await tick()
        expect(h.queue.enqueue(() => undefined)).toBe("skipped")
        expect(h.queue.pending).toBe(false)
        spy.mockRestore()
    })

    it("rapid repeated drags: every one is sent exactly once and the queue ends idle", async () => {
        const h = harness(50)
        const names = Array.from({ length: 30 }, (_, i) => `m${i}`)
        for (const name of names) h.queue.enqueue(h.job(name))
        for (const name of names) {
            await tick(Math.floor(Math.random() * 3))
            // alternate answers, refusals, silence and transport errors
            const n = Number(name.slice(1))
            if (n % 4 === 0) h.deferreds[name].resolve({ ok: true })
            else if (n % 4 === 1) h.deferreds[name].resolve({ ok: false, error: "no" })
            else if (n % 4 === 2) h.deferreds[name].reject(new Error("x"))
            else await tick(1000)
            await tick()
        }
        expect(h.log.filter((entry) => entry.startsWith("send:"))).toEqual(names.map((name) => `send:${name}`))
        expect(h.queue.pending).toBe(false)
        expect(h.queue.waiting).toBe(0)
    })

    it("refuses beyond maxQueued but recovers once the line drains", async () => {
        const h = harness(2)
        expect(h.queue.enqueue(h.job("a"))).toBe("started")
        expect(h.queue.enqueue(h.job("b"))).toBe("queued")
        expect(h.queue.enqueue(h.job("c"))).toBe("queued")
        expect(h.queue.enqueue(h.job("d"))).toBe("full")
        for (const name of ["a", "b", "c"]) { h.deferreds[name].resolve({ ok: true }); await tick() }
        expect(h.queue.enqueue(h.job("e"))).toBe("started")
    })

    it("a job that also awaits patches settles only after the answer and every patch", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a", { awaiting: ["p", "s"] })); h.queue.enqueue(h.job("b"))
        h.deferreds.a.resolve({ ok: true }); await tick()
        expect(h.log).toEqual(["send:a"])
        h.queue.patched(["p"]); await tick()
        expect(h.log).toEqual(["send:a"])
        h.queue.patched(["s"]); await tick()
        expect(h.log).toEqual(["send:a", "send:b"])
    })

    it("a patch that lands before the answer still counts", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a", { awaiting: ["p"] }))
        h.queue.patched(["p"])
        expect(h.queue.pending).toBe(true)
        h.deferreds.a.resolve({ ok: true }); await tick()
        expect(h.queue.pending).toBe(false)
    })

    it("a job without a timeout (use) is never rolled back by a timer", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a", { timeoutMs: undefined }))
        await tick(60_000)
        expect(h.log).toEqual(["send:a"])
    })

    it("reset forgets the line without rolling back, and the old answer cannot restart it", async () => {
        const h = harness()
        h.queue.enqueue(h.job("a")); h.queue.enqueue(h.job("b"))
        h.queue.reset()
        h.deferreds.a.resolve({ ok: false, error: "ghost" }); await tick(2000)
        expect(h.log).toEqual(["send:a"])
        expect(h.queue.pending).toBe(false)
        expect(h.queue.enqueue(h.job("c"))).toBe("started")
    })

    it("a throwing rollback still lets the next job run", async () => {
        const h = harness()
        const spy = vi.spyOn(console, "error").mockImplementation(() => undefined)
        h.queue.enqueue(h.job("a", { rollback: () => { throw new Error("bad rollback") } })); h.queue.enqueue(h.job("b"))
        h.deferreds.a.resolve({ ok: false }); await tick()
        expect(h.log).toEqual(["send:a", "send:b"])
        spy.mockRestore()
    })
})
