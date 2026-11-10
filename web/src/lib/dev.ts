import type { NuiWireMessage, SessionSnapshot } from "./types"

const sample: SessionSnapshot = {
    sessionId: "dev-session",
    token: "dev-token",
    revision: 4,
    player: {
        id: "player:dev", label: "Your pockets", type: "player", slots: 20, weight: 7850, maxWeight: 30000,
        items: [
            { slot: 1, name: "water", label: "Spring Water", amount: 3, weight: 500, description: "Clean and cold." },
            { slot: 2, name: "sandwich", label: "Sandwich", amount: 2, weight: 300, durability: 78 },
            { slot: 5, name: "radio", label: "Radio", amount: 1, weight: 900, stack: false },
        ],
    },
    secondary: {
        id: "stash:dev", label: "Shared locker", type: "stash", slots: 30, weight: 19000, maxWeight: 100000,
        items: [{ slot: 1, name: "bandage", label: "Bandage", amount: 8, weight: 100 }, { slot: 8, name: "pistol_ammo", label: "Pistol ammo", amount: 42, weight: 8 }],
    },
}

export function openDevHarness() {
    const post = <T,>(action: string, data: T) => window.postMessage({ action, data } satisfies NuiWireMessage<T>, "*")
    post("kora_inventory:nui:sessionOpened", sample)
}
