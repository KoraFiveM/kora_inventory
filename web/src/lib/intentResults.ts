import type { MoveAnswer } from "./moveQueue"

/**
 * Pairs a request with the verdict the Lua bridge delivers later.
 *
 * With Config.kora_inventory.ui.directTransport the intent fetch is acknowledged
 * at once (`pending: true`) and the server's verdict follows as a
 * `kora_inventory:nui:intentResult` message carrying the request id. The verdict
 * can win the race against the fetch's own response, so one that arrives with
 * nobody waiting yet is kept (a small bounded set) and handed over on `wait`.
 */
export interface IntentResults {
    /** A verdict arrived from the bridge. */
    deliver: (requestId: number, answer: MoveAnswer) => void
    /** Resolves with the verdict for `requestId`, now if it already came. */
    wait: (requestId: number) => Promise<MoveAnswer>
    /** Drops every waiter and kept verdict (session opened or closed). */
    reset: () => void
}

const KEPT_LIMIT = 32

export function createIntentResults(): IntentResults {
    let waiting = new Map<number, (answer: MoveAnswer) => void>()
    let kept = new Map<number, MoveAnswer>()

    return {
        deliver(requestId, answer) {
            const resolve = waiting.get(requestId)
            if (resolve) {
                waiting.delete(requestId)
                resolve(answer)
                return
            }
            kept.set(requestId, answer)
            if (kept.size > KEPT_LIMIT) kept.delete(kept.keys().next().value as number)
        },
        wait(requestId) {
            const early = kept.get(requestId)
            if (early) {
                kept.delete(requestId)
                return Promise.resolve(early)
            }
            return new Promise<MoveAnswer>((resolve) => { waiting.set(requestId, resolve) })
        },
        reset() {
            waiting = new Map()
            kept = new Map()
        },
    }
}
