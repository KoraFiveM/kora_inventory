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

1. **Resource starts** — The client waits two seconds for the React page to mount, then sends `kora_inventory:nui:locales` with strings resolved through `Kora.lang()`.
2. **Session opens** — The bridge pushes the theme tokens, then `kora_inventory:nui:config`, then `kora_inventory:nui:sessionOpened`, and takes NUI focus.
3. **Player acts** — The page posts `kora_inventory:nui:intent` with the session id, token, intent and payload (and a `requestId` for direct transport).
4. **Server answers** — Patches arrive as `kora_inventory:nui:sessionPatched`; the verdict arrives as the callback result or `kora_inventory:nui:intentResult`.
5. **Session closes** — `kora_inventory:nui:sessionClosed` is sent and focus is released.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| sessionId | Equals the session token in the bundled bridge. A mismatch is refused as `invalid intent`. |
| requestId | A number chosen by the page so a deferred verdict can be matched to its request. |
| Optimistic move | The page paints a move before the server answers and rolls it back if refused or unanswered. |

## Messages sent to the page

Each is `{ action, data }`. Items in views are keyed by slot and include `label`, `weight`, `description`, `image`, `imageUrl`, `useable`, `useTime`, `preventClose`, `unique`, `container`, `displayMeta` and `info`/`metadata`.

When `Config.kora_inventory.weapons.ammoInfo.enabled` is on, views (including shop stock) may also carry these server-computed, view-only fields:

| Field | Type | Description |
| --- | --- | --- |
| `ammo` | table | Weapons with an ammotype only: `type` (string), `item` (string), `label` (string) and `loaded` (integer, omitted when `showLoaded` is false). |
| `ammoType` | string | Ammo items only. |
| `rounds` | integer | Ammo items only: rounds per item. |
| `fits` | array of string | Ammo items only, when `showCompatible` is on and a weapon matches: sorted weapon labels, at most 12, plus a final "+N more" entry. |

When `Config.kora_inventory.decay.enabled` is on, items that decay also carry one more server-computed, view-only field (never stored, recomputed on every view, never accepted from the page). Shop stock never carries it.

| Field | Type | Description |
| --- | --- | --- |
| `decay` | table | `{ remaining, fraction }`: whole seconds of life left and the share of the item's lifetime left, 0 to 1. Sent when `decay.showOnSlot` or `decay.showInInspector` is on. With `showInInspector` the item's `displayMeta` also gets a row `{ key = 'decayRemaining', label = 'Expires in', value = '1h 20m' }`. The page draws a freshness bar on the slot (`--warning` below `decay.warnBelow`, `--destructive` below 10%) whose tooltip reads "Expires in 1h 20m". |

| Option | Type | Description |
| --- | --- | --- |
| `kora_inventory:nui:config` | table | `{ ammoInfo, hotbarSlots, centreWhenSolo, showHotbar, rightClickSplit, rightClick, optimisticMoves, queueMoves, moveTimeoutMs, directTransport, scale, images, inspectorDecimals, inspectorCopy, slotBorderWidth, layout, layouts, playerLayoutChoice, quickTransfer, modifierDrag, quickAmounts, filters, tooltips, weightWarnings, organize, tips, combine, decay }`, derived from `Config.kora_inventory.ui`, `Config.kora_inventory.organize`, `Config.Inspector`, `Config.Slots` and `Config.kora_inventory.weapons.ammoInfo`. `ammoInfo` is `{ enabled, where, showLoaded, showCompatible }` (booleans, and `where` as `inspector`, `menu` or `both`), a presentation hint only. `decay` is `{ enabled, showOnSlot, warnBelow }` from `Config.kora_inventory.decay`, also presentation only. Pushed on resource start and on every session open. |
| `kora_inventory:nui:layout` | table | The player's window placement from kora_hud's `/ui` editor: `{ x, y, scale, placed, playerSide, useForTransfer, layout? }`. Offsets and scale are clamped. `layout` is the player's chosen inventory layout, one of `classic`, `loadout`, `compact`, `dock`; any other value is dropped, and the page also checks it against the allowed set. Pushed when the editor applies or resets the layout and on every session open. |
| `kora_inventory:nui:locales` | table | Flat key/value map for the React UI, resolved on the client with `Kora.lang()` from `locales/en.lua`. Pushed two seconds after the client resource starts so the page's message listener is ready. |
| `kora_inventory:nui:sessionOpened` | table | `{ sessionId, token, revision, secondaryRevision, player, secondary?, expires }`. `player` and `secondary` are views `{ id (the inventory key), key, type, label, slots, maxWeight, weight, revision, items, stock? }`. |
| `kora_inventory:nui:sessionPatched` | table | `{ sessionId, revision?, secondaryRevision?, player?, secondary?, snapshot? }`: the changed view replaces the page's copy. |
| `kora_inventory:nui:sessionClosed` | table | `{ sessionId, reason }`. |
| `kora_inventory:nui:auditOpen` | table | `{ filter }` with optional `player`, `item`, `resource`, `range`. Opens the read-only `/invaudit` overlay (not a session). |
| `kora_inventory:nui:auditClose` | table | Closes the audit overlay. |
| `kora_inventory:nui:intentResult` | table | `{ requestId, ok, error? }`: the deferred verdict of an intent. |
| `kora_inventory:nui:itemBox` | table | Item receipt `{ name, label, image, imageUrl, amount, action, imageOverride, duration }` with `action` `add`, `purchase`, `remove` or `use`. |
| `kora_inventory:nui:giveAvailability` | table | `{ available }`: whether a nearby give recipient exists. No names or ids are ever sent. |
| `kora_inventory:nui:hotbar` | table | `{ slots, seconds, bottom }` for the on-screen hotbar overlay (U key). `slots[i]` is `{ slot, name?, label?, amount?, image?, imageUrl? }`. When `quickSlots.inHotbarHud` is on the payload also carries `quick`, the resolved quick slots that have an item: `{ id, slotLabel, slot, name, label, amount, total?, key, pinned, image?, imageUrl? }`, where `label` is the item's label, `slotLabel` the quick slot's label and `amount` the total for linked ammunition. |
| `kora_inventory:nui:quickSlots` | table | `{ enabled, hideWhenMissing, showKeyHints, drawer, slots }`. `drawer` is `{ startCollapsed }` (from `quickSlots.drawer.startCollapsed`): whether the side drawer opens collapsed until the player toggles it. `slots` is `slots` the resolved quick slot list in config order: `{ id, label, slot, name, total, pinned, key, linked }`. `slot` and `name` are nil when nothing resolves; `slot` is a real inventory slot (the page reads the item from its own copy of the player view). `total` is only set for linked ammunition. `pinned` is true when a local pin chose the item. `key` is the key label currently bound in Settings, Key Bindings (`''` when unbound). `linked` marks slots that cannot be pinned. Sent on every session open and again when the items, the drawn weapon or a pin change and the result differs. With `quickSlots.enabled = false` the only message is `{ enabled = false }`, sent once after start. |
| `kora_inventory:nui:hotbarPosition` | table | `{ bottom }` pixels from the screen bottom; resent when the player enters or leaves a vehicle. |
| `kora_inventory:nui:rejected` | table | Listened to by the page (`{ reason }`) but not sent by the bundled bridge, which shows refusals through `Kora.notify` instead. |

## Functions

The two entries below are the NUI callbacks. The messages sent to the page are listed under Messages.

### `RegisterNUICallback('kora_inventory:nui:intent', function(data, cb) end)`

The only way the page changes anything. Validates the envelope, calls `submitIntent` with `announce = false` and answers with the verdict.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table | `{ sessionId, token, intent, payload, requestId? }`. `intent` must be one of `close`, `move`, `use`, `drop`, `give`, `buy`, `sync`, `organize`, `combine`, `split`, `action`; `payload` must be a table. (`action` and unknown shapes are then refused by the transport as `unsupported intent`.) |

**Returns**

- **cb(&#123; ok, error? &#125;)**
- **With direct transport and a `requestId`: `cb({ ok = true, pending = true, requestId })` first, then the verdict message. Invalid envelopes answer `{ ok = false, error = 'invalid intent' }`. An unanswered request other than `use` and `combine` answers `timeout` after `moveTimeoutMs`.**

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

### `RegisterNUICallback('kora_inventory:pinQuickSlot', function(data, cb) end)`

The page asks to pin an item to a quick slot, or to clear the pin. This is a local display preference: it is answered on the client, stored in client key-value storage for the current character and never forwarded to the server. Registered only while `quickSlots.enabled` is not `false`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `data` | table | `{ id, slot }`. `id` must be a configured quick slot that is not linked. `slot` is an integer from `1` to `playerSlots` holding an item that matches that quick slot's filter; `nil` or `0` removes the pin. |

**Returns**

- **cb(&#123; ok = true &#125;)** after storing the pin and re-sending `kora_inventory:nui:quickSlots`.
- **cb(&#123; ok = false, error = reason &#125;)** for an unknown or linked id, an invalid slot, an empty slot, an item that does not fit, or no active character.

**Example**

```lua
await fetch('https://kora_inventory/kora_inventory:pinQuickSlot', { method: 'POST', body: JSON.stringify({ id: 'weapon', slot: 7 }) })
```

**Representative console output**

```text
{ ok: true }
```

## Common use cases

- Replacing the bundled UI with a custom page.
- Understanding what the page may and may not do.

## Limits and related APIs

The page can only send the ten allowed intents (the quick slot pin is a separate local callback that never reaches the server). It never receives other players' names or ids and cannot mutate state: every verdict comes from the server. Presentation settings are pushed one way and never read back. The `kora_inventory:nui:rejected` message is accepted by the bundled page but not emitted by the bundled bridge.

## Related guides

- [Client API](./client-api.md)
- [Events and callbacks](./events.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

kora_inventory ships a React NUI (`web/`, built into `web/build/`, served by `ui_page`). The NUI is only a renderer: `server.lua` is the sole authority and contains no NUI call, callback, `SendNUIMessage` or focus call. `client/ui.lua` owns the NUI page and focus, accepts only these NUI intents (`close`, `move`, `use`, `drop`, `give`, `buy`, `sync`, `organize`, `split`, `action`) and forwards them as a restricted envelope to the local event `kora_inventory:client:submitIntent`. `client.lua` attaches the current token and revisions before sending anything to the server.

Another renderer can replace it: use the client exports `openInventory`, `closeInventory`, `submitIntent`, `getCurrentSession` and listen to the `kora_inventory:ui:*` events (see [Events](./events.md)).

### Sessions

The client receives a short-lived token only after the server has resolved and authorised the target inventory. Every transfer checks the token, both revisions, slots, amount, server-side item data, routing bucket, access policy and distance immediately before the change. Viewers of a shared inventory get a revisioned replacement view after each change; stale actions are rejected, not merged. The lease is `sessionTtl` (idle timeout when `sessionSliding`).

### Using items from the UI and hotbar

Double-clicking a slot, the Use or Buy button and Enter on a selected item all run one `activateItem`. Number keys use slots `1..hotbarSlots` with the panel closed. Both go through `KoraInventory.useGate`, which runs the `useTime` progress bar before any request is sent.

### Combining items (the `combine` intent)

Dropping one item onto a different item in the player's own inventory asks "Combine / Cancel" when the pushed `combine` list pairs the two names; otherwise the drop is an ordinary move. Choosing Combine sends:

```lua
{ sessionId = ..., token = ..., intent = 'combine', requestId = 9,
  payload = { inventory = 'player:12', fromSlot = 1, toSlot = 2, revision = 41 } }
```

The page names no recipe, item, amount or result. The server validates the session lease, the revision, access, cuffed and downed state and the busy-slot lock exactly as for `use`, re-reads both slots, takes the recipe from its own registry and answers with the verdict. Like `use`, it may wait on a progress bar, so the bridge does not apply `moveTimeoutMs` to it. The page pushes the presentation list inside `kora_inventory:nui:config` as `combine = { enabled, recipes = { { a, b, label } } }`: item names and label only, no amounts. See [Crafting](./crafting.md#combining-items-by-dragging).

### Admin audit overlay and omnipack

The `/invaudit` overlay (`web/src/components/AuditViewer.tsx`, bridge in `client/admin_ui.lua`) is a separate component, not an inventory session: it has no token, lease or inventory and shares only NUI focus handling with `client/ui.lua` (`KoraInventory.ui.focus`). The server opens it with the net event `kora_inventory:client:auditOpen` after checking the audit ACE. The page posts filters to `kora_inventory:audit:query`; the client forwards them to the server callback `kora_inventory:server:auditQuery`, which re-checks the ACE on every request and returns a page of 100 rows plus a last-hour summary. `kora_inventory:audit:close` releases focus. It is read-only and refused while an inventory session holds the focus.

The omnipack is an ordinary shop session; its view carries `omnipack = true`, is sent once on open (no `stock` copy), and the panel adds its own search box and draws 120 matches at a time with a "Show more" button, keeping each item's real slot number. Takes use the normal `buy` intent.

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
| `layout` | `'classic'` | Server default layout: `classic`, `loadout`, `compact` or `dock`. Unknown values are sent as `classic`. |
| `layouts` | all `true` | Which layouts may be used. Sent as booleans only; if none is enabled, `classic` stays enabled. |
| `playerLayoutChoice` | `true` | Add an "Inventory layout" select to the `/ui` editor and honour the player's choice. Needs `playerLayout` and `kora_hud`. |
| `rightClickSplit` | `true` | Legacy boolean for `rightClick`: `true` is `split`, `false` is `none`. Only used when `rightClick` is absent or invalid. |
| `rightClick` | `'split'` | `split` (the split dialog on a stack of two or more), `menu` (the item context menu, see below) or `none`. Invalid values fall back to `rightClickSplit`. |
| `quickTransfer` | `true` | Shift+click moves a whole stack to the other open inventory (a buy of one from a shop). |
| `modifierDrag` | `true` | Ctrl+drag moves half a stack, Alt+drag moves one. |
| `quickAmounts` | `true` | Preset amount buttons beside the inspector's amount slider. |
| `filters` | `true` | Category chips (All, Weapons, Ammo, Consumables, Other) that dim non-matching slots; the search box dims in the player panel. |
| `weightWarnings` | `{ enabled = true, warnAt = 0.75, dangerAt = 0.95 }` | Weight bar turns warning-coloured and then destructive near capacity. |
| `tooltips` | `true` | Hover tooltip on filled slots. |
| `organize` | `{ enabled = true, sort = true, stack = true, panelSearch = true }` | Which of the per-panel Sort and Stack all buttons and the panel search box to draw. `sort` and `stack` are already combined with `enabled`. Presentation only: the server enforces `organize.*` itself. |
| `tips` | `{ enabled = true, maxShows = 5 }` | The first-time tip card: shown on at most `maxShows` openings (1 to 50). |
| `optimisticMoves` | `true` | Paint a move or purchase immediately and undo it if the server refuses or does not answer within `moveTimeoutMs`. The server validates every move either way. |
| `queueMoves` | `true` | With `optimisticMoves`, queue up to eight further drags while one is pending. |
| `directTransport` | `true` | Send requests as `kora_inventory:server:call` and receive `kora_inventory:client:callResult` instead of kora_lib callbacks. The `kora_inventory:server:transfer` and `intent` callbacks stay registered for third-party renderers. |
| `moveTimeoutMs` | `6000` | 500-60000. With `directTransport` off use about `1500`. |
| `moveTimeout` | unset | Legacy seconds form, only read when `moveTimeoutMs` is absent. |
| `images` | see [Items](./items.md) | Artwork resolution. |

`hotbarSlots` is sent alongside so the outline and the keys cannot disagree. Top-level `Config.Inspector`, `Config.Slots` and `Config.Hotbar` also style the UI. The inspector's text is selectable only when `Config.Inspector.allowCopy` is true; its Copy button copies the item as JSON.

### The `organize` intent

Sort and Stack all send `{ intent = 'organize', payload = { inventory = '<id the session granted>', mode = 'sort' | 'stack', revision = <player revision>, secondaryRevision = <second panel revision> } }`. Only the inventory id, the mode and the two revisions the page is looking at travel; the server plans the result from its own state and answers with the usual verdict (`ok`, or an error such as `stale inventory`, `organizing too quickly` or `shop inventories cannot be organized`). The refreshed inventory arrives as an ordinary `kora_inventory:nui:sessionPatched` message, and a request that changes nothing still re-sends the panel so the page is never left waiting. Validation is described under [organizing a panel](./inventories.md#organizing-a-panel-the-organize-intent).

### First-time tips

When `ui.tips.enabled` is on, the page shows a small card at the bottom of the window on at most `ui.tips.maxShows` openings. It only offers tips for features that are enabled in the pushed config (`quickTransfer`, `modifierDrag`, `rightClick`, the quick slots message, `organize`, and `playerLayoutChoice` with more than one allowed layout), cycles with Next, and hides for good with Got it. Progress is kept in the browser's `localStorage` key `kora_inventory:tips` as `{ seen: string[], dismissed: boolean, opens: number }` (`opens` counts the openings used against `maxShows`). Nothing about tips is sent to the server.

### Weapon and ammo highlight

When `ammoInfo.enabled` is on and the selected item is a weapon with an `ammo.type`, every slot (in the player and the secondary inventory) holding ammo whose `ammoType` is the same gets the `slot-compatible` class, a subtle ring in the accent colour. Selecting an ammo item highlights the weapons whose `ammo.type` matches its `ammoType`. Two weapons, two ammo items and unrelated items are never highlighted. The match is pure view logic over the server-computed fields; it changes nothing.

### Right-click item menu

With `ui.rightClick = 'menu'`, right-clicking an item opens a small menu at the cursor instead of the split dialog. It is clamped to stay on screen and closes on Escape (which does not close the inventory), on a click outside it, and whenever the server patches the session. It lists only the entries that apply to the item:

| Entry | Shown when |
| --- | --- |
| Use | The item is useable (or a container) and in the player's inventory. |
| Split | The stack has 2 or more and is not in a shop. Opens the normal split dialog. |
| Drop | The item is in the player's inventory. Drops the whole stack, like dragging it out of the window. |
| Give | As Drop, and only while a player to give to is available. Gives the whole stack. |
| Ammo info | The item has `ammo` or `ammoType`, `ammoInfo.enabled` is on and `ammoInfo.where` is `menu` or `both`. Shows what a weapon takes and has loaded, or an ammo item's type, rounds per item and the weapons it fits (each row follows `showLoaded` and `showCompatible`). |
| Copy | `Config.Inspector.allowCopy` is on. |

Every entry sends the same intent the inspector buttons send; the server validates it exactly as before.

### Quick slots in the page

Quick slots are shortcuts to real items in the player's inventory, never slots of their own. The Lua client sends `kora_inventory:nui:quickSlots` with `{ enabled, hideWhenMissing, showKeyHints, slots }`, where each slot is `{ id, label, slot, name, total, pinned, key, linked }`. `slot` is the real player slot the shortcut points at (null when unresolved), `total` is set for linked ammo, `key` is the bound key label or an empty string, and `linked` marks the ammo slot, which cannot be pinned. A message with `enabled = false` hides everything.

The page draws a strip next to the player's grid (a vertical strip in the classic layout, including the compact personal view and the transfer view). Each tile shows the real item's artwork, the quick slot label, the stack amount (or the ammo total), a key badge when `showKeyHints` is on and a key is bound, and a pin icon when pinned. A tile whose slot is empty, or now holds a different item than `name`, counts as missing. With `hideWhenMissing` (default) missing tiles are not drawn and the whole strip disappears when none is left; otherwise they are greyed placeholders with the label.

| Gesture | Result |
| --- | --- |
| Click a tile | Selects the real item, like clicking its slot, and pulses that slot in the grid (`slot-flash`). |
| Double-click a tile | Uses the real item. |
| Drag from a tile | Drags the real item: drop it on a grid slot to move it, or outside the window to drop it. |
| Drag an item from the player's inventory onto a tile | Pins that item with the `kora_inventory:pinQuickSlot` callback. Linked (ammo) tiles refuse the drop. |
| Right-click a pinned tile | Unpins it. |

Tiles respect the same busy state as the grid. A failed pin shows the refusal in the notice bar.

`kora_inventory:pinQuickSlot` receives `{ id, slot }` (`slot` null or 0 unpins) and answers `{ ok = true }` or `{ ok = false, error }`. Pins are a local display preference stored by the client; they are not sent to the server and never change inventory data.

The on-screen hotbar payload (`kora_inventory:nui:hotbar`) may carry `quick`, a list of `{ id, slotLabel, slot, name, label, amount, total, key, pinned, image, imageUrl }`. The page draws these after the numbered slots, behind a divider, with their key hint; a payload without `quick` renders as before.

### Layouts

The window is rendered by one of several layouts, chosen by the page from the pushed config and the player's `kora_inventory:nui:layout` message. The rule, in order: the player's layout if `playerLayoutChoice` is on and that layout is allowed; otherwise the server `layout` if it is allowed; otherwise `classic`. A layout missing from `layouts` counts as allowed, only an explicit `false` hides it.

The chosen id is set on the window element as the `data-layout` attribute (`main.inventory-shell`), so stylesheets can target one layout, for example `data-layout="dock"`. Every layout keeps the same shared pieces (slots, panels, inspector, top bar, shortcut bar), the same drag and drop, and the same intents; a layout only arranges them. The `classic` layout is the original window and is unchanged.

| Layout | Arrangement |
|---|---|
| `classic` | Top bar, then personal inventory, inspector and secondary inventory in three columns, shortcut bar underneath. Quick slots, when shown, hang in a drawer on the outside edge of the window (see below). |
| `loadout` | Character-loadout window. Transfer view has three columns: pockets, a fixed-width centre column (about 300 px at scale 1) holding the Loadout panel with the item inspector under it, and the secondary inventory. Solo view is pockets plus the centre column: the Loadout panel on top and the inspector below it only while an item is selected. The window is exactly as wide as the columns it shows, with no empty frame area, and stays anchored on the pockets, so selecting an item grows it sideways instead of shifting the grid. With the personal side set to right (or the window moved to the right half in solo view) the columns are mirrored. |
| `compact` | A narrow single column (about 520 px at scale 1) for minimal screen use: top bar, the player grid with five columns (so the hotbar range stays on one row), and in transfer view the secondary inventory under it behind a divider. Each panel scrolls independently. The inspector is a popover beside the window (on the left when the personal side is right or the window sits on the right), shown only while an item is selected. The search box is hidden. |
| `dock` | A full-height panel docked to the left screen edge (the right edge when the personal side is right), about 460 px wide at scale 1. The `/ui` scale applies; the centre-based position offsets do not. Tabs on top: "Pockets" and, when a secondary inventory is open, its label with an item-count badge. Pockets is always the default tab; it never switches by itself when a secondary opens. While dragging an item, resting on a tab for a moment switches to it so the item can be dropped into the other panel. The quick-slot drawer hangs on the inner edge, the side facing the screen centre, and the inspector slides up over the bottom of the dock when an item is selected. |

Quick slots are optional: when nothing is configured to show, the layouts render no drawer, no panel and no empty frame. If the loadout layout has no quick slots its centre column is just the inspector in transfer view, and disappears in solo view while nothing is selected.

### Quick-slot presentations

`LayoutProps.renderQuickSlots(position, options)` builds the quick slots for a layout. `position` is one of:

| Position | What it draws |
|---|---|
| `drawer` | Used by `classic`, `compact` and `dock`. A vertical drawer attached to the outside edge of the window (same panel background and border as the window, rounded on its outer corners, no border where it joins), top-aligned just under the top bar. Tiles stack vertically, about 64 px square at scale 1, with the item art, the quick slot label, the key hint and the count. A handle tab on the drawer's outer edge folds it into a slim strip and expands it again with a short slide (no animation with prefers-reduced-motion). The handle is a button with `aria-expanded` and the labels `ui.quick_drawer_collapse` and `ui.quick_drawer_expand`. The collapsed state is remembered in the browser's localStorage under `kora_inventory:quickDrawerCollapsed`; until the player first toggles it, `quickSlots.drawer.startCollapsed` decides. With nothing to show there is no drawer at all, no handle and no frame. |
| `panel` | Used by `loadout`. The Loadout panel: a header and one full-width row per quick slot with the item art, the quick slot label above the item label, and on the right the count (ammo shows magazines, a weapon that reports loaded rounds shows them) and the key hint. Unresolved slots (with `hideWhenMissing` off) are dashed placeholder rows. |
| `side`, `top`, `bottom` | The original small-tile strips, kept for compatibility. No bundled layout uses them. |

Every presentation behaves the same: click selects the real item and flashes its slot, double-click uses it, dragging moves the real item, dropping an item pins it and right-click unpins a pinned slot.

The drawer prefers a side per layout (`options.side`): the left edge in `classic` and `compact`, the right edge when the personal side is right, or in solo view when the inspector opens on the left (so the two never overlap). In `dock` it is the inner edge. If the preferred edge would run off the screen (for example the window was moved far to the left in the `/ui` editor) and the other edge has room, the drawer moves to the other edge. The on-screen nudge counts the drawer as part of the window, so window and drawer stay on screen together.

The registry lives in `web/src/layouts/`: `types.ts` (the `LayoutProps` contract), one component per layout (`ClassicLayout.tsx`, `LoadoutLayout.tsx`, `CompactLayout.tsx`, `DockLayout.tsx`) and `index.ts` (the `LAYOUTS` map and `resolveLayout`). To add a layout, write a component that takes `LayoutProps`, attach `shellRef`, `shellStyle` and `data-layout` to its main element, register it in `LAYOUTS`, and add its id to `LAYOUT_IDS` in `web/src/lib/layoutIds.ts` and to the whitelist in `client/ui.lua`. Layout-specific styles live in `web/src/styles/layouts.css`, scoped under `.inventory-shell[data-layout="..."]` and limited to kora_theme tokens. A layout that floats the inspector (compact, dock) uses `LayoutProps.drawerInspector`, the inspector in drawer form with a close button, which is null until an item is selected. Layouts never talk to the server or to the bridge, so they add no new authority.

### Item receipts and notifications

`itemBoxes` controls the receipt cards. `giveNotify` and `purchaseNotify` control toasts. English strings are in `locales/en.lua` (`inventory`, `vehicle_doors`, `shop_hints`, and `ui`). The React UI uses English defaults until the delayed locale message arrives.

### Rebuilding

See [Development](../development.md).
