---
title: "Client API"
sidebar_position: 19
---


# Client API

The client exports let your client scripts open and close inventories, check what the local player holds, submit intents from a custom renderer, and run the privacy-preserving give-target selection. Everything here is intent: the server resolves, validates and decides. The bundled NUI uses the same functions.

Namespace: `exports.kora_inventory` · Source: `client.lua, client/give_target.lua, client/compat/qb_weapons.lua`

## How it works

The client keeps one session (`token`, `primary`, `secondary`, `expires`) delivered by the server. `openInventory` never opens anything locally; it sends `kora_inventory:server:open` and the session arrives, or is refused, asynchronously. `submitIntent` is the single client transport for moves, uses, drops, gives, buys and syncs: it fills in the session token and the current revisions, sends one request (direct net event by default, kora_lib callback when `ui.directTransport` is off) and waits for the verdict. Opening is blocked locally while busy (a progress bar or the `koraUiBlocked` bag); the server also enforces downed, cuffed and busy rules.

## Opening storage from a client interaction

1. **Trigger on interaction** — From a kora_target option, key press or marker, call `exports.kora_inventory:openInventory(type, id)`.
2. **Let the server decide** — There is no return value; success arrives as the session, failure as a notification.
3. **React to the session if needed** — Listen to `kora_inventory:ui:sessionOpened` / `sessionClosed` for UI state, not for authority.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Session | The local copy of the server-issued session: token plus primary and secondary views. |
| Use gate | The optional progress bar of the item's `useTime`; cancelling sends nothing to the server. |
| Give target | The nearby player chosen locally to receive an item. The browser never sees names, peds or ids. |

## Intent table for submitIntent

The built-in UI sends an envelope `{ sessionId, token, intent, payload }`. Third-party renderers may also pass the payload fields directly. `announce = false` suppresses the refusal toast.

| Option | Type | Description |
| --- | --- | --- |
| `intent / action` | string | `close`, `move` (also `split`, `transfer`, `swapItems`), `use`, `drop`, `give`, `buy` or `sync`. Anything else is refused with `unsupported intent`. Default `transfer`. |
| `payload` | table | Intent fields. move: `fromInventory`, `fromSlot`, `toInventory`, `toSlot`, `amount` (or `fromSecondary` / `toSecondary` booleans). use: `slot`. drop: `slot`, `amount`. give: `slot`, `amount`. buy: `slot`, `amount`, optional `inventory`. |
| `token / sessionId` | string | Optional session token; a mismatch with the current session returns `stale session`. |
| `announce` | boolean | Default true. When false the caller handles refusals itself. |

## Functions

These are client exports on `exports.kora_inventory`. `HasItem` is the only capitalised name.

### `exports.kora_inventory:openInventory(invType, data?)`

Asks the server to open an inventory for the local player. Refused locally (with a "busy" notice) while a progress bar is running or the UI is blocked.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `invType` | string | `player`, `stash`, `shop`, `drop`, `container`, `evidence`, `temporary`, `trunk` or `glovebox`. |
| `data?` | string \| number \| table | An id, or a table with `id`, `key` or (vending machines) `coords`. For `player` the target server id; for `trunk` / `glovebox` the vehicle network id. |

**Returns**

- **No return value. The session arrives asynchronously via `kora_inventory:ui:sessionOpened`; a refusal shows a notification via `kora_inventory:ui:rejected`.**

**Example**

```lua
-- open a shop from a target option
exports.kora_target:addSphereZone({ coords = vec3(2747.7, 3472.9, 55.7), radius = 2.0, options = { {
    label = 'Browse hardware', icon = 'basket-shopping',
    onSelect = function() exports.kora_inventory:openInventory('shop', 'hardware') end,
} } })
```

**Representative console output**

```text
Nothing is returned. If the shop exists and the player is at the counter, the shop opens beside their inventory.
```

### `exports.kora_inventory:closeInventory()`

Closes the current session (sends `kora_inventory:server:close`). Does nothing if no session is open.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
exports.kora_inventory:closeInventory()
```

**Representative console output**

```text
The panel closes once the server confirms.
```

### `exports.kora_inventory:submitIntent(intent)`

Submits an intent for the active session and waits for the verdict. Moves send `kora_inventory:server:transfer`, use/drop/buy/sync send `kora_inventory:server:intent`, give first resolves a recipient locally. A `use` of an item with `useTime` runs the progress bar first and sends nothing if it is cancelled. After a successful `use` the panel closes unless the item sets `preventClose`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `intent` | table | See the intent table. |

**Returns**

- **accepted** — true when the server accepted it.
- **result** — the server result (revisions, drop id, `{ preventClose }`) or a reason: `no active session`, `stale session`, `unsupported intent`, `invalid item amount`, `cancelled`, `timeout`, `inventory request failed`, or the server's refusal text.

**Example**

```lua
local ok, result = exports.kora_inventory:submitIntent({ intent = 'use', payload = { slot = 2 }, announce = false })
if not ok then print('use refused:', result) end
```

**Representative console output**

```text
ok = true after the server ran the use; or false, 'item is currently being used'.
```

### `exports.kora_inventory:getCurrentSession()`

Returns a copy of the current session, or nil when no inventory is open.

**Parameters**



**Returns**

- **session** — `{ token, primary, secondary, expires }` (views with items, revision, weight) or nil.

**Example**

```lua
local session = exports.kora_inventory:getCurrentSession()
if session and session.secondary then print(session.secondary.key) end
```

**Representative console output**

```text
stash:pd_armoury
```

### `exports.kora_inventory:HasItem(names, amount?)`

Client-side check of the local player's replicated items. A string needs `amount` (default 1); an array needs every name (or `amount` of each); a `{ [name] = count }` map needs each count unless `amount` is given, which then applies to every entry. Counts are summed across slots. An empty table is false. Also published as `exports['qb-inventory']:HasItem`. For display only; never gate rewards on a client check.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `names` | string \| string[] \| table&lt;string, number> | Item name(s). |
| `amount?` | integer | Required count. |

**Returns**

- **hasItems** — boolean.

**Example**

```lua
if exports.kora_inventory:HasItem({ 'lockpick', 'screwdriver' }) then
    showPickOption()
end
```

**Representative console output**

```text
true
```

### `exports.kora_inventory:giveTargetAvailable()`

Returns true when at least one other player is streamed in within `giveDistance` (default `interactionDistance`). Presentation only; the server re-validates range and bucket.

**Parameters**



**Returns**

- **available** — boolean.

**Example**

```lua
local canGive = exports.kora_inventory:giveTargetAvailable()
```

**Representative console output**

```text
true when someone is within 3 m
```

### `exports.kora_inventory:requestGiveTarget(requestId)`

Starts recipient selection: with one nearby player it resolves immediately, with several it starts a kora_target selection on exactly those peds (15 second timeout). The answer arrives as the local event `kora_inventory:client:giveTargetResolved`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `requestId` | string \| integer | Correlation id echoed in the result. |

**Returns**

- **started** — true when selection started or resolved; false when `requestId` is nil (`missing give request id`), nobody is near (`no nearby player`) or targeting is unavailable.
- **reason** — string on false.

**Example**

```lua
AddEventHandler('kora_inventory:client:giveTargetResolved', function(result)
    if result.target then print('give to', result.target) end
end)
exports.kora_inventory:requestGiveTarget(1)
```

**Representative console output**

```text
true; the event reports the recipient server id.
```

### `exports.kora_inventory:cancelGiveTarget(reason?)`

Cancels an outstanding recipient selection.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `reason?` | string | Reason reported in the resolved event. Default `cancelled`. |

**Returns**

- **cancelled** — true if a selection was active.

**Example**

```lua
exports.kora_inventory:cancelGiveTarget('closed my menu')
```

**Representative console output**

```text
true; giveTargetResolved reports `cancelled = true`.
```

### `exports.kora_inventory:getConfigWeaponAttachments()`

Builds the legacy qb-weapons attachment map from the two configuration allow-lists (`weapons.components` and `weaponCarry.components`): component item name to weapon to native component name.

**Parameters**



**Returns**

- **map** — `table<item, table<weapon, componentName>>`; only pairs present in both lists appear.

**Example**

```lua
local map = exports.kora_inventory:getConfigWeaponAttachments()
print(map['suppressor_attachment'] and map['suppressor_attachment']['weapon_pistol'])
```

**Representative console output**

```text
COMPONENT_AT_PI_SUPP (only when both allow-lists are configured for that item and weapon; the shipped lists are empty)
```

## Common use cases

- Opening shops, stashes and drops from targets or markers.
- Disabling an interaction when the player lacks an item (display only).
- Building a custom renderer on top of the session transport.

## Limits and related APIs

All client calls are requests. `HasItem` and `getCurrentSession` read replicated or server-pushed data and can lag a moment. `openInventory` has no return value and does not report refusals other than by notification. The give selection is local; the browser and any custom renderer never receive player names, peds or ids.

## Related guides

- [Events and callbacks](./events.md)
- [NUI contract](./nui.md)
- [Opening inventories](./inventories.md)
