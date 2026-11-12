---
title: "Opening inventories and sessions"
sidebar_position: 4
---


# Opening inventories and sessions

Everything a player does in the inventory UI happens inside a session: a server-issued token tied to one player, one primary inventory (their own) and at most one secondary inventory (stash, shop, drop, trunk ...). This page explains how a session is opened, what the server checks on every request, and the server exports for opening, closing and granting inspection rights.

Namespace: `exports.kora_inventory` · Source: `server.lua (open, openSelf, validSession, transfer, handleIntent, canAccess)`

## How it works

Opening runs the access checks (`canAccess`), fires the `openInventory` (or `openShop`) hook, then creates the session with an expiry of `sessionTtl` and sends `kora_inventory:client:sessionOpened` with views of both inventories. Every later request carries the token and the revision of each inventory the client last saw. `validSession` rejects a wrong or expired token, a cuffed player, an inventory that is not part of the session, a failed access re-check (the session is closed with that reason), or a stale revision. Transfers then run inside a lock on both inventories, re-validate inside the lock, apply hooks, and commit by removing from the source and adding to the target, rolling back if the second half fails. A background loop every 5 seconds closes expired sessions and sessions whose drop moved to another routing bucket.

## What happens when a player opens an inventory

1. **Client sends an intent** — The client calls `exports.kora_inventory:openInventory(type, data)` (or presses TAB). The request is only a type and an id or table.
2. **Server resolves and checks** — `openInventory` refuses while the player is downed or cuffed, resolves the key (`type:id`), and `canAccess` checks owner, groups, access callback, coordinates, routing bucket and recovery state.
3. **Hooks run** — ox-style `openInventory` (or `openShop`) hooks may cancel the open. A cancelled open returns the hook's reason.
4. **Session issued** — The server creates `{ token, primary, secondary, expires }`, replaces any earlier session of that player, and sends it to the client, which pushes it to the NUI.
5. **Requests are validated** — Moves (`kora_inventory:server:transfer`) and intents (`use`, `drop`, `give`, `buy`, `sync` via `kora_inventory:server:intent`) are re-validated on every request.
6. **Session ends** — Closing, expiry (`sessionTtl`), disconnect, resource stop, losing access, cuffing, a bucket change or a stash policy change ends it with a reason delivered in `kora_inventory:client:sessionClosed`.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Session token | A random string `<source>:<time>:<random>` issued per open. It is the only credential the client holds. |
| Primary / secondary | The player's own inventory and the other inventory in the session. |
| Revision | Counter bumped on every committed change to an inventory. The server compares the client's revision with its own and answers `stale source inventory` / `stale target inventory` on a mismatch. |
| Lease | The session expiry, renewed on every request while `sessionSliding` is on. |
| Intent | A small client request: `move`, `split`, `use`, `drop`, `give`, `buy`, `sync`, `close`. |

## Open request data (second argument of the client open)

The client open accepts a type string and either an id or a table. The server reads only the fields below; anything else is ignored.

| Option | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Inventory id for stash, shop, drop, container, evidence and temporary types. For `trunk` and `glovebox` pass the vehicle network id instead (a number). |
| `key` | string | A full inventory key such as `stash:pd_armoury`. When present it replaces `type:id`. |
| `coords` | table | Vending machines only: `{ x, y, z }` reported by the client. The vending access check compares it with the player's live server position. |

## Access checks (canAccess)

In order: the inventory must exist; `confiscation` inventories are always denied; a drop must be in the player's routing bucket; another player's inventory needs same bucket, distance within `interactionDistance` and an inspection policy that returns true; secondary inventories refuse while `blocked` or recovery is pending; an inventory marked as needing an access policy with none loaded answers `access policy unavailable`; an `owner` must equal the player's source or citizen id (`not owner`); `groups` must match the player's job or gang and minimum grade (`not authorised`); the `access` callback must return a truthy value (otherwise `access denied`, whatever reason it returned); finally `coords` (one point or a list, each with an optional `distance`) must be within reach (`too far away`). An empty or malformed non-nil `coords` denies; nil means unbounded.

## Which intents exist

`use` (slot of the primary inventory), `drop` (slot and amount from the primary inventory; creates or merges into a drop), `give` (slot, amount and a recipient resolved locally by the client), `buy` (slot and amount from the shop in the session), `sync` (re-sends authoritative state, throttled to once per 200 ms). Moves and splits go through `kora_inventory:server:transfer` instead. Anything else answers `unsupported intent`.

## Moving, stacking and swapping

A transfer to an empty slot moves (or splits when the amount is smaller); onto a stackable match it stacks; onto a different occupied slot it swaps, which requires moving the whole stack (`cannot partially swap occupied slots`) and re-checks weight on both sides. Dropping a stack on its own slot succeeds without doing anything. A portable container cannot be put inside itself, and cannot go into another container unless its definition sets `allowNested`.

## Giving

The client resolves a nearby recipient locally (the browser never receives names, peds or ids). The server then re-checks the recipient's existence, routing bucket and distance, runs the `swapItems` hook with action `give`, moves the stack and rolls back on failure. The recipient must be within `interactionDistance` and have capacity.

## Opening by key

Native keys are `kind:id`. A client can only open a key that already exists server-side, so it can never create a stash or shop by asking for one. Server code creates stashes lazily through `stashOpen` / `OpenInventory`.

## Functions

These exports start and end sessions or extend who may open another player's inventory. Clients cannot call them; they use the client exports and the net events documented in Events and callbacks.

### `exports.kora_inventory:OpenInventory(src, identifier, opts?)`

Opens a stash or typed inventory for a player from server code. Without `opts.type` it opens the stash `identifier`, creating it on demand with the options you pass (or as a per-citizen stash if it was registered with `owner = true`). With `opts.type` it opens that inventory type using `opts.id`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `identifier` | string \| number | Stash id (used only when `opts.type` is absent). |
| `opts?` | table | For stashes: `label`, `slots`, `maxWeight`, `coords`, `distance`, `groups`, `owner`, `access`. With `opts.type` (`shop`, `drop`, `container`, `evidence`, `temporary`, `trunk`, `glovebox`, `stash`) you must also set `opts.id`. For vehicle types `id` is a network id. |

**Returns**

- **opened** — true when a session was opened.
- **result** — the session payload `{ token, primary, secondary, expires }` on success, or a failure reason such as `inventory not found`, `access denied`, `too far away`, `different routing bucket`, `not owner`, `not authorised`, `you cannot open inventories while downed`.

**Example**

```lua
-- open a per-citizen apartment stash registered earlier with owner = true
local opened, result = exports.kora_inventory:OpenInventory(src, 'apartment_5')
if not opened then
    Kora.notify.send(src, { title = 'Apartment', message = tostring(result), type = 'error' })
end

-- open a registered shop by type
exports.kora_inventory:OpenInventory(src, 'hardware', { type = 'shop', id = 'hardware' })
```

**Representative console output**

```text
opened = true and the player sees the stash or shop beside their own inventory. The stash path (no opts.type) skips the downed/cuffed check that the typed path and the client path apply.
```

### `exports.kora_inventory:CloseInventory(src)`

Closes the player's current inventory session. The client receives `kora_inventory:client:sessionClosed` with reason `requested`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |

**Returns**

- **closed** — true if a session existed and was closed, false if there was none.

**Example**

```lua
-- close any open inventory before teleporting the player
exports.kora_inventory:CloseInventory(src)
```

**Representative console output**

```text
closed = true; the NUI hides and focus is released.
```

### `exports.kora_inventory:RegisterInspectionAccess(callback)`

Registers a trusted server callback that can grant or veto opening another player's inventory (police search, admin tools, consent). Inspection is denied unless at least one callback (or `Config.kora_inventory.playerInspection.access`) returns true and none returns false. Distance (`interactionDistance`) and routing bucket are checked before callbacks run. Alias `registerInspectionAccess`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `callback` | function | `callback(source, target, sourceData, targetData)`. `sourceData`/`targetData` are detached copies of kora_core PlayerData. Return true to grant, false (optionally `false, reason`) to deny, nil to abstain. |

**Returns**

- **hookId** — integer id to pass to `RemoveInspectionAccess`.

**Example**

```lua
local id = exports.kora_inventory:RegisterInspectionAccess(function(source, target, officer, suspect)
    local job = officer.job
    if job and job.name == 'police' and job.onduty and suspect.metadata.ishandcuffed then
        return true
    end
    return false, 'only on-duty police may search cuffed players'
end)
```

**Representative console output**

```text
hookId = 1. A search attempt by an on-duty officer on a cuffed player within range now opens the target inventory.
```

### `exports.kora_inventory:RemoveInspectionAccess(id)`

Removes a callback registered with `RegisterInspectionAccess`. Callbacks registered by a resource are also removed automatically when that resource stops. Alias `removeInspectionAccess`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | integer | Id returned by `RegisterInspectionAccess`. |

**Returns**

- **No return value.**

**Example**

```lua
exports.kora_inventory:RemoveInspectionAccess(id)
```

**Representative console output**

```text
The callback no longer runs. Note: any resource can remove any id; the id is not owner-checked.
```

### `exports.kora_inventory:getPersistenceStatus()`

Reports whether secondary-inventory storage is ready. Wait for `ready` before relying on stored stashes and shops.

**Parameters**



**Returns**

- **status** — `{ ready, schemaReady, restoring, enabled, lastError }`. `ready` is true once the schema exists and stored inventories have been restored; `restoring` is true in between.

**Example**

```lua
while not exports.kora_inventory:getPersistenceStatus().ready do Wait(250) end
print('inventory storage ready')
```

**Representative console output**

```text
{ ready = true, schemaReady = true, restoring = false, enabled = true }
```

## Common use cases

- Let a server resource open a stash, shop or container for a player after its own validation.
- Close a player's inventory before a cutscene, jail or teleport.
- Allow police to search handcuffed players through a single inspection policy.

## Limits and related APIs

A player has one session at a time; opening replaces the previous one. The native `OpenInventory` export cannot open another player's inventory (`opts.type = 'player'` resolves to the caller's own); use the client open with a player type, or the qb identity's `OpenInventoryById`. Access callbacks cannot surface their own reason: a denial from an `access` callback is always reported as `access denied`. The session views are copies; mutate inventories through the exports, never through a view.

## Related guides

- [Stashes](./stashes.md)
- [Shops](./shops.md)
- [Drops](./drops.md)
- [Events and callbacks](./events.md)
- [Client API](./client-api.md)
