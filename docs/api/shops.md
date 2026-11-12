---
title: "Shops"
sidebar_position: 6
---


# Shops

A shop is a read-only inventory with finite stock and a price per row. Players buy through the inventory UI; the server re-resolves the shop, stock, price, access and payment inside one lock, charges the configured kora_core account, and adds the item. Four shops ship ready to use: Ammu-Nation, 24/7 convenience stores, liquor stores and vending machines. You can register your own the same way the bundled ones do.

Namespace: `exports.kora_inventory` · Source: `server.lua (registerShop, intentBuy, buyItem, shopGet, shopSet), server/shops/*.lua, config/shops/*.lua`

## How it works

Registration stores stock in the shop record and in `kora_inventory_shop_stock`. On a later start a restored shop keeps its stored stock and prices; registration only refreshes policy (label, size, coords, access, prices). Items can only leave a shop through a purchase (`shop items must be purchased`), and nothing can be moved into it (`shop inventory is read only`); use `SetShopItems` to restock. A purchase does this under a lock on the shop and the player: re-validate the session, check stock and the player's balance, run the `buyItem` hook (cancel here means nothing was charged), call `removeMoney`, run the `createItem` hook, add the item (weapons get serial, durability and ammo metadata), and refund in full (no tax) if the add fails. On success the stock drops, both inventories are bumped and patched, an audit entry is recorded, a purchase receipt is shown and `kora_inventory:server:itemPurchased` fires.

## Selling items in your own shop

1. **Register the shop on start** — Call `RegisterShop(id, data)` with stock rows, a `currency`, and a location boundary (`coords` + `distance`, or an `access` callback).
2. **Add a client trigger** — Use a kora_target zone or ped that calls `exports.kora_inventory:openInventory('shop', id)`. This is only convenience; the server validates the position again.
3. **Restock or reprice from the server** — `GetShopItems` reads the shelf, `SetShopItems` replaces it. Rows keep their own `price`.
4. **Observe sales** — Listen to `kora_inventory:server:itemPurchased` for business logic, or register a `buyItem` hook to veto or log purchases.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Stock row | A shelf entry with `name`, `amount`, `price` and optional `slot`, `info`. |
| Currency | The kora_core account charged. `'money'` means the `cash` account; any other value is used as the account name. |
| Catalogue shop | A shop whose stock is not a container load; register with `weightLimit = false` so restocks are never refused for weight. |

## RegisterShop data table

All keys are optional except stock rows you want on sale.

| Option | Type | Description |
| --- | --- | --- |
| `label` | string | Display name. Defaults to the id. |
| `slots` | integer | Number of shelf slots (at least 1). Default `defaultSlots`. |
| `maxWeight` | number | Weight cap of the shelf. Default `defaultMaxWeight`. |
| `weightLimit` | boolean | Default true. `false` lets seed stock and `SetShopItems` exceed `maxWeight`. Not persisted. |
| `currency` | string | kora_core account to charge. Default `'money'` (cash). |
| `inventory / items` | table[] | Stock rows. Each needs `name`, `amount` (or `count`, default 1) and a non-negative `price`; `slot` defaults to the row's index; `info`/`metadata` sets instance metadata. A row naming an unknown item rejects the whole registration. |
| `prices` | table&lt;string, number> | Fallback unit price by item name for rows without their own `price`. |
| `coords` | vector3 \| table \| table[] | Where the shop can be used. Omit and the shop is usable from anywhere unless `access` denies. |
| `distance` | number | Reach in metres. Default `interactionDistance`. |
| `groups` | table&lt;string, integer> | Restrict to a job or gang grade. |
| `owner` | integer \| string | Restrict to one player. |
| `access` | function | `access(source, inventory, opts)`; return truthy to allow. The bundled shops use this to check the player is at an approved counter. |

## Bundled shops

Ammu-Nation (`ammunation`, 32 slots, weapons and ammo, finite stock topped up every `restockIntervalMinutes` = 30, shopkeeper peds), 24/7 (`convenience`, 16 slots, food and drink, clerk peds, can be disabled with `enabled = false`), Rob's Liquor (`liquorstore`, 16 slots, beer, whiskey and snacks) and vending machines (`vendingmachine`, 2 slots, water and soda). All charge cash. The first three verify that the player stands within `interactionDistance` of one of the configured `locations` in the listed routing `bucket`. Vending machines have no location list: the client sends the machine's coordinates with the open request, the server checks the player's live position against them, and the approval is remembered for `sessionTtl` (sliding) so a long purchase is not cut off.

## Restocking

Ammu-Nation tops every configured row back up to its `amount` on a timer (never lowering a row). With `limitedStock = false` a row is refilled right after each purchase. A restock writes the whole shelf with `SetShopItems`; if one row cannot be written (for example over weight with `weightLimit = true`) it retries row by row and logs which rows failed. Persisted stock keeps its slots, so reordering the config after launch leaves differently ordered rows that are reported once and skipped.

## Pricing and failures

Unit price is the row's `price`, else `prices[name]`, else 0 (free). Totals are `price * count`. Failure reasons from purchases: `out of stock`, `insufficient funds` (balance check), the `removeMoney` error, `over weight` / `no free slot` (refunded), a hook reason, or an access reason. Stock rows written with `SetShopItems` are not price-validated, so always include `price`.

## Functions

Shop exports are server-only. The bundled shops call `RegisterShop` themselves; use the same calls for your own.

### `exports.kora_inventory:RegisterShop(id, data?)`

Registers a shop, or refreshes the policy of an existing (possibly restored) one while keeping its stock. Stock rows are turned into canonical, registry-backed item records. Alias `registerShop`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Shop id; becomes `shop:<id>`. |
| `data?` | table | See the RegisterShop data table above. |

**Returns**

- **inventoryKey** — `shop:<id>` on success, or nil.
- **reason** — `invalid shop slots`, `shop inventory must be a table`, `invalid shop item`, `invalid or duplicate shop slot`, `invalid shop amount or price`, `physical cash cannot be shop stock`, `invalid shop item in slot N: unknown item`.

**Example**

```lua
local key, err = exports.kora_inventory:RegisterShop('hardware', {
    label = 'Hardware Store', slots = 12, maxWeight = 60000, currency = 'cash',
    coords = vector3(2747.7, 3472.9, 55.7), distance = 2.5,
    inventory = {
        { name = 'lockpick', amount = 25, price = 150 },
        { name = 'water_bottle', amount = 60, price = 8 },
    },
})
if not key then print('shop registration failed: ' .. tostring(err)) end
```

**Representative console output**

```text
key = 'shop:hardware'. On the next restart the stored stock is kept and only the policy is refreshed.
```

### `exports.kora_inventory:GetShopItems(id)`

Returns a copy of a shop's current stock (slot-keyed, each row with its `price`). Unlike stashes it never creates a shop. Aliases `getShopItems` and `shopGet`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Shop id. |

**Returns**

- **items** — slot-keyed stock table, or nil with the reason `shop not found`.

**Example**

```lua
local stock, err = exports.kora_inventory:GetShopItems('hardware')
if not stock then return print(err) end
for slot, row in pairs(stock) do print(slot, row.name, row.amount, row.price) end
```

**Representative console output**

```text
1 lockpick 25 150
2 water_bottle 60 8
```

### `exports.kora_inventory:SetShopItems(id, items)`

Replaces the shelf of an existing shop (restocking, repricing, player-run shops). Rows are validated as items (known name, slot range, amount) but not for price. Aliases `setShopItems` and `shopSet`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string \| number | Shop id; unknown ids are rejected. |
| `items` | table&lt;integer, table> | Slot-keyed rows `{ name, amount, price, info? }`. |

**Returns**

- **updated** — true on success.
- **reason** — `shop not found`, `items must be a table`, `invalid item table`, `over weight` (unless the shop was registered with `weightLimit = false`), `inventory is locked`.

**Example**

```lua
local stock = exports.kora_inventory:GetShopItems('hardware')
stock[1].amount = 25   -- restock lockpicks
stock[1].price = 175   -- and raise the price
local ok, reason = exports.kora_inventory:SetShopItems('hardware', stock)
```

**Representative console output**

```text
ok = true; players with the shop open see the new shelf immediately.
```

### `exports.kora_inventory:BuyItem(src, shopId, slot, count?)`

Server-side purchase on behalf of a player: opens the shop for them (which runs the access and distance checks and replaces their current session), then performs the same locked purchase as the UI. No item receipt box is shown on this path. Alias `buyItem`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Buying player. |
| `shopId` | string \| number | Shop id. |
| `slot` | integer | Shelf slot. |
| `count?` | integer | Default 1. |

**Returns**

- **purchased** — true on success.
- **reason** — `shop not found`, an access reason, `out of stock`, `insufficient funds`, a hook reason, `over weight`, `no free slot`.

**Example**

```lua
local ok, reason = exports.kora_inventory:BuyItem(src, 'hardware', 1, 2)
if not ok then
    Kora.notify.send(src, { title = 'Shop', message = tostring(reason), type = 'error' })
end
```

**Representative console output**

```text
ok = true: price * 2 is charged to the shop's currency account and two lockpicks are added.
```

## Common use cases

- A server-defined store at a fixed location with finite stock.
- Player-run business shelves restocked by a business resource.
- Dynamic pricing by rewriting rows with `SetShopItems`.
- Vetoing or logging sales with a `buyItem` hook.

## Limits and related APIs

A shop is read-only to transfers. Stock added through `SetShopItems` has no price validation. The `access` callback is the only way to express rules beyond coords, groups and owner. Hook cancellations before payment charge nothing; a failed add after payment is refunded in full. Purchases on a shop with no `coords` and no `access` can be attempted from anywhere.

## Related guides

- [Hooks](./hooks.md)
- [Persistence](./persistence.md)
- [Events and callbacks](./events.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

### Registering a shop

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

### Bundled shops

Configured in `config/shops/*.lua`, each with server-side location validation (the player's server ped position and routing bucket must be at a configured counter).

| Shop | File | Notes |
| --- | --- | --- |
| 24/7 convenience | `convenience.lua` | `Config.kora_inventory.shops.convenience`; `enabled = false` removes the shop, targets and blips. Counters with a `ped` spot get a clerk. |
| Liquor | `liquorstore.lua` | Five "Rob's Liquor" counters, every one with a clerk. |
| Ammu-Nation | `ammunation.lua` | Finite stock, shopkeeper peds, restock timer. |
| Vending machine | `vendingmachine.lua` | Targets the prop models (`prop_vend_soda_01`, `prop_vend_soda_02`, `prop_vend_water_01`, `prop_vend_coffe_01`) through `kora_target`'s `addModel`; sells `water_bottle` and `soda`. |

Common fields: `id`, `label`, `slots`, `maxWeight`, `currency`, `interactionDistance`, `inventory`, `locations`, `blip` (`enabled`, `sprite`, `color`, `scale`, `shortRange`, `category`, `name`). `blip.category` must be a `Kora.blips` category; an unknown value logs a warning and the blip has no category. A location may set `bucket` and a `ped = { x, y, z, heading }` spot (`z` is floor height).

#### Ammu-Nation options

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

#### Markers, clerks and labels

`Config.ShopHints` and `Config.ShopClerks` (see [Configuration](./configuration.md)). With the defaults only the 24/7 counters without a ped spot (Senora Fwy, Grapeseed) show a marker; every other counter has a clerk or shopkeeper ped. The clerk exists only within `radius` of the player and offers "Open shop" through `kora_target`. Peds are removed when the resource stops.

A buy made while another is in flight waits for it, and a refusal is reported once, by the bundled UI.

### Events fired

`kora_inventory:server:itemPurchased` after each purchase and the `buyItem` hook, see [Events](./events.md) and [Hooks](./hooks.md).
