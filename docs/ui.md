---
title: UI
sidebar_position: 18
---

# UI and renderer contract

kora_inventory ships a React NUI (`web/`, built into `web/build/`, served by `ui_page`). The NUI is only a renderer: `server.lua` is the sole authority and contains no NUI call, callback, `SendNUIMessage` or focus call. `client/ui.lua` owns the NUI page and focus, accepts only these NUI intents (`close`, `move`, `use`, `drop`, `give`, `buy`, `sync`, `split`, `action`) and forwards them as a restricted envelope to the local event `kora_inventory:client:submitIntent`. `client.lua` attaches the current token and revisions before sending anything to the server.

Another renderer can replace it: use the client exports `openInventory`, `closeInventory`, `submitIntent`, `getCurrentSession` and listen to the `kora_inventory:ui:*` events (see [Events](./events.md)).

## Sessions

The client receives a short-lived token only after the server has resolved and authorised the target inventory. Every transfer checks the token, both revisions, slots, amount, server-side item data, routing bucket, access policy and distance immediately before the change. Viewers of a shared inventory get a revisioned replacement view after each change; stale actions are rejected, not merged. The lease is `sessionTtl` (idle timeout when `sessionSliding`).

## Using items from the UI and hotbar

Double-clicking a slot, the Use or Buy button and Enter on a selected item all run one `activateItem`. Number keys use slots `1..hotbarSlots` with the panel closed. Both go through `KoraInventory.useGate`, which runs the `useTime` progress bar before any request is sent.

## Presentation config (`Config.kora_inventory.ui`)

The only config sent to the browser (`kora_inventory:nui:config`, at start and on each session open). Nothing in it is authority.

| Key | Default | Effect |
| --- | --- | --- |
| `centreWhenSolo` | `true` | With no second inventory open, a compact centred player grid; the inspector slides out in a drawer. |
| `showHotbar` | `true` | Outline slots `1..hotbarSlots`. |
| `hotbarSeconds` | `5` | How long the on-screen hotbar stays after the show key; `0` disables the key. Live. |
| `scale` | `1.0` | Size multiplier for text and slots (0.5-2.0). Live. |
| `playerLayout` | `true` | Register the window with kora_hud's `/ui` editor so players can move, resize (75-125 %) and pick a side. Needs `kora_hud`. |
| `playerLayoutTransfer` | `false` | Default for "Use my position for stashes and trunks". |
| `rightClickSplit` | `true` | Right-click on a stack of two or more opens the split dialog. |
| `optimisticMoves` | `true` | Paint a move or purchase immediately and undo it if the server refuses or does not answer within `moveTimeoutMs`. The server validates every move either way. |
| `queueMoves` | `true` | With `optimisticMoves`, queue up to eight further drags while one is pending. |
| `directTransport` | `true` | Send requests as `kora_inventory:server:call` and receive `kora_inventory:client:callResult` instead of kora_lib callbacks. The `kora_inventory:server:transfer` and `intent` callbacks stay registered for third-party renderers. |
| `moveTimeoutMs` | `6000` | 500-60000. With `directTransport` off use about `1500`. |
| `moveTimeout` | unset | Legacy seconds form, only read when `moveTimeoutMs` is absent. |
| `images` | see [Items](./items.md) | Artwork resolution. |

`hotbarSlots` is sent alongside so the outline and the keys cannot disagree. Top-level `Config.Inspector`, `Config.Slots` and `Config.Hotbar` also style the UI. The inspector's text is selectable only when `Config.Inspector.allowCopy` is true; its Copy button copies the item as JSON.

## Item receipts and notifications

`itemBoxes` controls the receipt cards. `giveNotify` and `purchaseNotify` control toasts. Text is in `locales/en.json` (`inventory`, `vehicle_doors`, `shop_hints`).

## Rebuilding

See [Development](./development.md).
