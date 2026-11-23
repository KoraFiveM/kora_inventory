---
title: "Configuration"
sidebar_position: 24
---


# Configuration

Every setting lives in `config.lua` (a shared script, so both server and client read it) and in one file per bundled shop under `config/shops/`. Most live-editable values are registered with kora_lib's config editor (`Kora.config`) so they can be changed from the in-game editor without editing the file. Defaults below are the shipped working-tree values.

Namespace: `Config` · Source: `config.lua, config/shops/*.lua`

## How it works

Top-level options sit on `Config`; almost everything else sits on `Config.kora_inventory`. Settings marked as read "on every press / next open" are looked up when used, so a live edit applies without a restart. Settings read once (command names, the UI-block bag name, hotbar key count, vehicle storage tables after restart) need a resource restart. Presentation-only settings under `ui` are pushed to the browser on `kora_inventory:nui:config` and never read back by the server.

## Changing a setting

1. **Find the group** — Use the groups below. `Config.*` options are top-level; the rest are keys of `Config.kora_inventory`.
2. **Edit config.lua or use the config editor** — Values registered with `Kora.config` (vehicle switches, UI toggles, slow-request logging, drop offset, shop icons) are live-editable from the in-game config editor. Everything else is edited in the file.
3. **Restart the resource when needed** — Restart `kora_inventory` with `sudo` or `ensure` for settings read once: command names, `uiBlockBag`, `hotbarSlots`, persistence flags, capacity tables and anything under `containers`, `weapons`, `weaponCarry`.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Session lease | The server-issued token and expiry that tie an open inventory to one player. `sessionTtl` is how long it lives; `sessionSliding` renews it on use. |
| Secondary inventory | Any inventory that is not a player's own: stash, shop, drop, container, evidence, trunk, glovebox, temporary. |
| Routing bucket | FiveM's instance id. With `requireSameBucket` on, a player can only use inventories in their own bucket. |

## Configuration reference

Grouped by area. Each row shows the key, its type and default, and what it does.

### Top-level (Config.*)

Presentation and identity options that sit directly on `Config`.

| Option | Type | Description |
| --- | --- | --- |
| `showTargetHints` | boolean \| nil | Default `nil`. Controls the floating world icon over shop counters. `nil` follows kora_target's own sprite setting; `true` or `false` forces it for kora_inventory shop zones (needs kora_target's per-zone override, default on). Read when the shop zones are registered. |
| `SerialPrefix` | string | Default `'KORA'`. Prefix of newly generated weapon serials (`KORA-WEAPONPISTOL50-<time>-<n>`). Upper-cased, reduced to A-Z0-9, at most 12 characters; empty falls back to `KORA`. Existing serials are never rewritten. |
| `Inspector.decimals` | integer | Default `1`. Decimals shown for fractional inspector values such as durability (0 to 3). Trailing zeros are dropped. |
| `Inspector.allowCopy` | boolean | Default `true`. Lets the item inspector text be selected and shows a Copy button that copies the item (label, name, amount, slot, inventory, metadata) as JSON. `false` hides it. |
| `Slots.borderWidth` | integer | Default `2`. Slot border thickness in CSS pixels, clamped 1 to 4. |
| `Hotbar.bottomOffset` | integer | Default `90`. Distance in CSS pixels from the screen bottom to the on-screen hotbar while on foot (clamped 0 to 600). |
| `Hotbar.vehicleBottomOffset` | integer | Default `130`. Same, while seated in a vehicle. |

### Shop markers and clerks (Config.ShopHints, Config.ShopClerks)

World presentation at the bundled shops. None of this affects what the server allows.

| Option | Type | Description |
| --- | --- | --- |
| `ShopHints.enabled` | boolean | Default `true`. Draw a small marker (and optional text) at fixed shop points. A shop opts out with `hint = false` or `enabled = false` in its own config. |
| `ShopHints.drawDistance` | number | Default `10.0` metres. Nothing is drawn or checked beyond it. |
| `ShopHints.alpha` | integer | Default `160`. Marker opacity 0 to 255. |
| `ShopHints.marker.type` | integer | Default `20` (chevron). |
| `ShopHints.marker.scale` | table | Default `{ x = 0.3, y = 0.3, z = 0.3 }`. |
| `ShopHints.marker.zOffset` | number | Default `0.0`. Added to the point's z. |
| `ShopHints.marker.bob` | boolean | Default `true`. Marker bobs up and down. |
| `ShopHints.marker.rotate` | boolean | Default `true`. Marker spins. |
| `ShopHints.markerAtPeds` | boolean | Default `false`. Also draw the marker at counters served by a clerk or Ammu-Nation shopkeeper. |
| `ShopHints.showText` | boolean | Default `false`. Draw the locale text `shop_hints.text` ("[ALT] Shop") above the marker at counters without a ped. |
| `ShopClerks.enabled` | boolean | Default `true`. Spawn clerk peds at 24/7 and liquor locations that have a `ped` spot. `false` falls back to the counter zone and label. |
| `ShopClerks.showLabel` | boolean | Default `false`. Keep the floating label at counters that have a ped (still needs `ShopHints.showText`). |
| `ShopClerks.model` | string | Default `'s_m_m_ammucountry'`. Default clerk model. |
| `ShopClerks.scenario` | string | Default `'WORLD_HUMAN_CLIPBOARD'`. Scenario the clerk plays; an empty string stands still. |
| `ShopClerks.radius` | number | Default `40.0` metres. The clerk spawns when a player comes this close and is deleted when they leave. |
| `ShopClerks.interactionDistance` | number | Default `3.0`. kora_target distance to the clerk. |

### Grid placement

Set `Config.kora_inventory.grid.enabled = true` in `config.lua` and restart the resource to test multi-cell item placement. The default is `false`. Set `grid.columns` to change the number of columns. The default is six. The inventory's slot count is the total number of cells, including a partial final row when applicable.

Items can occupy rectangular footprints. Drag an item to the cell where its upper-left corner should sit. The preview outlines the cells the item would occupy and shows whether the edge or another item blocks it. Press **R** while dragging to rotate the footprint, or select a rectangular item and choose **Rotate item** to turn it in place. Weight limits still apply. Shops and ground drops use their usual one-slot layout.

Bundled weapons declare their footprints in `data/weapons.lua`. Set `gridWidth` and `gridHeight` on a weapon definition to customize its footprint.

Hover over a grid item to see its placement dimensions. The grid shows cell numbers on the player's hotbar. Classic panels keep their usual slot numbers.

Existing saved items keep their slots and take on their authored footprint when successfully placed. If you change the column count or re-enable the grid after using classic mode, a saved footprint uses one cell while it conflicts with the new grid or another item.

### Capacity, sessions and requests (Config.kora_inventory)

Core limits and session behaviour.

| Option | Type | Description |
| --- | --- | --- |
| `playerSlots` | integer | Default `41`. Slots in a player inventory. |
| `playerMaxWeight` | integer | Default `120000` grams. Maximum carried weight. |
| `hotbarSlots` | integer | Default `5`. Slots `1..hotbarSlots` double as the hotbar: number keys 1 to N are bound to them, and weapon carry in `hotbar` mode treats them as openly carried. `0` disables the key binds. Read once at start. |
| `quickSlots` | table | Quick slots: shortcuts to items that stay in the normal inventory. See [Quick slots](#quick-slots-configkora_inventoryquickslots) below. |
| `organize` | table | Sort and Stack all buttons and per-panel search. See [Sort and Stack all](#sort-and-stack-all-configkora_inventoryorganize) below. |
| `defaultSlots` | integer | Default `50`. Slot count for secondary inventories that do not specify `slots`. Also the slot count of ground drops. |
| `defaultMaxWeight` | integer | Default `100000` grams. Capacity for secondary inventories that do not specify `maxWeight`. |
| `interactionDistance` | number | Default `3.0` metres. Default reach for secondary inventories, player inspection and give targets. |
| `giveDistance` | number | Not in the shipped file. Optional client-side override of the radius used to find a give recipient; falls back to `interactionDistance`. The server still enforces `interactionDistance`. |
| `playerInspection.access` | function \| nil | Default `nil`. Trusted server callback `(source, target, sourceData, targetData)` deciding whether `source` may open another player's inventory. Return true to grant, false (optionally with a reason) to deny. With nothing registered, inspection is denied. See `RegisterInspectionAccess`. |
| `sessionTtl` | integer | Default `120000` ms. How long an open inventory may sit before the server closes it. Vending-machine approvals follow the same rule. |
| `sessionSliding` | boolean | Default `true`. Every request renews the lease, making it an idle timeout. `false` makes it a hard limit counted from opening. Live-editable. |
| `slowRequestMs` | number | Default `250`. Log a "slow ... request" line when answering a move, buy, drop or use takes this many ms. `0` turns it off. Live-editable (0 to 10000). |
| `dropDistance` | number | Default `2.0` metres. Reach used for drop inventories. |
| `auditLimit` | integer | Default `1000`. Entries kept in the in-memory audit ring (also the in-memory item-creation entries behind `/invaudit` when the database is off); older entries are discarded. Every entry also fires `kora_inventory:server:audit`. |
| `audit.enabled` | boolean | Default `true`. Records every item creation (see [Item-creation audit log](./persistence.md#item-creation-audit-log)). Live-editable. |
| `audit.persist` | boolean | Default `true`. Writes entries to `kora_inventory_audit`. `false` keeps only the in-memory ring. Live-editable. |
| `audit.flushSeconds` | number | Default `10` (1 to 300). Seconds between batched database writes; 200 queued rows also trigger one. Live-editable. |
| `audit.retentionDays` | number | Default `14` (1 to 365). Older rows are pruned at start and hourly. Live-editable. |
| `audit.trackRemovals` | boolean | Default `false`. Also log `RemoveItem` removals. Live-editable. |
| `audit.ace` | string | Default `kora_inventory.audit`. ACE needed for `/invaudit`; checked on every request. Live-editable. |
| `audit.command` | string | Default `invaudit`. Command name, read at start. |
| `audit.anomaly.enabled` | boolean | Default `true`. Counts item amounts added per invoking resource (other than kora_inventory itself) and per player inside the window; crossing a limit logs a warning and fires `kora_inventory:server:auditAnomaly` once per window per key. Omnipack takes and `remove` entries are not counted. Live-editable. |
| `audit.anomaly.windowSeconds` | number | Default `300` (10 to 3600). Length of the rolling window and minimum gap between repeat alerts for one key. Live-editable. |
| `audit.anomaly.perResourceThreshold` | number | Default `500`. Total item amount one resource may add in the window before an alert. Live-editable. |
| `audit.anomaly.perPlayerThreshold` | number | Default `200`. Total item amount one player may receive in the window before an alert. Live-editable. |
| `omnipack.enabled` | boolean | Default `true`. Enables `/omnipack` and the `openOmnipack` export. When `false`, opening and taking are refused immediately. Live-editable. |
| `omnipack.command` | string | Default `omnipack`. Command name, read at start. |
| `omnipack.ace` | string | Default `kora_inventory.omnipack`. ACE needed to open and to take; checked on every take. Live-editable. |
| `omnipack.maxAmount` | number | Default `100` (1 to 10000). Largest single take of one item. Live-editable. |
| `exchangeCallers` | table | Default `{ kora_drugs = true }`. Resource names allowed to call `ExecutePlayerExchange` and `GetPlayerExchange`. |
| `requireSameBucket` | boolean | Default `true`. Players may only use drops, players and other inventories in their own routing bucket. |

### Blocking rules

When a player cannot open or use the inventory. Enforced on the server as well as the client.

| Option | Type | Description |
| --- | --- | --- |
| `blockWhenDowned` | boolean | Default `true`. Downed, last-stand or dead players (kora_core metadata `isdead` / `inlaststand`) cannot open the inventory, use hotbar keys or use items. |
| `blockWhenCuffed` | boolean | Default `true`. Cuffed players (`ishandcuffed` metadata or the `koraCuffed` bag) cannot open the inventory, use items, or move anything; an open panel closes the moment they are cuffed. |
| `downedAllowedItems` | string[] | Default `{}`. Item names that may still be used while downed, for example `{ 'bandage' }`. Opening stays blocked. |
| `downedNotifyCooldown` | integer | Default `3000` ms. Minimum gap between "you cannot do that" notices (downed, cuffed and busy). |
| `blockWhileBusy` | boolean | Default `true`. While a use handler runs or any kora_lib progress bar is active, the inventory cannot be opened (and closes if open), hotbar use is refused, and the server refuses to drop, give or move the slot being used. |
| `uiBlockBag` | string \| false | Default `'koraUiBlocked'`. Player state bag another resource sets to true to block the inventory (kora_emotemenu does during its freecam). `false` or an empty string ignores it. Read once at start. |
| `busyTimeout` | integer | Default `30000` ms. A slot stays locked at most this long if a use handler never returns. |

### Built-in use handlers (builtinUsables)

Handlers kora_inventory registers itself for items that otherwise have none.

| Option | Type | Description |
| --- | --- | --- |
| `builtinUsables.parachute` | boolean | Default `true`. Using the `parachute` item gives `GADGET_PARACHUTE` and consumes one. Set `false` to leave the item to another resource. |
| `builtinUsables.parachuteTime` | integer | Default `2500` ms. Progress bar length before the parachute is given; `0` skips the bar. |
| `builtinUsables.parachuteTint` | integer \| nil | Default `nil`. Optional `SetPedParachuteTintIndex` value (0 to 7). |
| `builtinUsables.parachuteBag.enabled` | boolean | Default `true`. Show the pack on the ped's back (bag component 5). Freemode peds only. |
| `builtinUsables.parachuteBag.male` | table | Default `{ drawable = 8, texture = 0 }`. |
| `builtinUsables.parachuteBag.female` | table | Default `{ drawable = 8, texture = 0 }`. |

### Ground drops (drops)

A dropped item leaves a bag prop to walk up to. The prop is local presentation only; the server re-checks access, distance and bucket when it is opened.

| Option | Type | Description |
| --- | --- | --- |
| `drops.enabled` | boolean | Default `true`. Draw bag props and targets. |
| `drops.mergeRadius` | number | Default `1.5` metres. An item dropped within this distance of an existing drop (same bucket, with room) goes into that bag. `0` turns merging off. |
| `drops.model` | string | Default `'prop_med_bag_01b'`. |
| `drops.placeOnGround` | boolean | Default `true`. Trace down so the bag sits on the floor. |
| `drops.groundOffset` | number | Default `0.0` metres. Added to the bag height after placement (-1.0 to 1.0, live-editable). Ignored when `placeOnGround` is false. |
| `drops.interactionDistance` | number | Default `1.5`. Target radius. Keep at or below `dropDistance` so the prompt never appears out of server range. |
| `drops.label` | string | Default `'Pick up'`. |
| `drops.icon` | string | Default `'package'`. |

### NUI presentation (ui)

The only settings that cross into the browser. Nothing here is authority. Most apply the next time the inventory opens.

| Option | Type | Description |
| --- | --- | --- |
| `ui.centreWhenSolo` | boolean | Default `true`. With no second inventory open, show a compact centred grid and open the inspector in a drawer. |
| `ui.showHotbar` | boolean | Default `true`. Outline slots `1..hotbarSlots` in the accent colour inside the panel. |
| `ui.hotbarSeconds` | number | Default `5`. Seconds the on-screen hotbar stays visible after the U key. `0` disables the key (live-editable, 0 to 30). |
| `ui.scale` | number | Default `1.0`. Size multiplier for text, slots and counts, clamped 0.5 to 2.0. |
| `ui.rightClickSplit` | boolean | Legacy form of `ui.rightClick`, default `true`. Only read when `ui.rightClick` is absent or invalid: `true` means `split`, `false` means `none`. |
| `ui.rightClick` | string | Default `split`. What right-clicking an item does: `split` opens the split dialog for a stack of 2+ (the original behaviour), `menu` opens a small context menu at the cursor, `none` does nothing. Any other value falls back to `rightClickSplit`. Applied the next time the inventory opens. |
| `ui.quickTransfer` | boolean | Default `true`. Shift+click on a filled slot moves the whole stack to the other open inventory (stackable stack first, else first empty slot). From a shop it buys one. Never targets a shop. |
| `ui.modifierDrag` | boolean | Default `true`. Ctrl+drag moves half the stack (rounded down, at least 1); Alt+drag moves one. |
| `ui.quickAmounts` | boolean | Default `true`. Preset amount buttons (1, 5, 10, half, All, only those within the stack) beside the inspector's amount slider. |
| `ui.filters` | boolean | Default `true`. Category chips on each panel and the search box dim non-matching slots in the player panel. Slots are never hidden or reordered. |
| `ui.weightWarnings` | table | Default `{ enabled = true, warnAt = 0.75, dangerAt = 0.95 }`. The weight bar turns warning-coloured at `warnAt` and destructive at `dangerAt` (fractions of max weight, 0.01 to 1). |
| `ui.tooltips` | boolean | Default `true`. Hover tooltip (after about 350 ms) with label, amount, weight, durability, display rows and description. |
| `ui.tips` | table | Default `{ enabled = true, maxShows = 5 }`. A small dismissible tip card at the bottom of the window for players new to the inventory. It appears on at most `maxShows` openings (1 to 50), cycling through short tips about features that are switched on in this table (drag out to drop, Shift+click, Ctrl/Alt drag, right-click as configured by `ui.rightClick`, quick slots, Sort and Stack all, and the layout choice in the `/ui` editor). Next shows another tip; Got it hides the card for good. Progress is kept in the player's own browser storage under `kora_inventory:tips`. It is never shown while an item is being dragged. Applied the next time the inventory opens. |
| `ui.controls` | table | Default `{ button = true, defaultVisible = false }`. `button` shows a keyboard button in the inventory's top bar that toggles GTA's native instructional buttons (bottom-right of the screen) listing Esc, Enter, the mouse and the Shift, Ctrl and Alt modifiers for the features that are switched on; `false` removes the button and the overlay is never shown. `defaultVisible` shows it on a player's first opening, until they use the button (their own choice is then kept in their browser storage under `kora_inventory:controlsVisible`). It is hidden whenever the inventory closes. Client-side presentation only. Applied the next time the inventory opens. |
| `ui.optimisticMoves` | boolean | Default `true`. Paint a move or purchase at once, dimmed until the server confirms, and undo it with a notice if refused or unanswered. |
| `ui.queueMoves` | boolean | Default `true`. Queue drags made while a move is pending. Needs `optimisticMoves`. |
| `ui.directTransport` | boolean | Default `true`. Send move/buy/drop/use requests as one direct net event (`kora_inventory:server:call`) instead of kora_lib callbacks. Same handlers and checks either way. |
| `ui.moveTimeoutMs` | integer | Default `6000`. Milliseconds before an unanswered move is rolled back and re-synced (500 to 60000). With `directTransport` off keep it near 1500. |
| `ui.moveTimeout` | number | Not set by default. Legacy form of `moveTimeoutMs` in seconds (0.5 to 60); only read when `moveTimeoutMs` is absent. |
| `ui.images.localPath` | string | Default `'nui://kora_inventory/images'`. Local artwork folder for definition filenames and `info.image` filenames. |
| `ui.images.extensions` | string[] | Default `{ 'webp', 'png', 'gif', 'jpg' }`. Tried in order when a filename has no extension. Animated WebP and GIF work in CEF. |

### Cash and item receipts

Optional physical cash and the item notification boxes.

| Option | Type | Description |
| --- | --- | --- |
| `cash.asItem` | boolean | Default `false`. When true, the configured kora_core account is represented only by the stackable cash item. Turning this on or off on a live server is a data migration; do not flip it mid-session. |
| `cash.item` | string | Default `'cash'`. Item name that represents the account. Must be a stackable registry item. |
| `cash.account` | string | Default `'cash'`. kora_core money account the item mirrors. |
| `itemBoxes.enabled` | boolean | Default `true`. Master switch for item receipts. `false` makes the inventory silent. |
| `itemBoxes.duration` | integer | Default `2600` ms. Display time (at least 750 is enforced). |
| `itemBoxes.showAdditions` | boolean | Default `true`. Receipts for `AddItem` grants. |
| `itemBoxes.showPurchases` | boolean | Default `true`. Receipts for shop purchases. |
| `itemBoxes.showRemovals` | boolean | Default `true`. Receipts for `RemoveItem`. |
| `itemBoxes.showUses` | boolean | Default `false`. Receipts for item use. Off by default because a consuming use already draws a removal receipt. |

### Item decay (decay)

Items spoil in real time and are converted or removed when fully decayed. Shipped off. Rules, stamping and the paused-storage behaviour are described under [Item decay](./items.md#item-decay). Every key below is read at call time and applies live; the presentation keys reach the page the next time a player opens their inventory.

| Option | Type | Description |
| --- | --- | --- |
| `decay.enabled` | boolean | Default `false`. Master switch. Off stamps nothing, spoils nothing and removes every decay view field. |
| `decay.defaultAction` | string | Default `'convert'`. `'convert'` turns a spoiled item into its rule's `into` item (same slot and amount) and removes it when the rule has none. `'remove'` always removes. |
| `decay.items` | map | Default `sandwich` and `burger` (172800 s, into `garbage`) and `water_bottle` (604800 s, removed). Per item name: `lifetime` in seconds of real time and optional `into` item name. Wins over a `decay` field on the kora_core item definition; `false` exempts an item. A lifetime is stamped on each item when it is created, so edits apply to new items. Server-only. |
| `decay.showInInspector` | boolean | Default `true`. Adds an "Expires in 1h 20m" row to the item inspector and tooltip. |
| `decay.showOnSlot` | boolean | Default `true`. Draws a thin freshness bar on the slot of decaying items. |
| `decay.warnBelow` | number | Default `0.25`. Fraction of life left below which the bar uses the warning colour. Below 0.1 it always uses the destructive colour. |
| `decay.sweepSeconds` | integer | Default `300`. Seconds between sweeps of online players' inventories. `0` turns the sweep off (items then spoil only when viewed, used or moved). Values from 1 to 29 behave as 30. Server-only. |
| `decay.mergePolicy` | string | Default `'oldest'`. `'oldest'`: differently aged stacks merge and spoil with the oldest member (the stamps are ignored by the stack check). `'separate'`: items stack only when their stamps are identical. |
| `decay.pauseIn.stash` | boolean | Default `false`. When true, time does not count while an item sits in a stash. Server-only. |
| `decay.pauseIn.trunk` | boolean | Default `false`. Same for vehicle trunks. |
| `decay.pauseIn.glovebox` | boolean | Default `false`. Same for vehicle gloveboxes. |
| `decay.pauseIn.container` | boolean | Default `false`. Same for portable containers. |
| `decay.pauseIn.drop` | boolean | Default `false`. Same for ground drops. |
### Player trades (trade)

The two-sided confirmed trade window. See [Player trades](./trade.md). All keys are editable in `/config`; every key except `command` is read when it is used, so a change applies at once (`slots` and `allowCash` reach the window the next time the inventory opens). `distance`, `requestTimeout`, `confirmDelay`, `maxDuration` and `requestCooldown` are server-only.

| `trade.enabled` | boolean | Default `true`. Turns trading on. Off hides the Trade button, refuses new requests and ends any open trade. |
| `trade.slots` | integer | Default `8`. Offer slots per side (1 to 32). |
| `trade.allowCash` | boolean | Default `true`. Each side may add cash: the cash account, or the cash item when `cash.asItem` is on. |
| `trade.distance` | number | Default `3.0` metres. How close the players must be to request, keep open and complete a trade. |
| `trade.requestTimeout` | integer | Default `20` seconds. Time the asked player has to answer. |
| `trade.confirmDelay` | integer | Default `3` seconds. After both press Ready the offers freeze this long before Confirm is accepted. |
| `trade.maxDuration` | integer | Default `300` seconds. An open trade is cancelled with no changes after this long. |
| `trade.requestCooldown` | integer | Default `10` seconds. Minimum gap between trade requests from one player. |
| `trade.command` | string | Default `'trade'`. Chat command that requests a trade with the nearest player; empty for none. Read when the resource starts. |

### Persistence (persistence)

Durable storage for secondary inventories only. Player items are never stored here.

| Option | Type | Description |
| --- | --- | --- |
| `persistence.enabled` | boolean | Default `true`. `false` keeps every secondary inventory in memory only. |
| `persistence.persistDrops` | boolean | Default `false`. Save ground drops. |
| `persistence.persistTemporary` | boolean | Default `false`. Save temporary stashes and temporary-flagged inventories. |
| `persistence.flushInterval` | integer | Default `5000` ms. How often dirty inventories are written (at least 1000). |
| `persistence.migrationBatchSize` | integer | Default `100`. Rows between `kora_inventory:server:migrationProgress` events. |
| `persistence.legacyTables` | string[] | Default `{ 'inventories', 'stashitems', 'trunkitems', 'gloveboxitems' }`. Legacy tables `kora_inventory-migrate` reads. |

### Vehicle storage (vehicles)

Trunk and glovebox policy. Clients may suggest a network id only; plate, class, capacity and coordinates are resolved on the server.

| Option | Type | Description |
| --- | --- | --- |
| `vehicles.distance` | number | Default `3.0`. Server reach to the vehicle for glovebox access. |
| `vehicles.requireSameBucket` | boolean | Default `true`. Player and vehicle must share a routing bucket. |
| `vehicles.plateMaxLength` | integer | Default `8`. Maximum normalised plate length used in storage keys. |
| `vehicles.enabled` | boolean | Default `true`. Inventory key opens glovebox (seated) and trunk (at the boot). `false` leaves storage to other resources; `openInventory('trunk', netId)` still works. Live-editable. |
| `vehicles.gloveboxEnabled` | boolean | Default `true`. Glovebox from the inventory key. |
| `vehicles.trunkEnabled` | boolean | Default `true`. Trunk from the inventory key. |
| `vehicles.trunkCargo.enabled` | boolean | Default `false`. Draw the items in a trunk as props inside the vehicle's boot for nearby players. Cosmetic only: it never opens or changes inventory. Restart after changing. |
| `vehicles.trunkCargo.drawDistance` | number | Default `35.0` metres. Clients build props only for vehicles within this distance. |
| `vehicles.trunkCargo.maxProps` | integer | Default `24` (1 to 24). Props per trunk, filled in slot order. |
| `vehicles.trunkCargo.fallbackModel` | string | Default `prop_med_bag_01b`. Prop for items with no model override and no `dropProp` or `dropmodel` in their definition. |
| `vehicles.trunkCargo.models` | table | Item name to prop model overrides, for example `water_bottle = 'prop_ld_flow_bottle'`. Weapons render as their own weapon model. |
| `vehicles.trunkCargo.bounds` | table | Vehicle spawn name to a `min`/`max` model-space box that calibrates the cargo area of a custom model. A box outside the model's dimensions is ignored. |
| `vehicles.bootReach` | number | Default `1.8` metres. How close to stand to the boot (0.5 to 5.0, live-editable). |
| `vehicles.trunkDistance` | number | Default `7.0` metres. Server limit from player to the vehicle origin when opening a trunk (2.0 to 20.0). Larger than `distance` because the boot is at the far end. |
| `vehicles.respectLocks` | boolean | Default `true`. Refuse trunk access while the vehicle is locked (`kora_vehiclekeys:locked` bag, else native door lock). The glovebox of the vehicle you sit in is never blocked. |
| `vehicles.unknownClassFallback` | boolean | Default `true`. Use the `default` row of `classes` when the class cannot be resolved; `false` refuses storage for such vehicles. |
| `vehicles.frontBootModels` | string[] | Default: 37 rear- and mid-engine spawn names (adder, zentorno, osiris ...). Their trunk is at the front. Case-insensitive. |
| `vehicles.bootSkipClasses` | integer[] | Default `{ 8, 13, 21 }`. GTA classes the inventory key ignores on foot (motorcycles, cycles, trains). |
| `vehicles.ownerCheck` | function \| nil | Default `nil`. Trusted callback `(source, vehicle)`; return false (or false, reason) to deny. `vehicle` has `entity, netId, plate, class, kind, coords, distance, slots, maxWeight`. |
| `vehicles.accessCheck` | function \| nil | Default `nil`. Second callback with the same signature; both must pass. |
| `vehicles.classes` | table | Default: one row per GTA class 0 to 21 plus `default` (trunk 50 slots / 60000, glovebox 8 slots / 10000). Each row is `{ trunk = { slots, maxWeight } \| false, glovebox = ... \| false }`. Class 8 and 13 have no storage; boats, helicopters, planes and trains have no glovebox. Applied after a restart. |
| `vehicles.trunkAnimation.enabled` | boolean | Default `true`. Player turns to the boot, the lid opens and an animation loops while the trunk panel is open. |
| `vehicles.trunkAnimation.dict` | string | Default `'mini@repair'`. |
| `vehicles.trunkAnimation.clip` | string | Default `'fixing_a_ped'`. |
| `vehicles.trunkAnimation.flag` | integer | Default `49`. `TaskPlayAnim` flag. |
| `vehicles.trunkAnimation.openDoor` | boolean | Default `true`. `false` plays the animation without touching the door. A door already open is left open. |
| `vehicles.doors.enabled` | boolean | Default `true`. Master switch for the ALT-menu lid entries and `/trunk` `/hood`. |
| `vehicles.doors.targetOptions` | boolean | Default `true`. Open/Close entries in the kora_target menu while aiming at that end. |
| `vehicles.doors.inventoryOption` | boolean | Default `true`. "Trunk storage" entry beside the trunk toggle. |
| `vehicles.doors.commands` | boolean | Default `true`. `/trunk` and `/hood` for the driver. |
| `vehicles.doors.commandNames` | table | Default `{ trunk = 'trunk', hood = 'hood' }`. Rename or disable (false or empty string). Read once at start. |
| `vehicles.doors.respectLocks` | boolean | Default `true`. A locked vehicle cannot be opened from outside; closing and anything from inside is allowed. |
| `vehicles.doors.targetDistance` | number | Default `3.0`. Metres from the player to the aimed point (1.0 to 10.0). |
| `vehicles.doors.partDepth` | number | Default `1.3`. Metres from the vehicle end that count as the trunk or hood when aiming (0.5 to 3.0). |

### Containers and evidence (containers)

Item-bound containers and police evidence. Server-only domains: no client event accepts a container id, owner or item.

| Option | Type | Description |
| --- | --- | --- |
| `containers.defaultSlots` | integer | Default `12`. |
| `containers.defaultMaxWeight` | integer | Default `30000`. |
| `containers.maxIdentifierLength` | integer | Default `96`. Maximum container/evidence id length. Ids may contain letters, digits, `_ - .` only. |
| `containers.items` | table | Default `{ backpack = { label = 'Backpack', slots = 20, maxWeight = 60000, allowNested = false } }`. Item names promoted to portable containers. Using the item from your own inventory binds a generated container id to that exact unique item on first use. `allowNested = true` lets it be stored inside another container. |
| `containers.evidence.slots` | integer | Default `100`. |
| `containers.evidence.maxWeight` | integer | Default `150000`. |
| `containers.evidence.distance` | number | Default `3.0`. Reach between officer and target for seize/release. |
| `containers.evidence.requireSameBucket` | boolean | Default `true`. |
| `containers.evidence.access` | function | Shipped as a function that allows only an on-duty `police` job (via `exports.kora_core:getJob`). Signature `(source, action, context)`; return true to grant or false, reason to deny. Evidence is denied entirely when this is not a function. `action` is `open`, `seize` or `release`. |

### Searching players (search)

What a searcher sees and may open when they open another player's inventory. See [Containers and evidence](./containers.md).

| Option | Type | Description |
| --- | --- | --- |
| `search.hideContainerContents` | boolean | Default `true`. Live. Portable containers in a searched player's inventory are shown closed: no container id and nothing about their contents is sent to the searcher. Off shows them like ordinary items. |
| `search.openContainers` | boolean | Default `true`. Live. Lets a searcher open a searched player's bag with the `openTargetContainer` intent. The server re-checks the session, slot, range, bucket and search policy. Off refuses every such request and the view stops offering Open. |
| `search.openTime` | integer | Default `2000`. Live. Milliseconds of progress bar the searcher must complete before the bag opens (0 to 20000). The server runs the bar on the searcher's client and enforces the minimum elapsed time, then re-validates the session and slot before opening. |

### Water damage (waterDamage)

Electronics damaged by swimming. See [Items and metadata](./items.md).

| Option | Type | Description |
| --- | --- | --- |
| `waterDamage.enabled` | boolean | Default `false`. Live. Master switch. |
| `waterDamage.swimSeconds` | integer | Default `3`. Live. Seconds of swimming before the client reports (1 to 120). The server still accepts one report per player every 10 seconds. |
| `waterDamage.items` | table | Default `phone`, `iphone`, `samsungphone` at `chance = 1.0` and `radio` at `chance = 0.5`. Live. Item name to `{ chance = 0..1 }`, rolled once per carried stack per report. |
| `waterDamage.mode` | string | Default `flag`. Live. `flag`, `convert` or `remove`; anything else behaves like `flag`. |
| `waterDamage.into` | string \| nil | Default `nil`. Live. Item used by `convert`; an unknown or missing item falls back to `flag`. Swimming is self-reported, so never use an item worth more than the original (use junk such as garbage). |
| `waterDamage.repairItem` | string | Default `electronickit`. Live. Using it repairs the first water damaged pocket item and consumes one. |
| `waterDamage.protectedBy` | table | Default `{ 'paperbag' }`. Reserved, no effect yet: items inside any portable container are already never damaged. |

### Crafting, weapons and weapon carry

Server-owned recipes, weapon metadata rules, ballistics and the visible carried-weapon system.

| Option | Type | Description |
| --- | --- | --- |
| `crafting.maxBatchAmount` | integer | Default `100`. Largest `amount` accepted by `CraftItem` / `CanCraftRecipe`. |
| `weapons.defaultDurability` | number | Default `100`. Durability given to new weapons. |
| `weapons.maxAmmo` | integer | Default `10000`. Ceiling for stored ammo. |
| `weapons.serialPrefix` | string | Deprecated alias of `Config.SerialPrefix`; only read when `SerialPrefix` is left at `KORA` and this is set to something other than `QB`. |
| `weapons.ballistics.enabled` | boolean | Default `true`. Each loaded round is a record in `info.loadedBullets`, created and consumed only by the server. |
| `weapons.ballistics.maxLoadedRounds` | integer | Default `240`. Hard metadata cap per weapon. |
| `weapons.ballistics.shotCooldown` | integer | Default `65` ms. Minimum gap between accepted shot reports. |
| `weapons.ballistics.casingOffset` | number | Default `0.75`. Offset for the recovered casing marker. Present in config; not read by this resource's own scripts. |
| `weapons.ammoInfo.enabled` | boolean | Default `true`. Adds the ammo view fields to weapon and ammo items. Set `false` to remove them entirely. |
| `weapons.ammoInfo.where` | string | Default `both`. `inspector`, `menu` or `both`. With `inspector` or `both` the server also appends Takes, Loaded, Rounds and Fits rows to `displayMeta`; the value is also passed to the UI as a hint for the right-click menu entry. |
| `weapons.ammoInfo.showLoaded` | boolean | Default `true`. Include the rounds currently loaded in a weapon. |
| `weapons.ammoInfo.showCompatible` | boolean | Default `true`. Ammo items list the weapons they fit. |
| `weapons.durability.enabled` | boolean | Default `true`. Server-applied wear per accepted round. |
| `weapons.durability.perShot` | number | Default `0.10`. Durability percentage points lost per shot. |
| `weapons.durability.defaultMultiplier` | number | Default `1.0`. |
| `weapons.durability.multipliers` | table | Default `{}`. Per-weapon wear multipliers, for example `weapon_carbinerifle = 1.25`. |
| `weapons.durability.excluded` | table | Default `{}`. Weapons that never wear, for example `weapon_stungun = true`. |
| `weapons.components` | table | Default `{}`. Allow-list `weapon item name -> { component item names }` (a `default` row applies to weapons without their own). A weapon with no row accepts no components. |
| `weapons.jams.enabled` | boolean | Default `false`. Accepted shots can jam the weapon. Live. |
| `weapons.jams.baseChance` | number | Default `0.002`. Jam chance per accepted shot at 100 percent durability (0 to 1). Live. |
| `weapons.jams.lowDurabilityChance` | number | Default `0.03`. Jam chance per accepted shot at or below `lowDurabilityBelow`. Live. |
| `weapons.jams.lowDurabilityBelow` | number | Default `30`. Durability percent where the chance reaches `lowDurabilityChance`; blended linearly above it. Live. |
| `weapons.jams.clearTime` | integer | Default `1500` ms. Server-run progress bar for clearing a jam. Live. |
| `weapons.jams.excluded` | table | Default `{}`. Weapons that never jam, for example `weapon_revolver = true`. Melee, throwables and weapons with no `ammotype` never jam regardless. |
| `weapons.repair.enabled` | boolean | Default `true`. Registers the kit and cleaning use handlers. Applies after a restart. |
| `weapons.repair.maxDurability` | number | Default `100`. Ceiling for kits, cleaning and counters (never above 100). Live. |
| `weapons.repair.kits` | table | Default `repairkit = { restore = 25, time = 4000 }`, `advancedrepairkit = { restore = 60, time = 6000 }`. Item name to durability points restored and progress bar milliseconds. Only listed names get a built-in handler. `restore` and `time` are live; adding or removing a name applies after a restart. |
| `weapons.repair.cleaning.item` | string | Default `'cleaningkit'`. Item that cleans the drawn weapon. Applies after a restart. |
| `weapons.repair.cleaning.clearsJam` | boolean | Default `true`. Cleaning also clears a jam. Live. |
| `weapons.repair.cleaning.restore` | number | Default `5`. Durability points a cleaning restores. Live. |
| `weapons.repair.cleaning.time` | integer | Default `3000` ms. Cleaning progress bar. Live. |
| `weapons.repair.counters.enabled` | boolean | Default `false`. Repair counters. Zones are registered at start, so a change applies after a restart. |
| `weapons.repair.counters.pricePerPoint` | number | Default `15`. Price per missing durability point, rounded up. Live. |
| `weapons.repair.counters.account` | string | Default `'cash'`. `'cash'` or `'bank'` (anything else is treated as cash). Live. |
| `weapons.repair.counters.locations` | table | Default `{}`. List of `{ coords = vec3(x, y, z), distance = 2.5, bucket = 0, label = 'Weapon repairs' }`. Edited in `config.lua` only. A commented example sits beside the Ammu-Nation coordinates. |
| `weaponCarry.enabled` | boolean | Default `true`. Render owned, undrawn weapons on the body for every nearby client. Presentation and pacing only. |
| `weaponCarry.visibility` | string | Default `'hotbar'`. `'all'` renders every carryable weapon; `'hotbar'` only slots 1..hotbarSlots. |
| `weaponCarry.drawTime` | integer | Default `900` ms. Draw duration; `0` restores instant toggling and skips the animation. |
| `weaponCarry.holsterTime` | integer | Default `700` ms. |
| `weaponCarry.concealedDrawTime` | integer | Default `1800` ms. Extra draw time when the weapon was outside the hotbar range in `hotbar` mode. |
| `weaponCarry.drawAnim / holsterAnim` | table \| false | Fallback `{ dict, clip, flag }` (cop intimidation intro/outro, flag 49). `false` disables the animation but keeps the timing. |
| `weaponCarry.drawAnims / holsterAnims` | table | Per-tier animations keyed `back`, `sling`, `hip`; a tier set to `false` skips the animation. |
| `weaponCarry.disable` | table | Default `{ move = false, combat = true, car = false }`. Controls disabled by the draw progress bar. |
| `weaponCarry.tiers` | table | Default maps kora_core `weapontype` to tier: Rifle, Shotgun, SMG, Sniper, LMG, Heavy, Pistol to `back`; Melee to `sling`. A type not listed (Throwable, Equipment) is never carried. |
| `weaponCarry.attachments` | table | Per-tier lists of `{ bone, pos, rot }` positions taken in order; a weapon with no free position is not rendered. Defaults use bone 24817 (spine). |
| `weaponCarry.weapons` | table | Per-item overrides: `tier = false` stops carrying; `bone`, `pos`, `rot` override the position; `model` renders a prop instead. Default excludes `weapon_petrolcan` and `weapon_fireextinguisher`. |
| `weaponCarry.components` | table | Default `{}`. Maps a component item name to the GTA component name rendered on the carried weapon. Only entries here reach clients. |

### Drag to combine (combine)

Lets a player drop one item onto another in their own inventory to combine them. The server holds the only recipe registry; the page is only told each pair's item names and label. All of these are in the `/config` editor, and the server reads them on every attempt, so changes apply without a restart (players see the popover change the next time they open their inventory). See [Crafting](./crafting.md#combining-items-by-dragging).

| Option | Type | Description |
| --- | --- | --- |
| `combine.enabled` | boolean | Default `true`. Off: no popover, the `combine` intent is refused, and dropping one item on another swaps or stacks them as usual. Live. |
| `combine.progress` | boolean | Default `true`. Server only. Off: every recipe completes at once even if it has a `time`. Live. |
| `combine.recipes` | list of tables | The pairs players can combine. Each row has `a`, `b` (item names, either drag order), `result`, `amount` (default `1`), `consumeA`, `consumeB` (default `1`; `0` keeps the item), `time` (progress bar milliseconds, default `0`) and `label`. Default: one row, `rolling_paper` + `weed` = `joint`, `time = 2500`, `label = 'Roll a joint'`. A row with a bad shape or an unsupported field is skipped and reported in the server log. Live; it is an advanced list in the `/config` editor. |

Other resources add recipes at runtime with `registerCombination`; a pair already listed here cannot be registered again.

### Bundled shop files (config/shops/*.lua)

Each file sets `Config.kora_inventory.shops.<id>`. The same table is read by the server registration, the client targets/blips/peds and the hint markers. The location list is duplicated on purpose: the client uses it for presentation, the server independently verifies the live position and bucket before every open.

| Option | Type | Description |
| --- | --- | --- |
| `shops.<id>.id / label` | string | Shop id (`ammunation`, `convenience`, `liquorstore`, `vendingmachine`) and display label. The id is the second argument of `openInventory('shop', id)`. |
| `shops.<id>.enabled` | boolean | Default `true`. `false` removes the convenience shop, its targets, clerks and blips (the file registers nothing). Also honoured by clerks and hints for any shop. |
| `shops.<id>.slots / maxWeight` | integer | ammunation 32 / 40000; convenience and liquorstore 16 / 30000; vendingmachine 2 / 40000. |
| `shops.<id>.weightLimit` | boolean | ammunation sets `false` so the heavy catalogue is never refused for weight on restock. Default `true` for other shops. Registration policy, not persisted. |
| `shops.<id>.currency` | string | `'cash'` for all bundled shops. kora_core account charged for purchases (`'money'` is treated as cash). |
| `shops.<id>.interactionDistance` | number | ammunation, convenience, liquorstore `2.25`; vendingmachine `2.5`. Both the target radius and the server's counter distance. |
| `shops.<id>.inventory` | table[] | Stock rows `{ name, amount, price }`. Names must exist in the item registry. Rows are placed in order into slots 1..n; a restocked shop keeps its stored slots. |
| `shops.<id>.locations` | table[] | Counter points `{ name?, x, y, z, heading, bucket, ped? }`. `bucket` must be a number or the server check fails closed. `ped = { x, y, z, heading }` places the clerk; `clerk = false` or `shopkeeper = false` on a location opts out; `shopkeeperUnlessStarted = '<resource>'` skips the Ammu-Nation shopkeeper while that resource runs. |
| `shops.<id>.blip` | table | `{ enabled, sprite, color, scale, shortRange, category, name? }`. `category` must be a Kora.blips category; an unknown value logs a warning and the blip is created without one. Ammunation blips use category `Weapons`, convenience `Convenience`, liquor `Liquor`. |
| `shops.ammunation.shopkeeper` | table | `{ enabled = true, model = 's_m_m_ammucountry', radius = 60.0 }`. Frozen, invincible shopkeepers at each location with a `ped` spot. |
| `shops.ammunation.limitedStock / restockIntervalMinutes` | boolean / number | Defaults `true` / `30`. Purchases lower the shared stock; every interval each row is topped back up to its configured `amount` (never lowered). `limitedStock = false` refills a row right after each purchase. `0` or less turns the timer off. |
| `shops.<id>.clerk` | table \| false | Per-shop clerk override `{ model, scenario, radius, enabled }`; `false` disables clerks for the shop. |
| `shops.<id>.hint` | boolean | `false` opts the shop out of the floor marker. |
| `shops.vendingmachine.models` | string[] | Default `prop_vend_soda_01`, `prop_vend_soda_02`, `prop_vend_water_01`, `prop_vend_coffe_01`. Targeted by model everywhere on the map; vending machines have no fixed location list. |

## Physical cash

With `cash.asItem = true` kora_inventory registers with kora_core (`registerPhysicalCash`) and the cash account becomes a plain stack of the `cash.item` item: it can be given, stashed and dropped. `AddItem`/`RemoveItem` on that item name are routed to `addMoney`/`removeMoney`, `SetInventory`/`setItems` and `ClearInventory` keep the stack, shops cannot stock it, and the seven private `physicalCash*` exports only answer to kora_core. When the provider stops, kora_core fails closed instead of minting a second balance.

## Live editing

Settings registered through `Kora.config` carry a scope (server or client) and a `live` flag: vehicle switches, door switches, UI toggles, every `decay` key, `hotbarSeconds`, `slowRequestMs`, `sessionSliding`, `groundOffset` and `showTargetHints` apply on the next use or open. The vehicle class table, weapon components and carried-weapon components are edited through the config editor but apply after a restart. `Config` is replaced by the adopted copy at the end of `config.lua`, so scripts keep reading `Config.kora_inventory` as normal.

## Layouts, quick slots, ammo info and trunk cargo in /config

These keys are registered in `config/schema/core_features.lua` and appear in the in-game `/config` editor: `ui.layout`, `ui.layouts.*`, `ui.playerLayoutChoice`, `ui.rightClick`, `ui.quickTransfer`, `ui.modifierDrag`, `ui.quickAmounts`, `ui.filters`, `ui.tooltips`, `ui.weightWarnings.*`, `quickSlots.*`, `weapons.ammoInfo.*` and `vehicles.trunkCargo.*`. Layout and interface switches apply the next time a player opens their inventory; `quickSlots.hideWhenMissing`, `showKeyHints` and `inHotbarHud` apply on the next quick slot update; `ammoInfo.*` applies on the next inventory view; trunk cargo `enabled`, `drawDistance` and `maxProps` apply within a second or two.

Restart required: `quickSlots.enabled` (its keybinds are registered once at start), `vehicles.trunkCargo.fallbackModel`, `models` and `bounds`. The `quickSlots.slots` list is not editable in `/config`; change it in `config.lua`.

## Tables that other files re-read

A few keys are read by scripts that do not appear in config.lua: `giveDistance` (client give targeting), `weapons.serialPrefix` (deprecated) and `ui.moveTimeout` (legacy). They are accepted if you add them but are not part of the shipped file.

## Limits and related APIs

Capacity tables are read at start; changing `vehicles.classes` or `containers` live requires a restart. `hotbarSlots` controls both key binds and the weapon-carry hotbar range, so keep it in step with your HUD. `containers.evidence.access` and `vehicles.ownerCheck/accessCheck` can only be set by editing the file; there is no export to inject them. Do not toggle `cash.asItem` on a running server.

## Related guides

- [Persistence: tables and migration](./persistence.md)
- [Vehicle storage](./vehicles.md)
- [Weapons and weapon carry](./weapons.md)
- [Shops](./shops.md)

## Additional keys (from the code)

Keys that exist in `config.lua` but are not listed in the reference tables above.

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `closeOnGive` | boolean | `true` | Close the giver's panel after a successful give from the UI. |
| `giveNotify` | boolean | `true` | Notify both players on a give. |
| `purchaseNotify` | boolean | `true` | Notify the buyer of what was charged after a shop purchase. |
| `stackableWeapons` | table | `weapon_grenade`, `weapon_molotov` | Weapons that stack in one slot instead of one slot each (no serial). Only affects items added afterwards. |
| `ui.playerLayout` | boolean | `true` | Register the window with kora_hud's `/ui` editor so players can move, resize (75-125 %) and pick a side. Needs `kora_hud`. |
| `ui.playerLayoutTransfer` | boolean | `false` | Default for "Use my position for stashes and trunks". |
| `ui.layout` | string | `'classic'` | Server default inventory layout: `classic` (original three columns), `loadout` (pockets, the Loadout panel over the inspector, other inventory), `compact` (narrow single column, inspector as a popover) or `dock` (full-height edge panel with tabs; see [NUI and UI](./nui.md)). An unknown value falls back to `classic`. Applied the next time the inventory opens. |
| `ui.layouts` | table | all four `true` | Which layouts may be used and picked, for example `classic = true, dock = false`. Only an explicit `false` disables one; if all are `false`, `classic` stays available. |
| `ui.playerLayoutChoice` | boolean | `true` | Players choose their layout in kora_hud's `/ui` editor ("Inventory layout", listing only the allowed layouts). `false` gives everyone `ui.layout`. Needs `ui.playerLayout` and `kora_hud`. |
| `vehicles.gloveboxRequireSeated` | boolean | `true` | The server requires the player to be seated in the vehicle for the glovebox. |

`slowRequestMs` logs `slow <action> request from player <id>: <n> ms server-side` to the server console.

See also [Installation](../installation.md) and [Commands and keybinds](../commands.md).

## Sort and Stack all (`Config.kora_inventory.organize`)

Every inventory panel except shops (player, stash, trunk, glovebox, container and ground drop) gets a Sort button, a Stack all button and its own search box in its header. Sort and Stack all are server operations (the `organize` intent, see [Opening inventories and sessions](./inventories.md#organizing-a-panel-the-organize-intent)); the search box only dims non-matching slots in that panel and never reaches the server. Config is read on every request, so the server applies a change at once; the buttons appear or disappear the next time a player opens the inventory.

| Option | Type | Description |
| --- | --- | --- |
| `organize.enabled` | boolean | Default `true`. Master switch. When off the server refuses every `organize` intent and the buttons are hidden. |
| `organize.stack` | boolean | Default `true`. Allow Stack all: merge stackable stacks of the same item with identical metadata into the lowest slot, never above an item definition's optional `maxStack`. Unique items never merge. |
| `organize.sort` | boolean | Default `true`. Allow Sort: stack, then reorder by `sortOrder`, then label (case-insensitive), then item name, then original slot. |
| `organize.keepHotbar` | boolean | Default `true`. In a player inventory slots `1..hotbarSlots` are never moved or emptied, so hotbar keys and visible weapon carry keep working. A matching loose stack can still be added to a hotbar stack. Other inventories have no protected slots. |
| `organize.cooldownMs` | integer | Default `1000`. Minimum milliseconds between two organizes by one player (0 to 60000). |
| `organize.sortOrder` | string[] | Default `{ 'weapon', 'ammo', 'useable', 'other' }`. Category order for Sort. A weapon is an item whose definition is a weapon, ammo has an `ammoType` (or type `ammo`), useable has a use action; a category left out of the list sorts last. |
| `organize.panelSearch` | boolean | Default `true`. Show the per-panel search box. The top bar search keeps dimming the player panel as before. |

The `/config` editor entries live in `config/schema/organize.lua` (`config/schema/tips.lua` for `ui.tips`, and `config/schema/controls.lua` for `ui.controls`; both controls keys are live).

## Quick slots (`Config.kora_inventory.quickSlots`)

Quick slots are shortcuts, not physical slots. Items stay wherever they are in the player's normal inventory (slots `1..playerSlots`). A quick slot is a pointer that resolves to the real slot of a matching item. It is shown in a drawer on the side of the inventory window (a Loadout panel in the loadout layout), can be included in the U-key on-screen hotbar, and can have a hotkey. Nothing new is stored on the server and the server gains no new authority: a hotkey uses the resolved item through the same path as the number-key hotbar. The settings are read when the client starts, so restart the resource after editing them.

| Option | Type | Description |
| --- | --- | --- |
| `quickSlots.enabled` | boolean | Default `true`. `false` registers no keybinds and no NUI callback, and the client sends the page a single `enabled = false` message. |
| `quickSlots.hideWhenMissing` | boolean | Default `true`. `true` hides quick slots that resolve to no item; `false` makes the page show greyed placeholders. Sent to the page. |
| `quickSlots.showKeyHints` | boolean | Default `true`. The page shows the bound key on each quick slot. Sent to the page. |
| `quickSlots.drawer` | table | `{ startCollapsed = false }`. The quick slots hang in a drawer on the window's edge (classic, compact and dock layouts). `startCollapsed = true` opens the drawer as a slim strip. Once a player uses the drawer handle their choice is remembered on their own machine and wins over this value. Sent to the page. |
| `quickSlots.inHotbarHud` | boolean | Default `true`. Adds the resolved quick slots to the U-key on-screen hotbar payload as `quick`. |
| `quickSlots.reloadFromPockets` | boolean | Default `true`. Informational. Ammunition is always loaded through the normal ammo use path, which the server validates against the drawn weapon. |
| `quickSlots.slots` | table | Ordered list of quick slots, see below. |

Each entry of `slots`:

| Option | Type | Description |
| --- | --- | --- |
| `id` | string | Required. Letters, digits and underscores, unique. Names the hotkey command `kora_inventory:quick_<id>` (written with the id in place of the placeholder). Entries with another id are ignored. |
| `label` | string | Shown in the page and in the key bindings list as `Quick slot: label`. |
| `accepts` | table | Which items fit. `names` is a list of item names (any of), `type` is the item definition type (for example `'weapon'`) and `weapontype` is kora_core's weapon definition `weapontype` (for example `'Pistol'`). Every criterion given must match. Names are not case sensitive. An empty or missing filter matches nothing. |
| `linkedTo` | string | Id of another quick slot. This slot then resolves to the ammunition item whose definition `ammoType` equals the `ammotype` of the weapon resolved for that slot, and reports the total amount of that ammunition across all slots. A weapon without an `ammotype`, or no matching ammunition, leaves it unresolved. A linked slot cannot be pinned. |
| `key` | string | Default key, `''` for unbound. Nothing is bound by default because phone and radio resources, and GTA's own R reload, would clash. Players can still bind any quick slot under Settings, Key Bindings, FiveM. |

How a quick slot picks its item, in order:

1. The item the player pinned to it from the page (a local preference, see below). The item must still match the slot's filter, carry the pinned name and, if the pin has a serial, the same serial. A pinned weapon is followed when it moves to another slot.
2. For slots that accept weapons: the weapon that is currently drawn, if it matches the filter.
3. The lowest-numbered matching slot.

A weapon taken by one weapon quick slot is not taken again by another one (for example `weapon` and `sidearm`) unless it was pinned there. Slots above `playerSlots` are ignored.

Pins are stored in the player's own client key-value storage, per character (kora_core `citizenid`), under the key `kora_inventory:quickslots:` followed by the citizen id. They are never sent to the server and are re-checked against the live inventory on every resolve.

```lua title="config.lua"
quickSlots = {
    enabled = true,
    hideWhenMissing = false,
    drawer = { startCollapsed = true },
    slots = {
        { id = 'weapon',  label = 'Weapon',  accepts = { type = 'weapon' }, key = '' },
        { id = 'sidearm', label = 'Sidearm', accepts = { type = 'weapon', weapontype = 'Pistol' }, key = '' },
        { id = 'ammo',    label = 'Ammo',    linkedTo = 'weapon', key = '' },
        { id = 'radio',   label = 'Radio',   accepts = { names = { 'radio' } }, key = 'F5' },
    },
},
```
