/**
 * Serial queue for inventory requests (moves, buys, drops, ...).
 *
 * One request is in flight at a time; drags made meanwhile wait their turn.
 * The guarantee this module exists for: every job SETTLES EXACTLY ONCE, as
 * success, refusal, transport error or timeout, and whatever the outcome the
 * next waiting job is started. A job that never gets an answer is rolled back
 * by its own timer, a late answer to a settled job is ignored, and a job that
 * cannot start (its item vanished) is skipped rather than stalling the line.
 */

export interface MoveAnswer { ok: boolean; error?: string }
export type FailureReason = "rejected" | "timeout" | "error"

export interface MoveJob {
    /** Sends the request and resolves with the answer of the server. A rejection is a transport error. */
    send: () => Promise<MoveAnswer>
    /** Called once, instead of success, when the job was refused, errored or timed out. */
    rollback: (message: string, reason: FailureReason) => void
    /** Milliseconds before the job is rolled back as unanswered; omit for jobs that may run long. */
    timeoutMs?: number
    /** Inventory ids whose patch must also arrive before the job counts as done. */
    awaiting?: string[]
    /**
     * Once the server has answered ok, the longest the job may keep the line waiting for
     * its `awaiting` patches (defaults to timeoutMs). Past it the job settles as a success
     * and onUnconfirmed asks for a resync; a confirmed move is never rolled back for a patch.
     */
    confirmMs?: number
}

/** True when a drag lands on the slot it started from: nothing to send, nothing to predict. */
export function isNoopMove(from: { id: string; slot: number }, to: { id: string; slot: number }): boolean {
    return from.id === to.id && from.slot === to.slot
}

/** Builds the job when its turn comes, against whatever the UI looks like by then; undefined skips it. */
export type JobFactory = () => MoveJob | undefined

export interface MoveQueueOptions {
    /** Jobs allowed to wait behind the one in flight. */
    maxQueued: number
    /** Called whenever a job starts or settles (true while one is in flight). */
    onPending?: (pending: boolean) => void
    /** Called when a confirmed job stopped waiting for its patches (ask the server to re-send the state). */
    onUnconfirmed?: () => void
    /** Called after a job failed and has been rolled back. */
    onFailure?: (message: string, reason: FailureReason) => void
    /** Runs the next job after a settle; defaults to a macrotask so React can commit first. */
    defer?: (run: () => void) => void
}

interface Running {
    job: MoveJob
    settled: boolean
    answered: boolean
    awaiting: Set<string>
    timer?: ReturnType<typeof setTimeout>
}

export interface MoveQueue {
    /** "started" and "queued" took the factory; "skipped" means nothing could start; "full" refused it. */
    enqueue: (factory: JobFactory) => "started" | "queued" | "skipped" | "full"
    /** An authoritative patch for these inventories arrived. */
    patched: (ids: string[]) => void
    /** The server refused the job in flight out of band (a rejected event). */
    reject: (message: string) => void
    /** Forget everything without rolling back (session opened or closed). */
    reset: () => void
    readonly pending: boolean
    readonly waiting: number
}

export function createMoveQueue(options: MoveQueueOptions): MoveQueue {
    const defer = options.defer ?? ((run) => { setTimeout(run, 0) })
    let current: Running | undefined
    let waiting: JobFactory[] = []
    let generation = 0

    const notify = () => options.onPending?.(current !== undefined)

    function settle(run: Running, failure?: { message: string; reason: FailureReason }) {
        if (run.settled) return
        run.settled = true
        clearTimeout(run.timer)
        if (current === run) current = undefined
        if (failure) {
            try { run.job.rollback(failure.message, failure.reason) } catch (error) { console.error(error) }
        }
        notify()
        if (failure) options.onFailure?.(failure.message, failure.reason)
        if (waiting.length) {
            const mine = generation
            defer(() => { if (mine === generation && !current) startNext() })
        }
    }

    function complete(run: Running) {
        if (run.answered && run.awaiting.size === 0) settle(run)
    }

    function begin(job: MoveJob) {
        const run: Running = { job, settled: false, answered: false, awaiting: new Set(job.awaiting ?? []) }
        current = run
        if (job.timeoutMs && job.timeoutMs > 0) {
            run.timer = setTimeout(() => settle(run, { message: "Inventory did not respond", reason: "timeout" }), job.timeoutMs)
        }
        notify()
        let sent: Promise<MoveAnswer>
        try { sent = Promise.resolve(job.send()) } catch (error) { sent = Promise.reject(error) }
        sent.then((answer) => {
            if (run.settled) return
            if (!answer || answer.ok !== true) settle(run, { message: answer?.error ?? "Action rejected by inventory", reason: "rejected" })
            else {
                run.answered = true
                if (run.awaiting.size > 0) {
                    // The answer is final; only the confirming patches are missing. Bound the wait.
                    clearTimeout(run.timer)
                    const wait = job.confirmMs ?? job.timeoutMs
                    if (wait && wait > 0) {
                        run.timer = setTimeout(() => {
                            if (run.settled) return
                            settle(run)
                            options.onUnconfirmed?.()
                        }, wait)
                    }
                }
                complete(run)
            }
        }, () => settle(run, { message: "Inventory connection interrupted", reason: "error" }))
    }

    /** Starts the first waiting job that can run; jobs that cannot are dropped. */
    function startNext(first?: JobFactory): boolean {
        let factory = first ?? waiting.shift()
        while (factory) {
            let job: MoveJob | undefined
            try { job = factory() } catch (error) { console.error(error) }
            if (job) { begin(job); return true }
            factory = waiting.shift()
        }
        return false
    }

    return {
        enqueue(factory) {
            if (current) {
                if (waiting.length >= options.maxQueued) return "full"
                waiting.push(factory)
                return "queued"
            }
            return startNext(factory) ? "started" : "skipped"
        },
        patched(ids) {
            const run = current
            if (!run || run.settled) return
            for (const id of ids) run.awaiting.delete(id)
            complete(run)
        },
        reject(message) {
            if (current && !current.settled) settle(current, { message, reason: "rejected" })
        },
        reset() {
            generation++
            waiting = []
            if (current) { current.settled = true; clearTimeout(current.timer); current = undefined }
            notify()
        },
        get pending() { return current !== undefined },
        get waiting() { return waiting.length },
    }
}
