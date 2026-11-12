---
title: "Events and callbacks"
sidebar_position: 18
---


# Events and callbacks

## Server

Server-side events fall into three groups: local events other server resources can listen to (`AddEventHandler`) to react to committed inventory changes, net events a client sends (which this resource validates), and kora_lib callbacks the client awaits. Net events accept only a real client packet: a call made from another resource through `TriggerEvent` is ignored by the `GetInvokingResource()` guard.

Namespace: `events` · Source: `server.lua, server/*.lua, server/compat/*.lua`

### How it works

Local events fire after the action has committed, from inside the inventory's own lock, so handlers must be quick and must not call back into the same inventory in a way that needs the lock (it would answer `inventory busy`). Defer with `SetTimeout(0, ...)` when you need to write to the same inventory. Net events always re-derive the player from `source`; any player id in a payload is only a request. Replies to the bundled UI go back as `kora_inventory:client:callResult` (direct transport) or as the callback return values.

### Reacting to inventory changes

1. **Pick the event** — `kora_inventory:server:audit` sees every committed action; the specific events (`itemsMoved`, `itemPurchased`, `usedItem`, `crafted`, `evidenceMoved`, `weaponRoundFired`) are narrower.
2. **Subscribe with AddEventHandler** — Use `AddEventHandler(name, function(...) end)` in your server script.
3. **Keep handlers short** — Do heavy work in a new thread; never mutate the inventory that is mid-commit from inside the handler.

### Terms used on this page

| Term | Meaning |
| --- | --- |
| Local event | Raised with `TriggerEvent` inside the server; subscribe with `AddEventHandler`. |
| Net event | Registered with `RegisterNetEvent`; fired by a client with `TriggerServerEvent`. |
| Callback | A kora_lib request/response registered with `Kora.callback.register` on the server and awaited by a client. |

### Functions

Each entry shows how to subscribe, the arguments, where the event is raised and what the handler may do.

#### `AddEventHandler('kora_inventory:server:audit', function(action, src, details) end)`

Local event raised for every audited action. The same entries are kept in the in-memory ring (`auditLimit`). Raised from `recordAudit` in server.lua.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `action` | string | `add`, `remove`, `move`, `transfer`, `swap`, `transfer-rejected`, `drop`, `give`, `use`, `purchase`, `phoneResale`, `cash-add`, `cash-remove`, `cash-transfer`. |
| `src` | integer \| nil | Player server id the action belongs to. |
| `details` | table | Action specific fields, for example `{ item, amount, slot, reason }` or `{ from, to, item, amount }`. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:audit', function(action, src, details)
    if action == 'purchase' and details.price >= 50000 then
        print(('large purchase by %s: %s x%d'):format(src, details.item, details.amount))
    end
end)
```

**Representative console output**

```text
large purchase by 12: weapon_assaultrifle x1
```

#### `AddEventHandler('kora_inventory:server:sessionOpened', function(src, payload) end)`

Local event raised when a session opens (own inventory or with a secondary). Raised from `open` / `openSelf`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `payload` | table | `{ token, primary, secondary, expires }`; the views contain full item tables. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:sessionOpened', function(src, payload)
    local second = payload.secondary and payload.secondary.key or 'none'
    print(src, 'opened inventory with', second)
end)
```

**Representative console output**

```text
12 opened inventory with stash:pd_armoury
```

#### `AddEventHandler('kora_inventory:server:sessionClosed', function(src, session, reason) end)`

Local event raised when a session ends for any reason. Raised from `close`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `session` | table | `{ token, primary, secondary, expires }` of the ended session. |
| `reason` | string | `requested`, `replaced`, `expired`, `disconnected`, `cuffed`, `resource stopped`, `drop empty`, `different routing bucket`, `inventory deleted`, `stash policy updated\|rebound\|unavailable`, `stash state changed` or an access-denied reason. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:sessionClosed', function(src, session, reason)
    if session.secondary == 'stash:pd_armoury' then logArmouryClose(src, reason) end
end)
```

**Representative console output**

```text
The armoury close is logged with its reason.
```

#### `AddEventHandler('kora_inventory:server:itemsMoved', function(src, payload) end)`

Local event raised after a transfer, swap or give commits. Raised from `transfer` and `intentGive`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player who moved the item. |
| `payload` | table | `{ action, fromInventory, toInventory, fromType, toType, fromSlot, toSlot, itemName, count, metadata }`. `action` is `swapItems` for transfers and `give` for gives; `fromInventory`/`toInventory` are kora keys. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:itemsMoved', function(src, payload)
    if payload.toType == 'trunk' then logTrunkDeposit(src, payload.itemName, payload.count) end
end)
```

**Representative console output**

```text
A deposit into trunk:ABC 123 is logged.
```

#### `AddEventHandler('kora_inventory:server:itemPurchased', function(src, purchase) end)`

Local event raised after a shop purchase commits (UI and `BuyItem`). Raised from `intentBuy` and `buyItem`. Fires inside the purchase lock; the bundled Ammu-Nation refill defers with `SetTimeout(0, ...)` for that reason.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Buyer. |
| `purchase` | table | `{ shopId, itemName, count, metadata, price }` where `price` is the total paid. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:itemPurchased', function(src, purchase)
    if purchase.shopId == 'hardware' then addToTill(purchase.price) end
end)
```

**Representative console output**

```text
The till gains the amount paid.
```

#### `AddEventHandler('kora_inventory:server:usedItem', function(src, itemName, item) end)`

Local event raised after a registered handler returned success. Also raised for built-in handlers such as weapon draws. Not raised for portable containers (see `openedContainer`) or for refused or failed uses. Raised from `useItem`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player. |
| `itemName` | string | Item name. |
| `item` | table | The item table as it was before the handler ran (it may already be consumed). |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:usedItem', function(src, itemName, item)
    if itemName == 'lockpick' then bumpHeat(src) end
end)
```

**Representative console output**

```text
Heat increases when a lockpick is used.
```

#### `AddEventHandler('kora_inventory:server:openedContainer', function(src, itemName, item) end)`

Local event raised when a portable container item (the backpack) was opened with Use. Raised from `useItem`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player. |
| `itemName` | string | Container item name. |
| `item` | table | The item table. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:openedContainer', function(src, itemName, item) end)
```

**Representative console output**

```text
Called after the backpack panel opened.
```

#### `AddEventHandler('QBCore:Server:UseItem', function(src, item) end)`

Two roles. As a local event it is the legacy fallback raised when an item is used but no handler is registered. As a net event it is what the hotbar keys send: the server reads only `item.slot`, requires `item.name` to equal the real item in that slot, then runs the normal use.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player (local form). |
| `item` | table | Local form: the item. Net form (client): `{ slot, name }`. |

**Returns**

- **No return value.**

**Example**

```lua
-- legacy qb script reacting to an item with no registered handler
AddEventHandler('QBCore:Server:UseItem', function(src, item)
    if item.name == 'old_radio' then TriggerClientEvent('oldradio:toggle', src) end
end)
```

**Representative console output**

```text
Runs only when no useable handler exists for `old_radio`.
```

#### `AddEventHandler('kora_inventory:server:crafted', function(src, recipeId, result) end)`

Local event raised after `CraftItem` commits. Raised from `crafting.craft`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player. |
| `recipeId` | string | Recipe id. |
| `result` | table | The output entry or array of output entries (amounts multiplied by the batch). |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:crafted', function(src, recipeId, result)
    giveXp(src, recipeId)
end)
```

**Representative console output**

```text
XP awarded after a craft.
```

#### `AddEventHandler('kora_inventory:server:weaponStateChanged', function(src, slot, info) end)`

Local event raised after a weapon's metadata is rewritten by `SetWeaponState`, ammo loading, firing or wear. Raised from the weapon state writer in crafting.lua.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player. |
| `slot` | integer | Weapon slot. |
| `info` | table | A copy of the new metadata. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:weaponStateChanged', function(src, slot, info)
    if info.durability <= 0 then Kora.notify.send(src, { title = 'Weapon', message = 'Your weapon is broken.', type = 'warning' }) end
end)
```

**Representative console output**

```text
The player is told when durability hits 0.
```

#### `AddEventHandler('kora_inventory:server:weaponRoundFired', function(src, round) end)`

Local event raised for each accepted shot from a drawn inventory weapon, with the consumed round record. Contains the weapon serial, so do not forward it to clients.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Shooter. |
| `round` | table | `{ id, ammoType, lot, weapon, weaponSerial }`. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:weaponRoundFired', function(src, round)
    createCasing(src, round.id, round.ammoType, round.weaponSerial)
end)
```

**Representative console output**

```text
A casing record is created for forensic systems.
```

#### `AddEventHandler('kora_inventory:server:trainingRoundFired', function(src, info) end)`

Local event raised for each counted shot of a temporary training weapon.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Shooter. |
| `info` | table | `{ owner, weapon, shot, remaining }`; `owner` is the starting resource. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:trainingRoundFired', function(src, info)
    if info.owner == GetCurrentResourceName() then score[src] = (score[src] or 0) + 1 end
end)
```

**Representative console output**

```text
The range script scores a shot.
```

#### `AddEventHandler('kora_inventory:server:evidenceMoved', function(action, source, target, evidenceId, item) end)`

Local event raised after an evidence seize or release commits.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `action` | string | `seize` or `release`. |
| `source` | integer | Officer. |
| `target` | integer | Target player. |
| `evidenceId` | string | Evidence id. |
| `item` | table | Copy of the moved item. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:evidenceMoved', function(action, officer, target, evidenceId, item)
    logCustody(action, officer, target, evidenceId, item.name, item.amount)
end)
```

**Representative console output**

```text
A chain-of-custody log entry is written.
```

#### `AddEventHandler('kora_inventory:server:ready', function(status) end)`

Local event raised once secondary inventories have been restored from the database. Wait for it before relying on stored stashes.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `status` | table | The persistence status `{ ready, schemaReady, restoring, enabled, lastError }`. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:ready', function(status)
    registerMyStashes()
end)
```

**Representative console output**

```text
Your stashes are registered after the stored ones exist.
```

#### `AddEventHandler('kora_inventory:server:persistenceRejected', function(record) end)`

Local event raised for each stored inventory skipped as malformed during restoration.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `record` | table | `{ type, id, reason }`. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:persistenceRejected', function(record)
    print('rejected stored inventory', record.type, record.id, record.reason)
end)
```

**Representative console output**

```text
rejected stored inventory stash old_box stored inventory is malformed: invalid item name
```

#### `AddEventHandler('kora_inventory:server:migrationProgress', function(report, source, phase, row) end)`

Local event raised during `kora_inventory-migrate` every `migrationBatchSize` rows and when a source finishes.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `report` | table | Running totals `{ dryRun, imported, skipped, quarantined, sources }`. |
| `source` | string | Legacy table name. |
| `phase` | string | `importing` or `complete`. |
| `row` | table \| nil | The row being imported (importing phase). |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:server:migrationProgress', function(report, source, phase)
    print(source, phase, report.imported)
end)
```

**Representative console output**

```text
stashitems importing 100
```

#### `AddEventHandler('kora_core:server:inventoryChanged', function(src, path, value) end)`

Event raised by kora_core whenever any player item write happens. kora_inventory listens: for writes made by other resources it bumps the revision and refreshes any open panel; weapon carry also uses it to keep the carried list and the equipped weapon in sync. You can listen too.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player. |
| `path` | table | The changed path, for example `{ 'items', 3 }`. |
| `value` | any | The new value. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_core:server:inventoryChanged', function(src, path, value)
    refreshMyOverlay(src)
end)
```

**Representative console output**

```text
Fires for AddItem, RemoveItem and every other writer.
```

#### `RegisterNetEvent('kora_inventory:server:open', function(invType, data) end)  -- client: TriggerServerEvent`

Net event: the client asks to open an inventory. The server calls `openInventory` with the real `source`; a refusal comes back as `kora_inventory:client:rejected`. Sent by the client `openInventory` export.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `invType` | string | `player`, `stash`, `shop`, `drop`, `container`, `evidence`, `temporary`, `trunk`, `glovebox`. |
| `data` | string \| number \| table | An id (for `player` the target server id; for vehicle types the network id) or an open data table (`id`, `key`, `coords`). |

**Returns**

- **No return value. Success arrives as `kora_inventory:client:sessionOpened`; failure as `kora_inventory:client:rejected(reason)`.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:open', 'stash', 'pd_armoury')
```

**Representative console output**

```text
The session opens if the stash exists and the access checks pass.
```

#### `RegisterNetEvent('kora_inventory:server:close', function(token) end)  -- client: TriggerServerEvent`

Net event: the client closes its session. Ignored unless the token matches the current session.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `token` | string | The session token. |

**Returns**

- **No return value. The client then receives `kora_inventory:client:sessionClosed` with reason `requested`.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:close', session.token)
```

**Representative console output**

```text
The session is closed.
```

#### `RegisterNetEvent('kora_inventory:server:transfer', function(request) end)  -- client: TriggerServerEvent`

Net event for a move, split or swap between the two inventories of a session. The same handler is registered as the callback of the same name. Failures return as `kora_inventory:client:rejected`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `request` | table | `{ token, fromInventory, toInventory, fromSlot, toSlot?, amount?, fromRevision, toRevision }`. Inventory values must be the session's primary or secondary key. A missing `toSlot` stacks or fills the first free slot; a missing `amount` moves the whole stack. |

**Returns**

- **No return value (net event). The callback form returns `ok, { fromRevision, toRevision }` or `false, reason` (for example `invalid session`, `session expired`, `inventory not in session`, `stale source inventory`, `invalid item amount`, `invalid target slot`, `over weight`, `shop items must be purchased`, `item is currently being used`).**

**Example**

```lua
-- client (bundled UI does this through submitIntent)
TriggerServerEvent('kora_inventory:server:transfer', {
    token = session.token, fromInventory = 'player:12', toInventory = 'stash:pd_armoury',
    fromSlot = 3, toSlot = 5, amount = 2,
    fromRevision = session.primary.revision, toRevision = session.secondary.revision,
})
```

**Representative console output**

```text
Two items move to slot 5 of the stash; both inventories are patched.
```

#### `RegisterNetEvent('kora_inventory:server:intent', function(request) end)  -- client: TriggerServerEvent`

Net event for session intents `use`, `drop`, `give`, `buy` and `sync`. The same handler is registered as a callback. Failures return as `kora_inventory:client:rejected`. The `give` request is sent by `client.lua` after the recipient is resolved locally.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `request` | table | `{ token, action, payload, primaryRevision, secondaryRevision }`. Payloads: `use { slot }`, `drop { slot, amount }`, `give { slot, amount, target }`, `buy { slot, amount, inventory? }`, `sync {}`. `inventory` (when present) must be the session's own key. |

**Returns**

- **No return value (net event). Callback results: `use` returns `{ preventClose }`, `drop` the drop id, `give` `{ fromRevision, toRevision }`, `buy` and `sync` true; on failure false and a reason such as `invalid session action`, `stale inventory`, `invalid item slot`, `invalid item amount`, `item is currently being used`, `invalid give recipient`, `recipient is too far away`, `recipient is over weight`, `out of stock`, `insufficient funds`, `unsupported intent`.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:intent', {
    token = session.token, action = 'drop', payload = { slot = 4, amount = 1 },
    primaryRevision = session.primary.revision,
})
```

**Representative console output**

```text
The item is removed and a ground bag is created or merged.
```

#### `RegisterNetEvent('kora_inventory:server:call', function(requestId, action, request) end)  -- client: TriggerServerEvent`

The direct transport used by the bundled UI (`ui.directTransport`). One event in, one `kora_inventory:client:callResult` out, skipping kora_lib's callback layer. Same handlers and checks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `requestId` | integer | Positive whole id chosen by the client to match the reply. |
| `action` | string | `transfer` or `intent`. |
| `request` | table | The transfer or intent request. |

**Returns**

- **No return value. Reply: `kora_inventory:client:callResult(requestId, ok, result)`; an unknown action answers `unsupported request`, a crash answers `request failed`.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:call', 17, 'intent', { token = t, action = 'sync', payload = {} })
```

**Representative console output**

```text
The client receives callResult(17, true, true).
```

#### `RegisterNetEvent('kora_inventory:server:weaponToggled', function(slot) end)  -- client: TriggerServerEvent`

Net event: the client confirms the draw or holster animation the server asked for. Accepted only if it matches the pending request in time (the pending request expires after the animation time plus 15 seconds), the slot matches, and the item is still there.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `slot` | integer | The slot the server asked about. |

**Returns**

- **No return value. On success the server records or clears the equipped weapon and republishes the carried list; if the item left meanwhile it sends `kora_inventory:client:weaponRemoved`.**

**Example**

```lua
-- client (sent by client/weaponcarry.lua after the progress bar)
TriggerServerEvent('kora_inventory:server:weaponToggled', 1)
```

**Representative console output**

```text
The weapon is recorded as equipped.
```

#### `RegisterNetEvent('kora_inventory:server:weaponUnequipped', function() end)  -- client: TriggerServerEvent`

Net event, payload-free: the weapon left the player's hands without a holster (weapon wheel, death, disarm). It can only put the weapon back on the player's own body.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:weaponUnequipped')
```

**Representative console output**

```text
The equipped record is cleared and the carried list republished.
```

#### `RegisterNetEvent('kora_inventory:server:weaponFired', function() end)  -- client: TriggerServerEvent`

Net event, payload-free: the client's ped fired a shot. Rate-limited by `ballistics.shotCooldown`. Consumes one stored round of the equipped weapon (or counts a training round).

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
-- client
TriggerServerEvent('kora_inventory:server:weaponFired')
```

**Representative console output**

```text
One round is removed server-side and `weaponRoundFired` fires.
```

#### `RegisterNetEvent('kora_inventory:server:weaponAmmoConsumed', function(slot, amount) end)  -- client: TriggerServerEvent`

Legacy path used when ballistics are disabled: the client reports the ped's remaining ammo. It can only lower the stored ammo of the equipped weapon in that slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `slot` | integer | Equipped weapon slot. |
| `amount` | integer | Remaining ammo reported by the ped. |

**Returns**

- **No return value.**

**Example**

```lua
-- client (only when Config.kora_inventory.weapons.ballistics.enabled is false)
TriggerServerEvent('kora_inventory:server:weaponAmmoConsumed', 1, 8)
```

**Representative console output**

```text
Stored ammo drops to 8 if it was higher.
```

#### `Kora.callback.trigger('kora_inventory:server:open', invType, data)  -- client`

Callback form of the open request for third-party renderers. Returns `openInventory(src, invType, data)`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `invType` | string | Inventory type. |
| `data` | any | Id or table. |

**Returns**

- **opened** — boolean.
- **result** — payload or reason.

**Example**

```lua
local ok, result = Kora.callback.trigger('kora_inventory:server:open', 'stash', 'pd_armoury')
```

**Representative console output**

```text
ok = true, result = { token = ..., primary = ..., secondary = ... }
```

#### `Kora.callback.trigger('kora_inventory:server:drops')  -- client`

Callback used by `client/drops.lua` to hydrate bag props: ids and coordinates of drops in the caller's routing bucket, never contents.

**Parameters**



**Returns**

- **drops** — array of `{ id, coords }`.

**Example**

```lua
local drops = Kora.callback.trigger('kora_inventory:server:drops')
```

**Representative console output**

```text
{ { id = 7, coords = vec3(...) } }
```

### Common use cases

- Logging chain of custody, sales and moves.
- Gameplay triggers on item use, crafting and shots.
- Waiting for persistence to be ready.

### Limits and related APIs

Local events fire inside inventory locks, so avoid synchronous writes to the same inventory from a handler. A net event ignores calls whose `GetInvokingResource()` is set. Events do not carry authority: a client value in a payload is only a request. The qb-inventory and qb-weapons compat events are listed in their own modules.

### Related guides

- [Opening inventories](./inventories.md)
- [Hooks](./hooks.md)
- [qb-inventory compat](./compat-qb.md)
- [NUI contract](./nui.md)

## Client

Client events are of two kinds: net events the server sends (`kora_inventory:client:*`), which this resource handles itself and which are not meant to be triggered by other resources, and local presentation events (`kora_inventory:ui:*` and a few `kora_inventory:client:*` requests) that connect the transport, the NUI bridge and the give-target resolver. Other resources normally use the client exports instead.

Namespace: `events` · Source: `client.lua, client/*.lua`

### How it works

Every `kora_inventory:client:*` net handler starts with a `GetInvokingResource()` guard so another resource cannot spoof it from the client. The transport in `client.lua` keeps one session; the NUI bridge in `client/ui.lua` translates its local `kora_inventory:ui:*` events to NUI messages. The names differ on purpose: re-triggering a network handler's own name would recurse into it.

### Writing a custom renderer

1. **Listen to the local UI events** — `kora_inventory:ui:sessionOpened`, `sessionPatched`, `sessionClosed` and `rejected` carry the session state.
2. **Send intents** — Trigger `kora_inventory:client:submitIntent` or call the `submitIntent` export with a `move`, `use`, `drop`, `give`, `buy`, `sync` or `close` intent.
3. **Never hold authority** — Treat every view as a read-only snapshot; the server decides.

### Terms used on this page

| Term | Meaning |
| --- | --- |
| Session view | An inventory snapshot `{ id, key, type, label, slots, maxWeight, weight, revision, items, stock }`. |
| Presentation event | A local event under `kora_inventory:ui:` that exists for the NUI bridge, not for authority. |

### Functions

Net events below are sent by the server; local events can be triggered from client scripts where noted.

#### `RegisterNetEvent('kora_inventory:client:sessionOpened', function(payload) end)`

Server to client: a session opened. The transport stores it and raises the local `kora_inventory:ui:sessionOpened`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `payload` | table | `{ token, primary, secondary, expires }` with full views. |

**Returns**

- **No return value.**

**Example**

```lua
-- listen for the local relay instead of the net event
AddEventHandler('kora_inventory:ui:sessionOpened', function(payload)
    print('inventory opened', payload.token)
end)
```

**Representative console output**

```text
inventory opened 12:48211:557812
```

#### `RegisterNetEvent('kora_inventory:client:sessionPatched', function(token, patch) end)`

Server to client: an inventory in the session changed. Replaces the local view and raises `kora_inventory:ui:sessionPatched`. Ignored when the token does not match.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `token` | string | Session token. |
| `patch` | table | `{ key, revision, inventory }`. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:ui:sessionPatched', function(payload)
    print(payload.patch.key, payload.patch.revision)
end)
```

**Representative console output**

```text
player:12 41
```

#### `RegisterNetEvent('kora_inventory:client:sessionClosed', function(token, reason) end)`

Server to client: the session ended. Clears local state and raises `kora_inventory:ui:sessionClosed`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `token` | string | Session token. |
| `reason` | string | Why it closed (see the server `sessionClosed` event). |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:ui:sessionClosed', function(payload) print(payload.reason) end)
```

**Representative console output**

```text
requested
```

#### `RegisterNetEvent('kora_inventory:client:rejected', function(reason) end)`

Server to client: a request was refused. Raises `kora_inventory:ui:rejected`, which shows a notification (repeats and stale-session noise are filtered).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `reason` | string | Refusal text. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:ui:rejected', function(payload) print(payload.reason) end)
```

**Representative console output**

```text
too far away
```

#### `RegisterNetEvent('kora_inventory:client:callResult', function(requestId, ok, result) end)`

Server to client: the answer to a direct-transport request. Resolves the pending request. Unknown ids are ignored; a request with no answer times out after 30 seconds.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `requestId` | integer | Id sent with `kora_inventory:server:call`. |
| `ok` | boolean | Verdict. |
| `result` | any | Result or reason. |

**Returns**

- **No return value.**

**Example**

```lua
-- handled internally by client.lua
```

**Representative console output**

```text
The waiting submitIntent call returns ok, result.
```

#### `RegisterNetEvent('kora_inventory:client:itemBox', function(payload) end)`

Server to client: an item receipt. Forwarded to the NUI as `kora_inventory:nui:itemBox`, unless the same change was already shown through the legacy event.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `payload` | table | `{ name, label, image, imageUrl, imageOverride, amount, action, duration }` with `action` one of `add`, `purchase`, `remove`, `use`. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server, for example after AddItem
```

**Representative console output**

```text
A "+3 Lockpick" box appears for 2.6 seconds.
```

#### `RegisterNetEvent('kora_inventory:client:dropCreated', function(id, coords) end)`

Server to client: a ground drop exists. Creates the local bag prop and pick-up target.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | integer \| string | Drop id. |
| `coords` | table | `{ x, y, z }`. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server from dropCreate
```

**Representative console output**

```text
A bag appears on the ground.
```

#### `RegisterNetEvent('kora_inventory:client:dropsUpdated', function(list) end)`

Server to client: the full list of visible drops (after a routing-bucket change). Adds missing props and removes stale ones.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `list` | table[] | Array of `{ id, coords }`. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server
```

**Representative console output**

```text
Props in other buckets are removed.
```

#### `RegisterNetEvent('kora_inventory:client:dropRemoved', function(id) end)`

Server to client: a drop was emptied or deleted. Removes its prop and target.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | integer \| string | Drop id. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server
```

**Representative console output**

```text
The bag disappears.
```

#### `RegisterNetEvent('kora_inventory:client:toggleWeapon', function(request) end)`

Server to client: draw or holster a weapon. The client plays the timed progress bar and animation, applies ammo, components, tint and damage settings, then reports `kora_inventory:server:weaponToggled`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `request` | table | `{ name, slot, action (draw\|holster\|toggle), duration, ammo, tint, components, label, tier, damage }`. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server from the weapon use handler
```

**Representative console output**

```text
The player draws the pistol after 900 ms.
```

#### `RegisterNetEvent('kora_inventory:client:weaponRemoved', function(name) end)`

Server to client: the item backing a drawn weapon left the inventory (dropped, given, moved, sold). The client strips the weapon from the ped.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Weapon item name. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server
```

**Representative console output**

```text
The weapon disappears from the player's hands.
```

#### `RegisterNetEvent('kora_inventory:client:addAmmo', function(request) end)`

Server to client: set the ped's ammo to the server-saved value after a magazine was loaded (an absolute amount, so late shots do not matter).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `request` | table | `{ weapon, rounds, ammo, maxAmmo }`. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by the server from the ammo handler
```

**Representative console output**

```text
The pistol shows 24 rounds.
```

#### `RegisterNetEvent('kora_inventory:client:startTrainingWeapon', function(name, rounds, damage) end)`

Server to client: give the training weapon with the given rounds.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Weapon name. |
| `rounds` | integer | Rounds. |
| `damage` | table | Damage settings. |

**Returns**

- **No return value.**

**Example**

```lua
-- sent by StartTrainingWeapon
```

**Representative console output**

```text
The weapon is placed in the player's hands.
```

#### `RegisterNetEvent('kora_inventory:client:stopTrainingWeapon', function() end)`

Server to client: remove the training weapon.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
-- sent by StopTrainingWeapon
```

**Representative console output**

```text
The weapon is removed.
```

#### `Kora.callback.register('kora_inventory:client:useParachute', function(request) end)`

Client callback the server awaits from the parachute use handler. Runs the progress bar, gives the parachute and wears the pack.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `request` | table | `{ time, tint }`. |

**Returns**

- **equipped** — true when the parachute was equipped, false if cancelled, already equipped, or the ped died.

**Example**

```lua
-- called by the server, not by other resources
```

**Representative console output**

```text
true after the bar completes.
```

#### `TriggerEvent('kora_inventory:client:submitIntent', intent)`

Local client event equivalent to the `submitIntent` export (but without a return value). Public hook for custom renderers.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `intent` | table | `{ intent, payload, token?, sessionId?, announce? }` with `intent` one of `close`, `move`, `split`, `transfer`, `swapItems`, `use`, `drop`, `give`, `buy`, `sync`. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('kora_inventory:client:submitIntent', { intent = 'use', payload = { slot = 2 } })
```

**Representative console output**

```text
The use is sent to the server.
```

#### `TriggerEvent('kora_inventory:client:requestGiveAvailability')`

Local request: report whether a give recipient is nearby. Answered with `kora_inventory:ui:giveAvailability { available }`. Raised automatically when a session opens and every 750 ms while it is open.

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:ui:giveAvailability', function(payload) print(payload.available) end)
TriggerEvent('kora_inventory:client:requestGiveAvailability')
```

**Representative console output**

```text
true
```

#### `TriggerEvent('kora_inventory:client:requestGiveTarget', requestId)`

Local request that starts recipient selection (same as the `requestGiveTarget` export). Answered with `kora_inventory:client:giveTargetResolved`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `requestId` | string \| integer | Correlation id echoed in the answer. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('kora_inventory:client:requestGiveTarget', 5)
```

**Representative console output**

```text
With one nearby player the answer arrives at once; with several, the player points at one.
```

#### `AddEventHandler('kora_inventory:client:giveTargetResolved', function(result) end)`

Local event with the outcome of recipient selection. The transport uses it to send the `give` intent.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `result` | table | `{ requestId, target = serverId }` or `{ requestId, cancelled = true, reason }` (`no nearby player`, `targeting unavailable`, `target selection timed out`, `inventory closed`, `replaced`, `cancelled`). |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:client:giveTargetResolved', function(result) print(result.requestId, result.target, result.reason) end)
```

**Representative console output**

```text
5 14 nil
```

#### `TriggerEvent('kora_inventory:client:cancelGiveTarget', reason?)`

Local request that cancels an outstanding recipient selection.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `reason?` | string | Reason placed in the resolved event. |

**Returns**

- **No return value.**

**Example**

```lua
TriggerEvent('kora_inventory:client:cancelGiveTarget', 'cancelled')
```

**Representative console output**

```text
The selection ends.
```

#### `AddEventHandler('kora_inventory:client:useStarted', function() end)`

Local events raised around a use from the open panel: `useStarted` before the request is sent (the qb `inv_busy` flag is cleared so the handler's client effects can add or remove items), `useRejected` if it fails (the flag is restored).

**Parameters**



**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:client:useStarted', function() end)
```

**Representative console output**

```text
Used by client/compat.lua to manage `inv_busy`.
```

#### `AddEventHandler('kora_inventory:ui:sessionOpened', function(payload) end)`

Local presentation relays of the session net events, consumed by the NUI bridge, the vehicle trunk animation, the give-target resolver and the qb compat bridge. Payloads: opened `{ token, primary, secondary, expires }`; patched `{ token, patch }`; closed `{ token, reason }`; rejected `{ reason }`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `payload` | table | See the description. |

**Returns**

- **No return value.**

**Example**

```lua
AddEventHandler('kora_inventory:ui:sessionClosed', function(payload) cleanup(payload.reason) end)
```

**Representative console output**

```text
Your cleanup runs when the inventory closes.
```

#### `AddEventHandler('kora_inventory:ui:giveTargeting', function(payload) end)`

Other local presentation events used internally: `hotbarShow { slots, seconds }` (U key), `giveTargeting { active }` (NUI focus handoff while pointing at a recipient), `giveAvailability { available }`, `legacyItemBox (itemData, action, amount)` (from `qb-inventory:client:ItemBox`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `payload` | table | See the description. |

**Returns**

- **No return value.**

**Example**

```lua
-- internal
```

**Representative console output**

```text
Not intended as a public API.
```

### Common use cases

- Building a custom inventory renderer.
- Reacting to the inventory opening or closing.
- Showing your own item receipts.

### Limits and related APIs

The `kora_inventory:client:*` net events are for the server only; they refuse calls from other resources. Local `kora_inventory:ui:*` events are presentation relays and may change with the bundled UI. Do not rely on them for authority.

### Related guides

- [Client API](./client-api.md)
- [NUI contract](./nui.md)
- [Opening inventories](./inventories.md)

## Additional events and state (from the code)

Names the sections above do not list. All come from the current code of this resource.

| Name | Kind | Purpose |
| --- | --- | --- |
| `kora_inventory:server:persistenceReady` | server local event | `reports`: schema setup finished (kora_inventory listens to this itself). |
| `kora_inventory:server:throwableThrown` | net event (client to server) | The drawn throwable was thrown. |
| `kora_inventory:server:legacyWeaponUse`, `kora_inventory:server:legacyWeaponHolster` | net events (client to server) | Used by the legacy `qb-weapons` client events. |
| `kora_inventory:client:openAmmunation`, `openLiquorStore`, `openConvenienceStore` | net events (server to client) | Each only calls `openInventory('shop', id)`; the server repeats all location checks. |
| `qb-inventory:server:GetCurrentDrops`, `createDrop`, `attemptPurchase`, `giveItem` | callbacks | qb-inventory compatibility, see [Compatibility](../compatibility.md). |
| `qb-weapons:server:GetConfig`, `weapon:server:GetWeaponAmmo`, `qb-weapons:server:RepairWeapon`, `RemoveAttachment` | callbacks | Legacy qb-weapons callbacks. The repair and attachment ones refuse. |
| `kora_inventory:weaponCarry` | player state bag | Written by the server: carried weapon list; clients only render it. |
| `fftSession` | state | Read only with [FFT hooks](../fft.md). |

The server also listens for `kora_core:server:inventoryChanged`, `kora_core:server:playerLoaded`, `QBCore:Server:OnPlayerUnload` and `playerDropped`. Metadata read for blocks: `isdead`, `inlaststand`, `ishandcuffed`; state read: `koraCuffed`, `kora_vehiclekeys:locked`.

The full list of exports is on [Exports](../exports.md).
