---
title: "Drops"
sidebar_position: 7
---


# Drops

A drop is a temporary ground inventory (`drop:<id>`) created when a player drops an item or when your script calls `dropCreate`. Every client draws a local bag prop with a pick-up target; opening it goes through the normal access, distance and bucket checks. Drops disappear when emptied and are not saved unless `persistence.persistDrops` is on.

Namespace: `exports.kora_inventory` · Source: `server.lua (dropCreate, dropTake, intentDrop, findMergeDrop), client/drops.lua`

## How it works

A UI drop removes the item from the player, then either merges it into the nearest existing drop within `drops.mergeRadius` (same bucket, with room) or creates a new drop at the player's server-side position. The new drop id is broadcast with `kora_inventory:client:dropCreated` (to every player, or only to players in the same routing bucket when `requireSameBucket` is on and a bucket was given). Clients that connect later fetch current drops (ids and coordinates, never contents) through the `kora_inventory:server:drops` callback. When the last item leaves, `kora_inventory:client:dropRemoved` removes the prop everywhere.

## How a player drop flows

1. **Drop intent** — The UI sends the `drop` intent with a slot and amount from the player's own inventory.
2. **Validation** — Session token and revision, the slot and amount, the slot not being busy, and the player entity existing.
3. **Merge or create** — The server looks for a nearby drop that can take the item; if none, it reserves a new id, runs the `swapItems` hook (`toInventory = 'newdrop'`) and creates the drop.
4. **Presentation** — Every client in range creates a local prop and a kora_target sphere that calls `openInventory('drop', id)`.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Merge radius | `drops.mergeRadius` metres: drops closer than this join an existing bag. |
| Bag prop | A local, non-networked object per client. It has no inventory identity; deleting it gains nothing. |

## Functions

Server exports for creating and emptying drops from your own code.

### `exports.kora_inventory:dropCreate(coords, items, bucket?)`

Creates a ground drop at a position with the given contents and announces it to clients. Slot count, distance and label come from config (`defaultSlots`, `dropDistance`, `Ground drop`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `coords` | vector3 \| table | World position `{ x, y, z }`. |
| `items` | table&lt;integer, table> | Slot-keyed instance tables. They are stored as given and are not validated, so pass full tables, for example copies from `GetItemBySlot`. |
| `bucket?` | integer | Routing bucket the drop belongs to. Omit for a global drop visible in every bucket. |

**Returns**

- **id** — integer id of the new drop. Open it with `openInventory('drop', id)`.

**Example**

```lua
local ped = GetPlayerPed(src)
local item = exports.kora_inventory:GetItemBySlot(src, 3)
if item and exports.kora_inventory:RemoveItem(src, item.name, item.amount, 3, 'dumped') then
    local c = GetEntityCoords(ped)
    local id = exports.kora_inventory:dropCreate({ x = c.x, y = c.y, z = c.z }, { [1] = item }, GetPlayerRoutingBucket(src))
end
```

**Representative console output**

```text
Returns 7. Nearby clients see a bag appear; walking up and interacting opens drop:7.
```

### `exports.kora_inventory:dropTake(src, id, slot, amount?)`

Takes items from a drop into a player's inventory. Opens the drop for the player first (access, distance and bucket checks) then moves the stack through the validated transfer funnel.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Receiving player. |
| `id` | integer \| string | Drop id. |
| `slot` | integer | Slot in the drop. |
| `amount?` | integer | Default the whole stack. |

**Returns**

- **taken** — true on success.
- **result** — `{ fromRevision, toRevision }` on success, or a reason such as `no such drop`, `too far away`, `different routing bucket`, `invalid item amount`, `over weight`, `no free slot`.

**Example**

```lua
local taken, result = exports.kora_inventory:dropTake(src, 7, 1)
if not taken then print('could not take:', result) end
```

**Representative console output**

```text
taken = true, result = { fromRevision = 12, toRevision = 31 }. If the drop is now empty the session closes and the bag disappears.
```

## Common use cases

- Dropping a dead player's loot as a bag.
- Spawning loot piles from a script.
- Picking items up from a drop in a scripted interaction.

## Limits and related APIs

Drops live only in memory unless `persistDrops` is true, so they are lost on restart by default. `dropCreate` does not validate or normalise items. Players must be within `dropDistance` (2.0) of the drop; the target prompt radius `drops.interactionDistance` should stay at or below it. `bucket` limits who sees and opens the drop.

## Related guides

- [Opening inventories](./inventories.md)
- [Configuration](./configuration.md)
- [Events and callbacks](./events.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

Dropping an item creates a temporary `drop` inventory at the player's position and a bag prop (`Config.kora_inventory.drops`). The prop is presentation only: a local, non-networked object created independently on each client. Interacting with it calls the normal open path with the drop id; the server re-checks existence, distance and routing bucket, so removing or faking the prop gains nothing. A drop within `mergeRadius` of an existing drop in the same bucket joins it.

Player-created drops belong to the player's routing bucket (`requireSameBucket`). `kora_inventory:server:drops` and the legacy drop list return ids and coordinates only. After a bucket change the five-second session cleanup closes old drop sessions and refreshes local bags.

```lua
-- server
local dropId = exports.kora_inventory:dropCreate(GetEntityCoords(ped), {
    [1] = { name = 'water_bottle', amount = 1, slot = 1 },
})
```

`dropCreate(coords, items, bucket?)` created by trusted code is global unless a `bucket` is passed. `dropTake(src, dropId, slot, amount?)` moves items out. Client events `kora_inventory:client:dropCreated`, `dropRemoved` and `dropsUpdated` let other client scripts track bags. Drops are persisted only when `persistence.persistDrops` is true.
