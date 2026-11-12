---
title: "Crafting"
sidebar_position: 9
---


# Crafting

A headless crafting engine: server resources register recipes (ingredients in, items out) and call `CraftItem` after they have checked the station, job and distance. The engine plans the whole transaction against the player's inventory, applies it in one write, and fires events. There is no client or NUI entry point on purpose.

Namespace: `exports.kora_inventory` · Source: `server/crafting.lua`

## How it works

A craft takes a lock on the player's inventory, copies their items, subtracts every ingredient (slots lowest first, optionally matching metadata), inserts every output (unique items one per free slot with a fresh serial, stackable outputs onto a matching stack or the first free slot), checks the final weight against the player limit, runs hooks, then replaces the player's items in a single write. If any step fails nothing is changed. Because it writes the whole item table, crafted outputs do not trigger `createItem` hooks or item receipts.

## Adding a crafting station

1. **Register recipes on start** — `RegisterCraftRecipe(id, recipe)` with ingredients and output. Add an `access` callback for rules you can check from the recipe alone.
2. **Validate the interaction** — In your own server event verify the player is at the station, has the job, and has not exceeded rate limits. Never accept a recipe id from a client without checking it is allowed at that station.
3. **Optionally preview** — `CanCraftRecipe(src, id, amount)` tells you whether it would fit, without running access callbacks or hooks.
4. **Craft** — `CraftItem(src, id, context, amount)` commits the transaction and returns the outputs.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Recipe | A server-registered definition: `ingredients`, one or more `outputs`, optional `label`, `station`, `access`. |
| Context | Opaque trusted data you pass to `CraftItem`; it reaches the recipe `access` callback and craft hooks. Never forward a client table. |
| Batch amount | How many times the recipe runs in one call, 1 to `crafting.maxBatchAmount` (100). |

## Recipe table

Fields accepted by `RegisterCraftRecipe`. Unknown item names are rejected.

| Option | Type | Description |
| --- | --- | --- |
| `ingredients / items` | table | Array of `{ name, amount, metadata? }`, or a map `name -> amount`, or `name -> { amount, metadata }`. Amounts are positive integers (default 1). `metadata` (or `info`) must be a subset of the item's metadata to match. At least one ingredient is required. |
| `output / result` | table | One output `{ name, amount, metadata? }` (`item` and `count` are accepted as aliases). |
| `outputs / give` | table[] | Several outputs; takes precedence over `output`. Weapon outputs get canonical weapon metadata and a new serial each. |
| `label` | string | Display label. Defaults to the id. |
| `station` | string | Free-form station tag stored with the recipe for your own use. |
| `access` | function | `access(source, recipe, context)`; return false (optionally `false, reason`) to deny. Errors deny with `crafting policy failed`. |

## Functions

All crafting exports are server-only. Recipes belong to the resource that registered them.

### `exports.kora_inventory:RegisterCraftRecipe(id, recipe)`

Registers or updates a recipe. Re-registering your own id replaces it; an id owned by another resource is refused. Recipes are removed when their resource stops.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Recipe id: letters, digits, `_ . -`, at most 96 characters. |
| `recipe` | table | See the recipe table. |

**Returns**

- **registered** — true on success.
- **reason** — `invalid recipe id`, `recipe must be a table`, `recipe ingredients are required`, `unknown recipe ingredient`, `recipe output is required`, `recipe outputs are required`, `unknown recipe output`, `recipe is owned by another resource`.

**Example**

```lua
local ok, err = exports.kora_inventory:RegisterCraftRecipe('workbench.repairkit', {
    label = 'Repair Kit',
    ingredients = { metalscrap = 4, plastic = 2 },
    output = { name = 'vehicle_repair_kit', amount = 1 },
    station = 'workbench',
    access = function(source, recipe, context)
        if type(context) ~= 'table' or context.station ~= 'workbench' then return false, 'wrong station' end
    end,
})
```

**Representative console output**

```text
ok = true. The recipe is now available to CraftItem.
```

### `exports.kora_inventory:RemoveCraftRecipe(id)`

Removes a recipe registered by the calling resource.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Recipe id. |

**Returns**

- **removed** — true; false when the recipe does not exist; false with `not recipe owner` when another resource owns it.

**Example**

```lua
exports.kora_inventory:RemoveCraftRecipe('workbench.repairkit')
```

**Representative console output**

```text
true
```

### `exports.kora_inventory:GetCraftRecipe(id)`

Returns a copy of a registered recipe in normalised form (`id, label, ingredients, output, outputs, station`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Recipe id. |

**Returns**

- **recipe** — table or nil.

**Example**

```lua
local recipe = exports.kora_inventory:GetCraftRecipe('workbench.repairkit')
if recipe then print(recipe.label, #recipe.ingredients) end
```

**Representative console output**

```text
Repair Kit 2
```

### `exports.kora_inventory:CanCraftRecipe(src, recipeId, amount?)`

Checks whether the player's current inventory can complete a registered recipe: all ingredients present, outputs fit in slots and weight. Does not run the access callback or hooks and does not reserve anything.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `recipeId` | string | Recipe id. |
| `amount?` | integer | Batch count, default 1, at most `maxBatchAmount`. |

**Returns**

- **possible** — boolean.
- **reason** — `unknown recipe`, `invalid crafting amount`, `missing crafting ingredient: <name>`, `no free slot for recipe output`, `over weight`, `player inventory not found`.

**Example**

```lua
local ok, why = exports.kora_inventory:CanCraftRecipe(src, 'workbench.repairkit', 3)
if not ok then print(why) end
```

**Representative console output**

```text
false, 'missing crafting ingredient: metalscrap'
```

### `exports.kora_inventory:CanCraftItems(src, ingredients, outputs)`

Capacity query for a transaction you define yourself (no registered recipe): can the player give up `ingredients` and receive `outputs` within slots and weight. Ingredients match by name only. With physical cash on, cash-item outputs are counted net of tax.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `ingredients` | table | Same shapes as a recipe's ingredients; may be empty. |
| `outputs` | table[] | Array of `{ name, amount, metadata? }`. |

**Returns**

- **possible** — boolean.
- **reason** — `source is required`, an ingredient/output error, `missing crafting ingredient: <name>`, `no free slot for recipe output`, `over weight`.

**Example**

```lua
local ok, why = exports.kora_inventory:CanCraftItems(src, { { name = 'weed', amount = 5 } }, { { name = 'weed_baggy', amount = 1 } })
```

**Representative console output**

```text
true
```

### `exports.kora_inventory:CraftItem(src, recipeId, context?, amount?)`

Runs a registered recipe for a player. Order: amount validation, recipe `access`, plan, craft hooks (`RegisterCraftHook`), ox `craftItem` hooks, atomic write, ox post events, `kora_inventory:server:crafted`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `recipeId` | string | Recipe id. |
| `context?` | any | Trusted data for the access callback and hooks, for example `{ station = 'workbench', benchId = 3 }`. Never pass a raw client payload. |
| `amount?` | integer | Batch count, default 1. |

**Returns**

- **crafted** — true on success.
- **result** — on success the output entry `{ name, amount, metadata }` (an array when the recipe has several outputs, amounts already multiplied); on failure a reason from the list under `CanCraftRecipe`, `crafting denied`, `crafting policy failed`, or a hook reason.

**Example**

```lua
RegisterNetEvent('workbench:server:craft', function(stationId)
    local src = source
    if not isAtStation(src, stationId) then return end     -- your own server-side check
    local ok, result = exports.kora_inventory:CraftItem(src, 'workbench.repairkit', { station = 'workbench', benchId = stationId }, 1)
    if not ok then
        Kora.notify.send(src, { title = 'Workbench', message = tostring(result), type = 'error' })
    end
end)
```

**Representative console output**

```text
ok = true, result = { name = 'vehicle_repair_kit', amount = 1, metadata = {} }; four metalscrap and two plastic are gone in the same write.
```

### `exports.kora_inventory:RegisterCraftHook(callback)`

Registers a callback run before every craft of any recipe. Return false (optionally with a reason) to cancel. Hooks are removed when their resource stops.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `callback` | function | `callback({ source, recipe, inventory, context, amount })`; `recipe` is a copy. |

**Returns**

- **hookId** — integer for `RemoveCraftHook`.

**Example**

```lua
local id = exports.kora_inventory:RegisterCraftHook(function(info)
    if info.recipe.station == 'workbench' and isRaidActive() then return false, 'workbench is closed during raids' end
end)
```

**Representative console output**

```text
hookId = 1
```

### `exports.kora_inventory:RemoveCraftHook(id)`

Removes a craft hook registered by the calling resource.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | integer | Id from `RegisterCraftHook`. |

**Returns**

- **removed** — true; false when unknown; false with `not hook owner` for another resource's hook.

**Example**

```lua
exports.kora_inventory:RemoveCraftHook(id)
```

**Representative console output**

```text
true
```

## Common use cases

- Workbenches, kitchens and drug labs with server-defined recipes.
- Batch crafting limited by `maxBatchAmount`.
- Pre-checking capacity before charging money for a service.

## Limits and related APIs

Crafting has no client entry point. The whole item table is rewritten, so crafted outputs skip `createItem` hooks and item receipt boxes; trigger your own notification. Recipe `metadata` matching is a subset test (every listed key must match). `CanCraftRecipe` and `CanCraftItems` are advisory and do not reserve capacity. Recipes are not persisted and must be registered on every start.

## Related guides

- [Items and metadata](./items.md)
- [Hooks](./hooks.md)
- [Weapons and weapon carry](./weapons.md)
- [Events and callbacks](./events.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

`server/crafting.lua` is a headless, server-only recipe and craft API. It registers no network event or NUI callback and ships no station discovery, progress timer or UI. The resource that owns the crafting station resolves station, job, proximity, routing-bucket and progression checks on the server, then calls `CraftItem`. Never forward a client recipe, output, item metadata, count or context to these exports.

### Registering a recipe

```lua
exports.kora_inventory:RegisterCraftRecipe('repair_board', {
    label = 'Repair board',
    ingredients = { { name = 'wood', amount = 2, metadata = { grade = 'oak' } } },
    outputs = {
        { name = 'board', amount = 1, metadata = { quality = 100 } },
        { name = 'sawdust', amount = 2 },
    },
    access = function(source, recipe, context)
        -- context is server-owned station state, never a raw client payload
        return true
    end,
})
```

- The id is a string of up to 96 characters from letters, digits, `_`, `.` and `-`.
- `ingredients` (or `items`) are required; outputs are `outputs` (or `give`), or the legacy singular `output` / `result`. Each output item must exist in kora_core's registry.
- `access` is optional and receives `(source, recipe, context)`. `station` is an optional string label.
- Only the registering resource may re-register or remove its recipe. Recipes and craft hooks are removed when their owner resource stops.

### Exports

| Export | Returns | Notes |
| --- | --- | --- |
| `RegisterCraftRecipe(id, recipe)` | `true` or `false, reason` | |
| `RemoveCraftRecipe(id)` | `true` or `false, reason` | Owner only. |
| `GetCraftRecipe(id)` | copy of the recipe or `nil` | |
| `CanCraftRecipe(source, recipeId, amount?)` | `true` or `false, reason` | Read-only plan of ingredients, outputs, slots and weight. Runs no access callback or hook and changes nothing. |
| `CanCraftItems(source, ingredients, outputs)` | `true` or `false, reason` | Same check for an ad hoc list, without a registered recipe. |
| `CraftItem(source, recipeId, trustedContext, amount?)` | `true, result` or `false, reason` | Runs access callback, craft hooks and the `craftItem` ox hook, then commits. |
| `RegisterCraftHook(callback)` / `RemoveCraftHook(id)` | id / boolean | Owner only. |

`amount` defaults to one and is bounded by `Config.kora_inventory.crafting.maxBatchAmount` (`100`). A batch scales every ingredient and output and is committed in one locked transaction. A failed craft changes no slot.

A craft hook callback receives one table: `source`, `recipe`, `inventory` (the player inventory key), `context` and `amount`. A falsy return rejects the craft (a second return value is used as the reason). Hooks can approve or reject but cannot change the plan.

After a successful craft the server event `kora_inventory:server:crafted` (`src, recipeId, result`) fires.
