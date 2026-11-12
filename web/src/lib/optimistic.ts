import type { InventoryItem, InventoryView, SessionPatch, SessionSnapshot } from "./types"

/**
 * Optimistic inventory moves.
 *
 * Everything here is a *prediction* of what the server is about to do, used
 * only to paint the drop immediately. The server never reads it and stays
 * authoritative: its patch replaces the predicted items, and a rejection or a
 * timeout restores the snapshot taken before the prediction. Whenever the
 * outcome is not certain from the data the browser holds (stack rules, weight
 * caps, partial swaps) `predictMove` returns undefined and the move simply
 * waits for the server as it always did.
 *
 * Every item a prediction creates or changes carries `pending: true`, which the
 * slot renders dimmed; the server's patch replaces the items and so clears it.
 */

export interface MoveRequest {
    fromInventory: string
    fromSlot: number
    toInventory: string
    toSlot: number
    amount: number
}

export interface Prediction {
    session: SessionSnapshot
    /** The untouched views of every inventory the prediction changed. */
    before: Map<string, InventoryView>
}

export function slotItems(items: InventoryView["items"] | undefined): InventoryItem[] {
    const values = Array.isArray(items) ? items : Object.values(items ?? {})
    return values.filter((item): item is InventoryItem =>
        item !== null && typeof item === "object" && Number.isInteger(item.slot) && item.slot > 0,
    )
}

const sameMetadata = (a: InventoryItem, b: InventoryItem) => JSON.stringify(a.metadata ?? {}) === JSON.stringify(b.metadata ?? {})

/** The server's stack rule: same name and metadata, and neither side unique or opted out. */
const stacks = (a: InventoryItem, b: InventoryItem) =>
    a.name === b.name && a.stack !== false && b.stack !== false && !a.unique && !b.unique && sameMetadata(a, b)

function totalWeight(items: InventoryItem[]) {
    return items.reduce((sum, item) => sum + (Number(item.weight) || 0) * item.amount, 0)
}

function view(source: InventoryView, items: InventoryItem[], weight: number): InventoryView {
    return { ...source, weight, items: items.sort((a, b) => a.slot - b.slot) }
}

export function predictMove(session: SessionSnapshot, request: MoveRequest): Prediction | undefined {
    const find = (id: string) => session.player.id === id ? session.player : session.secondary?.id === id ? session.secondary : undefined
    const from = find(request.fromInventory)
    const to = find(request.toInventory)
    if (!from || !to || from.type === "shop" || to.type === "shop") return undefined

    const { fromSlot, toSlot, amount } = request
    const slotOk = (inv: InventoryView, slot: number) => Number.isInteger(slot) && slot >= 1 && slot <= inv.slots
    if (!slotOk(from, fromSlot) || !slotOk(to, toSlot)) return undefined
    if (from.id === to.id && fromSlot === toSlot) return undefined

    const same = from.id === to.id
    const fromItems = slotItems(from.items).map((item) => ({ ...item }))
    const toItems = same ? fromItems : slotItems(to.items).map((item) => ({ ...item }))
    const source = fromItems.find((item) => item.slot === fromSlot)
    if (!source || !Number.isInteger(amount) || amount < 1 || amount > source.amount) return undefined
    const target = toItems.find((item) => item.slot === toSlot)

    // Cross-inventory weight is the one rejection the browser can compute, so
    // it is the one it refuses to guess about when the numbers are missing.
    const weightLeft = (inv: InventoryView, items: InventoryItem[]) => inv.maxWeight === undefined ? Infinity : inv.maxWeight - totalWeight(items)

    if (!target) {
        if (!same && (source.weight === undefined || (Number(source.weight) || 0) * amount > weightLeft(to, toItems))) return undefined
        const moved: InventoryItem = { ...source, slot: toSlot, amount, pending: true }
        if (amount === source.amount) fromItems.splice(fromItems.indexOf(source), 1)
        else source.amount -= amount
        toItems.push(moved)
    } else if (stacks(source, target)) {
        // The server has no stack cap; an item opting out of stacking, or a
        // unique one (weapons, serialled items), never merges.
        if (!same && (source.weight === undefined || (Number(source.weight) || 0) * amount > weightLeft(to, toItems))) return undefined
        target.amount += amount
        target.pending = true
        if (amount === source.amount) fromItems.splice(fromItems.indexOf(source), 1)
        else source.amount -= amount
    } else {
        // Occupied by something else: only a whole-stack swap is legal.
        if (amount !== source.amount) return undefined
        if (!same) {
            const fromAfter = totalWeight(fromItems) - (Number(source.weight) || 0) * source.amount + (Number(target.weight) || 0) * target.amount
            const toAfter = totalWeight(toItems) - (Number(target.weight) || 0) * target.amount + (Number(source.weight) || 0) * source.amount
            if (from.maxWeight !== undefined && fromAfter > from.maxWeight) return undefined
            if (to.maxWeight !== undefined && toAfter > to.maxWeight) return undefined
        }
        source.slot = toSlot
        target.slot = fromSlot
        source.pending = true
        target.pending = true
        if (!same) {
            fromItems.splice(fromItems.indexOf(source), 1, target)
            toItems.splice(toItems.indexOf(target), 1, source)
        }
    }

    const nextFrom = view(from, fromItems, same ? (from.weight ?? totalWeight(fromItems)) : totalWeight(fromItems))
    const nextTo = same ? nextFrom : view(to, toItems, totalWeight(toItems))
    const replace = (inv: InventoryView) => inv.id === nextFrom.id ? nextFrom : inv.id === nextTo.id ? nextTo : inv
    const before = new Map<string, InventoryView>([[from.id, from], [to.id, to]])
    return {
        session: { ...session, player: replace(session.player), secondary: session.secondary && replace(session.secondary) },
        before,
    }
}

/** Ids whose item list an authoritative patch has just replaced. */
export function refreshedInventories(patch: SessionPatch): string[] {
    if (patch.snapshot) return [patch.snapshot.player.id, patch.snapshot.secondary?.id].filter((id): id is string => Boolean(id))
    const ids: string[] = []
    if (patch.player?.id && patch.player.items !== undefined) ids.push(patch.player.id)
    if (patch.secondary?.id && patch.secondary.items !== undefined) ids.push(patch.secondary.id)
    return ids
}

/** Puts back the pre-prediction views, leaving anything the server refreshed since alone. */
export function restoreInventories(session: SessionSnapshot, before: Map<string, InventoryView>): SessionSnapshot {
    const pick = (inv: InventoryView) => before.get(inv.id) ?? inv
    return { ...session, player: pick(session.player), secondary: session.secondary && pick(session.secondary) }
}

export interface BuyRequest {
    shopInventory: string
    slot: number
    amount: number
}

/**
 * A shop purchase as the server will commit it: the stock row loses `amount`
 * and the player gets the item on a matching stack, or the first free slot.
 * Price and funds stay the server's call -- the browser holds no balance -- so
 * a purchase it cannot afford is painted and then undone with the server's
 * reason. Returns undefined whenever the outcome is not certain from what the
 * browser holds (unknown weight, over weight, no room, a unique multi-buy).
 */
export function predictBuy(session: SessionSnapshot, request: BuyRequest): Prediction | undefined {
    const shop = session.secondary
    const player = session.player
    if (!shop || shop.type !== "shop" || shop.id !== request.shopInventory) return undefined

    const shopItems = slotItems(shop.items).map((item) => ({ ...item }))
    const stock = shopItems.find((item) => item.slot === request.slot)
    const { amount } = request
    if (!stock || !Number.isInteger(amount) || amount < 1 || amount > stock.amount) return undefined
    if (stock.weight === undefined || (stock.unique && amount > 1)) return undefined

    const playerItems = slotItems(player.items).map((item) => ({ ...item }))
    if (player.maxWeight !== undefined && totalWeight(playerItems) + (Number(stock.weight) || 0) * amount > player.maxWeight) return undefined

    const bought: InventoryItem = { ...stock, slot: 0, amount, pending: true }
    delete bought.price
    const stack = playerItems.find((item) => stacks(item, bought))
    if (stack) {
        stack.amount += amount
        stack.pending = true
    } else {
        let free = 1
        const taken = new Set(playerItems.map((item) => item.slot))
        while (taken.has(free)) free++
        if (free > player.slots) return undefined
        bought.slot = free
        playerItems.push(bought)
    }

    if (amount === stock.amount) shopItems.splice(shopItems.indexOf(stock), 1)
    else stock.amount -= amount

    const nextPlayer = view(player, playerItems, totalWeight(playerItems))
    const nextShop = view(shop, shopItems, shop.weight ?? 0)
    return {
        session: { ...session, player: nextPlayer, secondary: nextShop },
        before: new Map<string, InventoryView>([[player.id, player], [shop.id, shop]]),
    }
}
