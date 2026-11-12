---
title: Crafting
sidebar_position: 12
---

# Crafting

`server/crafting.lua` is a headless, server-only recipe and craft API. It registers no network event or NUI callback and ships no station discovery, progress timer or UI. The resource that owns the crafting station resolves station, job, proximity, routing-bucket and progression checks on the server, then calls `CraftItem`. Never forward a client recipe, output, item metadata, count or context to these exports.

## Registering a recipe

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

## Exports

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
