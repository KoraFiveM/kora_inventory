import { createContext } from "react"
import { DEFAULT_AMMO_INFO } from "@/lib/ammo"
import { DEFAULT_COMBINE, type CombineConfig } from "@/lib/combine"
import type { AmmoInfoConfig, ControlsConfig, OrganizeConfig, RightClickMode, TipsConfig, DecayConfig, UiConfig } from "@/lib/types"
import { DEFAULT_DECAY } from "@/lib/decay"

/**
 * Presentation config from `Config.kora_inventory.ui`, pushed on
 * `kora_inventory:nui:config`.
 *
 * The defaults here are what renders in the window between the UI mounting and
 * that message arriving (and in the dev harness, which sends no config at all),
 * so they mirror the shipped config rather than being "off".
 */
export const DEFAULT_UI_CONFIG: Required<Pick<UiConfig, "hotbarSlots" | "centreWhenSolo" | "showHotbar" | "scale" | "rightClickSplit" | "optimisticMoves" | "queueMoves" | "directTransport" | "moveTimeoutMs" | "inspectorDecimals" | "inspectorCopy" | "layout" | "playerLayoutChoice" | "quickTransfer" | "modifierDrag" | "quickAmounts" | "filters" | "tooltips">> & { weightWarnings: { enabled: boolean; warnAt: number; dangerAt: number } } & { images: NonNullable<UiConfig["images"]>; layouts: NonNullable<UiConfig["layouts"]>; rightClick: RightClickMode; ammoInfo: AmmoInfoConfig; organize: OrganizeConfig; tips: TipsConfig; controls: ControlsConfig; combine: CombineConfig; decay: DecayConfig } = {
    hotbarSlots: 5,
    centreWhenSolo: true,
    showHotbar: true,
    rightClickSplit: true,
    // Split dialog by default; `menu` and `none` come from ui.rightClick.
    rightClick: "split",
    ammoInfo: DEFAULT_AMMO_INFO,
    // Item decay is off until the server says otherwise (config.lua: decay.enabled).
    decay: DEFAULT_DECAY,
    optimisticMoves: true,
    queueMoves: true,
    directTransport: true,
    // A move that gets no answer would otherwise stay pending for good. Generous
    // because nothing blocks while it waits: a lag spike must not look like a
    // failure and snap the item back (config.lua: ui.moveTimeoutMs).
    moveTimeoutMs: 6000,
    inspectorDecimals: 1,
    inspectorCopy: true,
    scale: 1,
    // Layout registry (web/src/layouts): the server default, which layouts may
    // be used, and whether the player's own choice is honoured.
    layout: "classic",
    layouts: { classic: true, loadout: true, compact: true, dock: true },
    playerLayoutChoice: true,
    quickTransfer: true,
    modifierDrag: true,
    quickAmounts: true,
    filters: true,
    tooltips: true,
    weightWarnings: { enabled: true, warnAt: 0.75, dangerAt: 0.95 },
    // Config.kora_inventory.organize and ui.tips; the server enforces organize itself.
    organize: { enabled: true, sort: true, stack: true, panelSearch: true },
    tips: { enabled: true, maxShows: 5 },
    // Keyboard button for GTA's native controls overlay (Config.kora_inventory.ui.controls).
    controls: { button: true, defaultVisible: false },
    // Drag one item onto another for a recipe (Config.kora_inventory.combine).
    combine: DEFAULT_COMBINE,
    images: {
        localPath: "nui://kora_inventory/images",
        extensions: ["webp", "png", "gif", "jpg"],
    },
}

export type ResolvedUiConfig = typeof DEFAULT_UI_CONFIG

export const UiConfigContext = createContext<ResolvedUiConfig>(DEFAULT_UI_CONFIG)
