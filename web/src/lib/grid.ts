import { asSlots } from "./inventory"
import type { InventoryItem, InventoryView, SessionSnapshot } from "./types"

export function hasGrid(session: SessionSnapshot | null) {
    return Boolean(session?.player.gridColumns || session?.secondary?.gridColumns)
}

export function gridSize(item?: InventoryItem) {
    return {
        width: item?.gridWidth ?? item?.gridBaseWidth ?? 1,
        height: item?.gridHeight ?? item?.gridBaseHeight ?? 1,
    }
}

export function gridPlacementSize(item: InventoryItem, rotated = Boolean(item.gridRotated)) {
    const { width, height } = gridSize(item)
    const baseWidth = item.gridBaseWidth ?? (item.gridRotated ? height : width)
    const baseHeight = item.gridBaseHeight ?? (item.gridRotated ? width : height)
    return rotated ? { width: baseHeight, height: baseWidth } : { width: baseWidth, height: baseHeight }
}

export function gridPosition(slot: number, columns: number) {
    return { column: (slot - 1) % columns + 1, row: Math.floor((slot - 1) / columns) + 1 }
}

export function gridCells(slot: number, columns: number, slots: number, width: number, height: number) {
    const { column } = gridPosition(slot, columns)
    if (slot < 1 || column + width - 1 > columns || slot + (height - 1) * columns + width - 1 > slots) return []
    const cells: number[] = []
    for (let row = 0; row < height; row++) {
        for (let offset = 0; offset < width; offset++) cells.push(slot + row * columns + offset)
    }
    return cells
}

export function occupiedGridCells(inventory: InventoryView, items = asSlots(inventory.items)) {
    const occupied = new Map<number, number>()
    for (const item of items) {
        const { width, height } = gridSize(item)
        const cells = inventory.gridColumns ? gridCells(item.slot, inventory.gridColumns, inventory.slots, width, height) : [item.slot]
        for (const cell of cells) occupied.set(cell, item.slot)
    }
    return occupied
}

export interface GridDropPreview {
    cells: number[]
    status: "fit" | "edge" | "blocked"
}

export function gridDropFootprint(inventory: InventoryView, slot: number, { width, height }: ReturnType<typeof gridSize>, ignore: number[] = [], reserved: number[] = []): GridDropPreview {
    const columns = inventory.gridColumns!
    const { column } = gridPosition(slot, columns)
    const cells: number[] = []
    for (let row = 0; row < height; row++) {
        for (let offset = 0; offset < width && column + offset <= columns; offset++) {
            const cell = slot + row * columns + offset
            if (cell <= inventory.slots) cells.push(cell)
        }
    }
    if (cells.length !== width * height) return { cells, status: "edge" }
    const occupied = occupiedGridCells(inventory)
    const blocked = cells.some((cell) => {
        const anchor = occupied.get(cell)
        return reserved.includes(cell) || (anchor !== undefined && !ignore.includes(anchor))
    })
    return { cells, status: blocked ? "blocked" : "fit" }
}

export function firstEmptySlot(inventory: InventoryView, item: InventoryItem, items = asSlots(inventory.items)) {
    const occupied = occupiedGridCells(inventory, items)
    const { width, height } = gridPlacementSize(item)
    for (let slot = 1; slot <= inventory.slots; slot++) {
        const cells = inventory.gridColumns ? gridCells(slot, inventory.gridColumns, inventory.slots, width, height) : [slot]
        if (cells.length && cells.every((cell) => !occupied.has(cell))) return slot
    }
}
