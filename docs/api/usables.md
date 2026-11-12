---
title: "Usable items"
sidebar_position: 8
---


# Usable items

A usable item is an item with a server handler. The player presses Use in the inventory (or a hotbar key), the client optionally runs the item's `useTime` progress bar, and the server runs your handler with the player and a copy of the item. This page covers registering handlers, how a use is validated, and the handlers kora_inventory ships itself.

Namespace: `exports.kora_inventory` · Source: `server.lua (createUseable, getUseable, useItem), server/useables.lua, server/containers.lua`

## How it works

Use always goes through `useItem(src, slotOrName)`: the item is re-read from the server (a client only ever sends a slot), the downed and cuffed rules apply, the ox `usingItem` hook can cancel, portable containers open instead of running a handler, and otherwise `useables[name]` (your registration) wins over `builtInUseables[name]` (weapons, ammo, parachute). While the handler runs the slot is marked busy so it cannot be dropped, given or moved; the mark is cleared when the handler returns, errors or `busyTimeout` passes. The handler runs in `pcall`, so an error never breaks the inventory. After a successful use the panel closes unless the item sets `preventClose`/`shouldClose = false`.

## Adding a usable item

1. **Register the item** — Add it to the `items` registry with `useable = true` (and optionally `useTime`, `preventClose`).
2. **Register the handler** — `createUseable(name, function(src, item) ... end)` on the server, on every start.
3. **Do the work yourself** — The inventory does not consume the item for you. Call `RemoveItem(src, item.name, 1, item.slot, reason)` when the use succeeds, and return false if it must be refused.
4. **Tell the client** — Trigger your own client event for effects. Keep any authority (healing, money, rewards) on the server.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Handler | A function `(src, item)` called on the server. `item` is a detached copy of the slot. |
| useTime | Item field: milliseconds of progress bar the client runs before it sends the use request. A cancelled bar sends nothing. |
| Busy slot | A slot whose handler is still running; drop, give and move are refused for it. |
| Built-in handler | A handler kora_inventory registers itself (weapons, ammo, parachute, simple consumables). |

## Handler contract

Return `false` to refuse the use: the player gets `item use was rejected` and no `usedItem` event fires. Returning anything else (including nothing) counts as success. A handler that raises an error returns the error message as the failure reason. The item is not consumed automatically.

## No handler registered

If an item exists but no handler does, the server fires `QBCore:Server:UseItem(src, item)` for legacy scripts and returns `false, 'no useable registered'`. This keeps stock qb scripts that listen for that event working.

## Built-in handlers

Weapons: using a weapon draws or holsters it through weapon carry (the item stays in the slot). Ammo: any registry item with `ammoType` and a positive `rounds` loads into the weapon the player currently has drawn, if its `ammotype` matches, adding exactly `rounds` individually tracked rounds (limited by `weapons.maxAmmo` and `ballistics.maxLoadedRounds`) and consuming one item; with no weapon drawn it fails with `draw a weapon before loading ammunition`. Parachute: shows a cancellable progress bar, gives `GADGET_PARACHUTE`, wears the pack, and consumes one item only after the client reports it equipped (disable with `builtinUsables.parachute = false`). Food, drink, alcohol and drug items have no built-in handler here: `kora_consumables` registers those use handlers. Another resource that calls `createUseable` for the same name replaces these.

## Portable containers

Items listed in `Config.kora_inventory.containers.items` (the shipped `backpack`) never reach a handler. Use binds a container to that unique item on first use and opens it; `kora_inventory:server:openedContainer` fires.

## Hotbar and legacy event

Hotbar keys and the legacy `QBCore:Server:UseItem` net event send only a slot and item name. The server compares the name with the real slot before using it, so a forged table is ignored.

## Functions

Handlers are registered from the server resource that owns the behaviour. When that resource stops its handlers are removed automatically.

### `exports.kora_inventory:createUseable(name, handler)`

Registers (or replaces) the server handler for an item name. The handler is owned by the calling resource and removed when it stops. Raises a Lua error if `name` is not a string or `handler` is not callable. Aliases `CreateUsableItem` and, through kora_core, `QBCore.Functions.CreateUseableItem`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name (case-sensitive; use the lower-case registry name). |
| `handler` | function | `handler(src, item)`. Return false to refuse. |

**Returns**

- **No return value.**

**Example**

```lua
exports.kora_inventory:createUseable('bandage', function(src, item)
    local removed = exports.kora_inventory:RemoveItem(src, item.name, 1, item.slot, 'used bandage')
    if not removed then return false end
    exports.kora_core:incrementMetaData(src, 'health', 25, 0, 100)
    return true
end)
```

**Representative console output**

```text
Pressing Use on a bandage removes one and runs your effect; the panel closes afterwards.
```

### `exports.kora_inventory:CreateUsableItem(name, handler)`

Alias of `createUseable` under the qb-style name.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name. |
| `handler` | function | `handler(src, item)`. |

**Returns**

- **No return value.**

**Example**

```lua
exports.kora_inventory:CreateUsableItem('radio', function(src, item)
    TriggerClientEvent('myradio:client:toggle', src)
end)
```

**Representative console output**

```text
Registers the handler exactly as `createUseable` does.
```

### `exports.kora_inventory:getUseable(name)`

Returns the handler record for an item, whether registered by a resource or built in.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `name` | string | Item name. |

**Returns**

- **record** — `{ func, resource }` (resource is `kora_inventory` for built-ins), or nil when no handler exists.

**Example**

```lua
local record = exports.kora_inventory:getUseable('water_bottle')
if record then print(record.resource) end
```

**Representative console output**

```text
kora_inventory
```

### `exports.kora_inventory:useItem(src, slotOrName)`

Uses an item for a player exactly as pressing Use does: validation, hooks, busy lock, handler, `usedItem` event.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `slotOrName` | integer \| string | A slot number, or an item name (the first stack found). |

**Returns**

- **used** — true when the handler (or container open) succeeded.
- **result** — on failure: `item not found`, `you cannot use items while downed`, `you cannot use items while cuffed`, a `usingItem` hook reason, `item is currently being used`, the handler's error text, `item use was rejected`, `no useable registered`, or a container error.

**Example**

```lua
local used, why = exports.kora_inventory:useItem(src, 'sandwich')
if not used then print('could not eat:', why) end
```

**Representative console output**

```text
used = true after the sandwich handler consumed one item.
```

## Common use cases

- Food, drink and medical items with effects handled by a gameplay resource.
- Tool items (lockpicks, radios) that trigger a client interaction.
- Replacing a built-in consumable with your own handler.

## Limits and related APIs

Handlers are not saved and must be registered at every start. Do not hold long-running work without `useTime` or a client progress bar: the slot stays locked until the handler returns, up to `busyTimeout` (30 s). Weapons cannot be given a custom handler without replacing the built-in draw behaviour. Cancelled client progress bars send nothing, so never rely on the client to report completion.

## Related guides

- [Items and metadata](./items.md)
- [Hooks](./hooks.md)
- [Weapons and weapon carry](./weapons.md)
- [Events and callbacks](./events.md)
