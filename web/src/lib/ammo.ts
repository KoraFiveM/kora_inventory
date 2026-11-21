import type { AmmoInfoConfig, InventoryItem, RightClickMode } from "./types"

export const DEFAULT_AMMO_INFO: AmmoInfoConfig = { enabled: true, where: "both", showLoaded: true, showCompatible: true }

/** Merges a pushed `ammoInfo` onto the current value; anything malformed keeps what was there. */
export function mergeAmmoInfo(current: AmmoInfoConfig, pushed: Partial<AmmoInfoConfig> | undefined): AmmoInfoConfig {
    if (!pushed || typeof pushed !== "object") return current
    return {
        enabled: typeof pushed.enabled === "boolean" ? pushed.enabled : current.enabled,
        where: pushed.where === "inspector" || pushed.where === "menu" || pushed.where === "both" ? pushed.where : current.where,
        showLoaded: typeof pushed.showLoaded === "boolean" ? pushed.showLoaded : current.showLoaded,
        showCompatible: typeof pushed.showCompatible === "boolean" ? pushed.showCompatible : current.showCompatible,
    }
}

const typeOf = (value: unknown) => typeof value === "string" && value !== "" ? value : undefined

/** The ammo type a weapon takes, or the type an ammo item is; undefined for anything else. */
function ammoTypeOf(item: Pick<InventoryItem, "ammo" | "ammoType"> | undefined): { kind: "weapon" | "ammo"; type: string } | undefined {
    if (!item) return undefined
    const weapon = typeOf(item.ammo?.type)
    if (weapon) return { kind: "weapon", type: weapon }
    const ammo = typeOf(item.ammoType)
    return ammo ? { kind: "ammo", type: ammo } : undefined
}

/**
 * True when `candidate` is the other half of `selected`'s weapon/ammo pair: a
 * weapon whose ammo type is the selected ammo's, or ammo of the selected
 * weapon's type. Two weapons, two ammo items, or unrelated items never match.
 */
export function isAmmoCompatible(selected: Pick<InventoryItem, "ammo" | "ammoType"> | undefined, candidate: Pick<InventoryItem, "ammo" | "ammoType"> | undefined): boolean {
    const a = ammoTypeOf(selected)
    const b = ammoTypeOf(candidate)
    return Boolean(a && b && a.kind !== b.kind && a.type === b.type)
}

interface AmmoRow { key: "takes" | "loaded" | "rounds" | "fits"; label: string; value: string }

/** Rows for the "Ammo info" popover; empty when the item has nothing to show. */
export function ammoInfoRows(item: InventoryItem, config: AmmoInfoConfig, t: (key: string, values?: Record<string, string | number>) => string): AmmoRow[] {
    const rows: AmmoRow[] = []
    if (item.ammo && typeof item.ammo === "object") {
        const label = item.ammo.label || item.ammo.item
        rows.push({ key: "takes", label: t("ui.ammo_takes"), value: label && item.ammo.type ? `${label} (${item.ammo.type})` : label || item.ammo.type })
        if (config.showLoaded && Number.isFinite(item.ammo.loaded)) rows.push({ key: "loaded", label: t("ui.ammo_loaded"), value: t("ui.ammo_rounds_value", { count: Number(item.ammo.loaded) }) })
    } else if (item.ammoType) {
        rows.push({ key: "takes", label: t("ui.ammo_type"), value: item.ammoType })
        if (Number.isFinite(item.rounds)) rows.push({ key: "rounds", label: t("ui.ammo_rounds_per_item"), value: String(item.rounds) })
        if (config.showCompatible && Array.isArray(item.fits) && item.fits.length > 0) rows.push({ key: "fits", label: t("ui.ammo_fits"), value: item.fits.filter((fit) => typeof fit === "string").join(", ") })
    }
    return rows
}

/** The right-click mode: the pushed `rightClick`, else the legacy `rightClickSplit` boolean (true = split, false = none). */
export function resolveRightClick(pushed: { rightClick?: unknown; rightClickSplit?: unknown }, current: RightClickMode): RightClickMode {
    if (pushed.rightClick === "split" || pushed.rightClick === "menu" || pushed.rightClick === "none") return pushed.rightClick
    if (typeof pushed.rightClickSplit === "boolean") return pushed.rightClickSplit ? "split" : "none"
    return current
}
