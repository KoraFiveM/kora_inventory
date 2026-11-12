---
title: Configuration
sidebar_position: 3
---

# Configuration

Configuration is in `config.lua` (shared) and `config/shops/*.lua` (one file per bundled shop). Most values are under the `Config.kora_inventory` table. When `kora_lib`'s `Kora.config` is available, `config.lua` registers metadata for selected keys (marked "live" below) so they can be edited at runtime; per-server overrides are generated into `config.local.lua`, which is git-ignored.

Server-only keys (callbacks, trust policy) are never sent to clients. The only table sent to the browser is `Config.kora_inventory.ui` (see [UI](./ui.md)).

## Top-level keys

| Key | Default | Meaning |
| --- | --- | --- |
| `Config.showTargetHints` | `nil` | Floating icon over shop counters. `nil` follows `kora_target`, `true`/`false` force it. Live. |
| `Config.SerialPrefix` | `'KORA'` | Prefix of new weapon serials. Upper-cased, reduced to A-Z0-9, max 12 characters; empty falls back to `KORA`. Existing serials are never rewritten. |
| `Config.Inspector.decimals` | `1` | Decimals shown for fractional metadata (0-3). |
| `Config.Inspector.allowCopy` | `true` | Lets the inspector text be selected and shows a Copy button that copies the item as JSON. |
| `Config.Slots.borderWidth` | `2` | Slot border thickness in CSS pixels (1-4), also used for the hotbar frame. |
| `Config.Hotbar.bottomOffset` | `90` | Distance in px from the screen bottom to the on-screen hotbar, on foot. |
| `Config.Hotbar.vehicleBottomOffset` | `130` | Same, in a vehicle. |
| `Config.ShopHints` | see below | Marker and optional text at fixed shop points. |
| `Config.ShopClerks` | see below | Clerk peds at 24/7 and liquor counters. |

### Config.ShopHints

`enabled` (`true`), `drawDistance` (`10.0` m), `alpha` (`160`), `marker` (`type` 20, `scale`, `zOffset`, `bob`, `rotate`), `markerAtPeds` (`false`: also draw at counters served by a ped), `showText` (`false`: draw locale key `shop_hints.text` above the marker at counters without a ped). Set `hint = false` on a shop config to opt that shop out. Vending machines are model targets without a fixed point and get no marker.

### Config.ShopClerks

`enabled` (`true`), `showLabel` (`false`), `model` (`s_m_m_ammucountry`), `scenario` (`WORLD_HUMAN_CLIPBOARD`, empty string = stand still), `radius` (`40.0` m, the ped exists only within this distance of the player), `interactionDistance` (`3.0`). A shop may override with `clerk = { model, scenario, radius, enabled }` or `clerk = false`; a location may set `ped.model`, `ped.scenario` or `clerk = false`. With `enabled = false` the old counter zone is used.

## Config.kora_inventory

### Inventory limits and behaviour

| Key | Default | Meaning |
| --- | --- | --- |
| `playerSlots` | `41` | Player inventory slots. |
| `playerMaxWeight` | `120000` | Player carry limit (grams). |
| `defaultSlots` | `50` | Default slots for stashes, shops and drops. |
| `defaultMaxWeight` | `100000` | Default weight limit for stashes, shops and drops. |
| `stackableWeapons` | grenade, molotov | Weapons that stack in one slot instead of one slot each (no serial). Only affects items added afterwards. |
| `hotbarSlots` | `5` | Slots `1..hotbarSlots` are the number-key hotbar and the range treated as openly carried by `weaponCarry.visibility = 'hotbar'`. `0` disables the key binds. |
| `interactionDistance` | `3.0` | Maximum distance for give (and other player-to-player actions). |
| `dropDistance` | `2.0` | Distance used when opening a ground drop. |
| `closeOnGive` | `true` | Close the giver's panel after a successful give from the UI. |
| `giveNotify` | `true` | Notify both players on a give. |
| `purchaseNotify` | `true` | Notify the buyer of what was charged after a shop purchase. |
| `requireSameBucket` | `true` | Player-created drops belong to the routing bucket they were created in. |
| `playerInspection.access` | `nil` | Trusted callback `(source, target, sourceData, targetData)`; opening another player's inventory is denied unless it (or a policy registered with `RegisterInspectionAccess`) returns `true`. |
| `auditLimit` | `1000` | Entries kept in the in-memory audit ring. |
| `slowRequestMs` | `250` | Logs `slow <action> request from player <id>: <n> ms server-side` when a request takes at least this long; `0` turns it off. Live. |

### Sessions

| Key | Default | Meaning |
| --- | --- | --- |
| `sessionTtl` | `120000` | Milliseconds an open inventory may sit unused before the server closes it. Vending machine approvals follow the same rule. |
| `sessionSliding` | `true` | Each request renews the lease (idle timeout). `false` makes it a hard limit. Live. |

### Blocks

| Key | Default | Meaning |
| --- | --- | --- |
| `blockWhenDowned` | `true` | Downed, last-stand or dead players (`isdead` / `inlaststand` metadata) cannot open the inventory or use items. Enforced on server and client. |
| `downedAllowedItems` | `{}` | Item names that may still be used while downed. Opening stays blocked. |
| `downedNotifyCooldown` | `3000` | Minimum ms between "cannot do that while downed" notices. |
| `blockWhenCuffed` | `true` | Cuffed players (`ishandcuffed` metadata, `koraCuffed` state bag) cannot open the inventory, use items or hotbar slots, or move, drop or give. |
| `blockWhileBusy` | `true` | While an item is in use or a kora_lib progress bar is active the inventory cannot open, hotbar use is refused, and the slot cannot be dropped, given or moved. |
| `busyTimeout` | `30000` | Maximum ms a slot stays locked if a use handler never returns. |
| `uiBlockBag` | `"koraUiBlocked"` | Local player state bag name; while `true` the inventory cannot open. `false` or empty disables it. Read once at start. |

### Built-in use handlers

`builtinUsables`: `parachute` (`true`), `parachuteTime` (`2500` ms, `0` skips the bar), `parachuteTint` (`nil`), `parachuteBag` (`enabled = true`, `male` and `female` each `drawable = 8, texture = 0`). See [Weapons](./weapons.md).

### Drops

`drops`: `enabled` (`true`), `mergeRadius` (`1.5` m, `0` turns merging off), `model` (`prop_med_bag_01b`), `placeOnGround` (`true`), `groundOffset` (`0.0`, live), `interactionDistance` (`1.5`, keep at or below `dropDistance`), `label` (`Pick up`), `icon` (`package`). See [Stashes and drops](./stashes-and-drops.md).

### UI (`ui`)

Presentation only. See [UI](./ui.md) for each key: `centreWhenSolo`, `showHotbar`, `hotbarSeconds`, `scale`, `playerLayout`, `playerLayoutTransfer`, `rightClickSplit`, `optimisticMoves`, `queueMoves`, `directTransport`, `moveTimeoutMs`, `moveTimeout`, `images`.

### Item receipts (`itemBoxes`)

`enabled`, `duration` (`2600` ms), `showAdditions`, `showPurchases`, `showRemovals` (all `true`), `showUses` (`false`, because a consumed item already draws a removal receipt).

### Cash (`cash`)

`asItem` (`false`), `item` (`'cash'`), `account` (`'cash'`). When `asItem` is on, the kora_core account is represented by a stackable item; `AddItem`/`RemoveItem` on that item are routed back through kora_core. Turning it on or off on an established server is a data migration; do not flip it mid-session.

### Persistence (`persistence`)

`enabled` (`true`), `persistDrops` (`false`), `persistTemporary` (`false`), `flushInterval` (`5000` ms), `migrationBatchSize` (`100`), `legacyTables` (`inventories`, `stashitems`, `trunkitems`, `gloveboxitems`). See [Database](./database.md).

### Vehicles (`vehicles`)

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Inventory key opens glovebox/trunk. Live. |
| `gloveboxEnabled`, `trunkEnabled` | `true` | Per-storage switches. Live. |
| `gloveboxRequireSeated` | `true` | Server requires the player to be seated in the vehicle for the glovebox. |
| `distance` | `3.0` | Base server distance check. |
| `trunkDistance` | `7.0` | Server distance from the vehicle origin when opening a trunk (2-20). Live. |
| `bootReach` | `1.8` | Client distance to the boot position (0.5-5). Live. |
| `respectLocks` | `true` | Server refuses a locked vehicle's trunk. Live. |
| `requireSameBucket` | `true` | Routing bucket check. |
| `plateMaxLength` | `8` | Maximum normalised plate length. |
| `unknownClassFallback` | `true` | Use the `default` class row when the class cannot be resolved. Live. |
| `frontBootModels` | list of mid/rear-engine models | Models whose trunk is at the front. Live. |
| `bootSkipClasses` | `8, 13, 21` | Classes ignored by the inventory-key trunk path. Live. |
| `ownerCheck`, `accessCheck` | `nil` | Trusted server callbacks for ownership/keys/faction policy. |
| `classes` | per class | Slots and `maxWeight` for `trunk` and `glovebox` per GTA class, plus a required `default` row. `false` disables the storage for that class. |
| `trunkAnimation` | see file | `enabled`, `dict`, `clip`, `flag`, `openDoor`. |
| `doors` | see file | `enabled`, `targetOptions`, `inventoryOption`, `commands`, `commandNames`, `respectLocks`, `targetDistance`, `partDepth`. |

See [Vehicles](./vehicles.md).

### Containers (`containers`)

`defaultSlots` (`12`), `defaultMaxWeight` (`30000`), `maxIdentifierLength` (`96`), `items` (portable container item types; ships `backpack` with 20 slots, 60000 weight, `allowNested = false`), `evidence` (`slots` 100, `maxWeight` 150000, `distance` 3.0, `requireSameBucket` true, and an `access(source, action, context)` callback). The default evidence callback allows only an on-duty `police` job (read with `exports.kora_core:getJob`). See [Containers and evidence](./containers-evidence.md).

### Crafting and weapons

`crafting.maxBatchAmount` (`100`). `weapons`: `defaultDurability` (`100`), `maxAmmo` (`10000`), `ballistics` (`enabled`, `maxLoadedRounds` 240, `shotCooldown` 65 ms, `casingOffset` 0.75), `durability` (`enabled`, `perShot` 0.10, `defaultMultiplier` 1.0, `multipliers`, `excluded`), `components` (empty map: weapon item name to allowed component item names; live-registered with a schema). `weaponCarry` is described in [Weapons](./weapons.md).

### Exchanges

`exchangeCallers` (`{ kora_drugs = true }`): resource names allowed to call `ExecutePlayerExchange`. See [Player exchanges](./exchanges.md).

### Shops

Bundled shops are configured in `config/shops/*.lua` under `Config.kora_inventory.shops`. See [Shops](./shops.md).
