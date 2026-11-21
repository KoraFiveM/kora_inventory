/** localStorage key holding whether the player left the controls overlay on. */
export const CONTROLS_STORAGE_KEY = "kora_inventory:controlsVisible"

type ControlsStorage = Pick<Storage, "getItem" | "setItem">

function defaultStorage(): ControlsStorage | undefined {
    try {
        return typeof window !== "undefined" ? window.localStorage : undefined
    } catch {
        return undefined
    }
}

/** The player's saved choice, or undefined when they have never used the button. */
export function loadControlsChoice(storage: ControlsStorage | undefined = defaultStorage()): boolean | undefined {
    try {
        const raw = storage?.getItem(CONTROLS_STORAGE_KEY)
        if (raw === "true") return true
        if (raw === "false") return false
    } catch {
        // Storage can be unavailable; the configured default then applies.
    }
    return undefined
}

export function saveControlsChoice(visible: boolean, storage: ControlsStorage | undefined = defaultStorage()): void {
    try {
        storage?.setItem(CONTROLS_STORAGE_KEY, String(visible))
    } catch {
        // Storage can be unavailable or full; the choice then lasts this session only.
    }
}

/** Whether the overlay should be on: no button means never, else the player's choice, else the default. */
export function controlsVisible(config: { button: boolean; defaultVisible: boolean }, choice: boolean | undefined): boolean {
    if (!config.button) return false
    return choice ?? config.defaultVisible
}
