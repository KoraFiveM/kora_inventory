---
title: Shops
sidebar_position: 8
---

# Shops

## Registering a shop

```lua
-- server
exports.kora_inventory:registerShop('hardware', {
    label = 'Hardware',
    slots = 5,
    maxWeight = 50000,
    currency = 'cash',
    coords = vector3(45.0, -1750.0, 29.6),
    distance = 2.5,
    inventory = {
        { slot = 1, name = 'lockpick', amount = 50, price = 120 },
    },
})

-- client
exports.kora_inventory:openInventory('shop', 'hardware')
```

- Stock rows need `name`, `amount` (or `count`) and a non-negative `price`; every row is built through the item registry, so unknown items are rejected. Physical cash cannot be stock.
- `coords` accepts one point or a list, like stashes.
- `RegisterShop` seeds stock only for a shop that was not restored from the database; a restored shop keeps its persisted stock and prices.
- The generic transfer path refuses shop inventories. Items leave a shop only through the `buy` intent, which revalidates the session, stock, both revisions, access, distance and payment. A failed add after payment is refunded.
- `buyItem(src, shopId, slot, count?)` performs the same purchase from server code. It opens the shop for the player (so access and distance checks apply) and **takes the payment itself** through kora_core; do not charge the player first.
- `shopGet(id)` and `shopSet(id, items)` (aliases `GetShopItems`, `SetShopItems`) change stock or prices after registration. They reject unknown ids. `shopSet` refuses a shelf heavier than the shop's `maxWeight` unless the shop registered with `weightLimit = false` (registration-time policy, not persisted).

Shop `access(source, inventory, opts)` callbacks are called with the raw client open request as third argument, which lets a shop with no fixed location list (vending machines) verify client-reported coordinates against the server position.

## Bundled shops

Configured in `config/shops/*.lua`, each with server-side location validation (the player's server ped position and routing bucket must be at a configured counter).

| Shop | File | Notes |
| --- | --- | --- |
| 24/7 convenience | `convenience.lua` | `Config.kora_inventory.shops.convenience`; `enabled = false` removes the shop, targets and blips. Counters with a `ped` spot get a clerk. |
| Liquor | `liquorstore.lua` | Five "Rob's Liquor" counters, every one with a clerk. |
| Ammu-Nation | `ammunation.lua` | Finite stock, shopkeeper peds, restock timer. |
| Vending machine | `vendingmachine.lua` | Targets the prop models (`prop_vend_soda_01`, `prop_vend_soda_02`, `prop_vend_water_01`, `prop_vend_coffe_01`) through `kora_target`'s `addModel`; sells `water_bottle` and `soda`. |

Common fields: `id`, `label`, `slots`, `maxWeight`, `currency`, `interactionDistance`, `inventory`, `locations`, `blip` (`enabled`, `sprite`, `color`, `scale`, `shortRange`, `category`, `name`). `blip.category` must be a `Kora.blips` category; an unknown value logs a warning and the blip has no category. A location may set `bucket` and a `ped = { x, y, z, heading }` spot (`z` is floor height).

### Ammu-Nation options

| Option | Default | Meaning |
| --- | --- | --- |
| `shopkeeper.enabled` | `true` | Clerk ped at each location with a `ped` spot. |
| `shopkeeper.model`, `shopkeeper.radius` | `s_m_m_ammucountry`, `60.0` | Ped model and the distance within which the client-side ped exists. |
| `locations[n].shopkeeper` | unset | `false` removes the ped from that store. |
| `locations[n].shopkeeperUnlessStarted` | `kora_mdt` at Legion Square | Skip this store's ped while that resource runs. |
| `limitedStock` | `true` | `false` refills a purchased row right after the sale. |
| `restockIntervalMinutes` | `30` | Tops each row back up to its configured `amount`; `0` disables. A restock never lowers a level. Failures are logged per row. |
| `weightLimit` | `false` | `false` makes the shelf a catalogue so restocks are never refused for weight. |

The stock includes standard weapons and the `pistol_ammo`, `smg_ammo`, `shotgun_ammo`, `rifle_ammo`, `mg_ammo` and `snp_ammo` packs.

### Markers, clerks and labels

`Config.ShopHints` and `Config.ShopClerks` (see [Configuration](./configuration.md)). With the defaults only the 24/7 counters without a ped spot (Senora Fwy, Grapeseed) show a marker; every other counter has a clerk or shopkeeper ped. The clerk exists only within `radius` of the player and offers "Open shop" through `kora_target`. Peds are removed when the resource stops.

A buy made while another is in flight waits for it, and a refusal is reported once, by the bundled UI.

## Events fired

`kora_inventory:server:itemPurchased` after each purchase and the `buyItem` hook, see [Events](./events.md) and [Hooks](./hooks.md).
