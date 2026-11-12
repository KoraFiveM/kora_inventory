---
title: "NUI contract"
sidebar_position: 20
---


# NUI contract

The bundled inventory page is a renderer only. `client/ui.lua` translates the local session events into NUI messages and turns the page's two callbacks back into client intents. This page documents that wire contract for anyone replacing or extending the UI; the internal components are not documented.

Namespace: `NUI` · Source: `client/ui.lua, web/src/lib/types.ts, web/src/lib/nui.ts, web/src/App.tsx`

## How it works

Messages are sent with `SendNUIMessage({ action, data })` and received in the page by action name. The page POSTs to `https://kora_inventory/kora_inventory:nui:intent` and `.../kora_inventory:nui:close`. With `directTransport` on and a `requestId` in the request, the callback is acknowledged immediately (`{ ok = true, pending = true, requestId }`) and the server's verdict arrives later as the message `kora_inventory:nui:intentResult`; otherwise the callback blocks until the verdict or the move timeout. `use` is exempt from the timeout because it may wait on a progress bar. NUI focus is taken when a session opens and released when it closes.

## Message flow

1. **Session opens** — The bridge pushes the theme tokens, then `kora_inventory:nui:config`, then `kora_inventory:nui:sessionOpened`, and takes NUI focus.
2. **Player acts** — The page posts `kora_inventory:nui:intent` with the session id, token, intent and payload (and a `requestId` for direct transport).
3. **Server answers** — Patches arrive as `kora_inventory:nui:sessionPatched`; the verdict arrives as the callback result or `kora_inventory:nui:intentResult`.
4. **Session closes** — `kora_inventory:nui:sessionClosed` is sent and focus is released.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| sessionId | Equals the session token in the bundled bridge. A mismatch is refused as `invalid intent`. |
| requestId | A number chosen by the page so a deferred verdict can be matched to its request. |
| Optimistic move | The page paints a move before the server answers and rolls it back if refused or unanswered. |

## Messages sent to the page

Each is `{ action, data }`. Items in views are keyed by slot and include `label`, `weight`, `description`, `image`, `imageUrl`, `useable`, `useTime`, `preventClose`, `unique`, `container`, `displayMeta` and `info`/`metadata`.

| Option | Type | Description |
| --- | --- | --- |
| `kora_inventory:nui:config` | table | `{ hotbarSlots, centreWhenSolo, showHotbar, rightClickSplit, optimisticMoves, queueMoves, moveTimeoutMs, directTransport, scale, images, inspectorDecimals, inspectorCopy, slotBorderWidth }`, derived from `Config.kora_inventory.ui`, `Config.Inspector` and `Config.Slots`. Pushed on resource start and on every session open. |
| `kora_inventory:nui:sessionOpened` | table | `{ sessionId, token, revision, secondaryRevision, player, secondary?, expires }`. `player` and `secondary` are views `{ id (the inventory key), key, type, label, slots, maxWeight, weight, revision, items, stock? }`. |
| `kora_inventory:nui:sessionPatched` | table | `{ sessionId, revision?, secondaryRevision?, player?, secondary?, snapshot? }`: the changed view replaces the page's copy. |
| `kora_inventory:nui:sessionClosed` | table | `{ sessionId, reason }`. |
| `kora_inventory:nui:intentResult` | table | `{ requestId, ok, error? }`: the deferred verdict of an intent. |
| `kora_inventory:nui:itemBox` | table | Item receipt `{ name, label, image, imageUrl, amount, action, imageOverride, duration }` with `action` `add`, `purchase`, `remove` or `use`. |
| `kora_inventory:nui:giveAvailability` | table | `{ available }`: whether a nearby give recipient exists. No names or ids are ever sent. |
| `kora_inventory:nui:hotbar` | table | `{ slots, seconds, bottom }` for the on-screen hotbar overlay (U key). `slots[i]` is `{ slot, name?, label?, amount?, image?, imageUrl? }`. |
| `kora_inventory:nui:hotbarPosition` | table | `{ bottom }` pixels from the screen bottom; resent when the player enters or leaves a vehicle. |
| `kora_inventory:nui:rejected` | table | Listened to by the page (`{ reason }`) but not sent by the bundled bridge, which shows refusals through `Kora.notify` instead. |

## Functions

The two entries below are the NUI callbacks. The messages sent to the page are listed under Messages.

### `RegisterNUICallback('kora_inventory:nui:intent', function(data, cb) end)`

The only way the page changes anything. Validates the envelope, calls `submitIntent` with `announce = false` and answers with the verdict.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table | `{ sessionId, token, intent, payload, requestId? }`. `intent` must be one of `close`, `move`, `use`, `drop`, `give`, `buy`, `sync`, `split`, `action`; `payload` must be a table. (`action` and unknown shapes are then refused by the transport as `unsupported intent`.) |

**Returns**

- **cb(&#123; ok, error? &#125;)**
- **With direct transport and a `requestId`: `cb({ ok = true, pending = true, requestId })` first, then the verdict message. Invalid envelopes answer `{ ok = false, error = 'invalid intent' }`. An unanswered non-`use` request answers `timeout` after `moveTimeoutMs`.**

**Example**

```lua
// page side (TypeScript)
const response = await fetch('https://kora_inventory/kora_inventory:nui:intent', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json; charset=UTF-8' },
  body: JSON.stringify({ sessionId, token, intent: 'move', requestId: 4,
    payload: { fromInventory: 'player:12', fromSlot: 3, toInventory: 'stash:pd_armoury', toSlot: 5, amount: 1 } }),
})
```

**Representative console output**

```text
{ ok: true, pending: true, requestId: 4 } followed by the message kora_inventory:nui:intentResult { requestId: 4, ok: true }
```

### `RegisterNUICallback('kora_inventory:nui:close', function(data, cb) end)`

The page asks to close. Forwarded as a `close` intent when the session id and token match.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table | `{ sessionId, token }`. |

**Returns**

- **cb(&#123; ok = true &#125;) always.**

**Example**

```lua
await fetch('https://kora_inventory/kora_inventory:nui:close', { method: 'POST', body: JSON.stringify({ sessionId, token }) })
```

**Representative console output**

```text
{ ok: true }
```

## Common use cases

- Replacing the bundled UI with a custom page.
- Understanding what the page may and may not do.

## Limits and related APIs

The page can only send the nine allowed intents. It never receives other players' names or ids and cannot mutate state: every verdict comes from the server. Presentation settings are pushed one way and never read back. The `kora_inventory:nui:rejected` message is accepted by the bundled page but not emitted by the bundled bridge.

## Related guides

- [Client API](./client-api.md)
- [Events and callbacks](./events.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

kora_inventory ships a React NUI (`web/`, built into `web/build/`, served by `ui_page`). The NUI is only a renderer: `server.lua` is the sole authority and contains no NUI call, callback, `SendNUIMessage` or focus call. `client/ui.lua` owns the NUI page and focus, accepts only these NUI intents (`close`, `move`, `use`, `drop`, `give`, `buy`, `sync`, `split`, `action`) and forwards them as a restricted envelope to the local event `kora_inventory:client:submitIntent`. `client.lua` attaches the current token and revisions before sending anything to the server.

Another renderer can replace it: use the client exports `openInventory`, `closeInventory`, `submitIntent`, `getCurrentSession` and listen to the `kora_inventory:ui:*` events (see [Events](./events.md)).

### Sessions

The client receives a short-lived token only after the server has resolved and authorised the target inventory. Every transfer checks the token, both revisions, slots, amount, server-side item data, routing bucket, access policy and distance immediately before the change. Viewers of a shared inventory get a revisioned replacement view after each change; stale actions are rejected, not merged. The lease is `sessionTtl` (idle timeout when `sessionSliding`).

### Using items from the UI and hotbar

Double-clicking a slot, the Use or Buy button and Enter on a selected item all run one `activateItem`. Number keys use slots `1..hotbarSlots` with the panel closed. Both go through `KoraInventory.useGate`, which runs the `useTime` progress bar before any request is sent.

### Presentation config (`Config.kora_inventory.ui`)

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

### Item receipts and notifications

`itemBoxes` controls the receipt cards. `giveNotify` and `purchaseNotify` control toasts. Text is in `locales/en.json` (`inventory`, `vehicle_doors`, `shop_hints`).

### Rebuilding

See [Development](../development.md).
