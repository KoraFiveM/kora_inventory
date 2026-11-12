---
title: "Containers and evidence"
sidebar_position: 13
---


# Containers and evidence

Two trusted server-only domains: item-bound containers (backpacks, bags) and evidence/confiscation storage. There is no client event that accepts a container id, owner, item or target; a gameplay resource resolves everything on the server first. The Lua tables `KoraInventory.containers`, `KoraInventory.evidence` (also `KoraInventory.confiscation`) are internal to the resource; the player-facing entry points are the `use` of a configured portable item and the evidence policy in `config.lua`.

Namespace: `KoraInventory.containers` · Source: `server/containers.lua`

## How it works

A portable container is a generic `container:<id>` inventory bound to one unique item by writing a server-generated `info.containerId` into that item. Access is possession-based: every open and every transfer revalidates that the player currently holds an item with that exact container id, so giving the backpack to someone transfers access. Using a configured portable item (`containers.items`) opens it from the player's own inventory; the first use creates and binds the container. A container cannot be stored inside itself, and not inside another container unless the definition sets `allowNested`. Generic containers must have an owner, a group list, an access callback or coordinates, so an unbounded durable stash cannot be created by accident. Evidence inventories (`evidence:<id>`) are default-deny: every open, seize and release runs `containers.evidence.access(source, action, context)`, plus entity, bucket, range, slot, amount and capacity checks under deterministic locks.

## How a backpack works

1. **Define the item** — A unique item (the shipped `backpack`) listed in `containers.items` with slots and weight.
2. **First use binds** — Using the item generates an id like `item-<owner>-<slot>-<time>-<n>` and writes it to the item's `info.containerId` through the player write funnel.
3. **Later uses open it** — The server reads the real slot, finds the bound id and opens `container:<id>` with a possession check.
4. **Giving it away** — Transferring the unique item to another player moves access with it; copied or stale records cannot open it.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Portable container | A container whose identity is a `containerId` stored in a unique item's metadata. |
| Evidence policy | The `containers.evidence.access` callback deciding open, seize and release. |
| Seize / release | Moving an item from a target player into evidence, or back out to a target. |

## Functions

Functions are resource-internal (not exported). They are documented for maintainers; external resources reach the behaviour through the backpack item, `Config.kora_inventory.containers` and, for evidence, the `access` policy.

### `KoraInventory.containers.create(id, options?)`

Creates a bounded generic container `container:<id>`. Resource-internal.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `id` | string | Id of letters, digits and `_ - .`, at most `maxIdentifierLength` (96). |
| `options?` | table | `label`, `slots`, `maxWeight`, `ownerSource` (a player source resolved to a citizen id), `groups`, `coords`, `distance`, `access`, `temporary`, `items` (seed rows, validated like any item write). |

**Returns**

- **created** — true with the inventory view, or false.
- **reason** — `invalid container options`, `container owner is unavailable`, `invalid container identifier`, `container requires a server-side access boundary`, `could not create container`, or a seed error such as `invalid item table`.

**Example**

```lua
local ok, view = KoraInventory.containers.create('stash-box-9', { label = 'Crate', slots = 10, coords = vector3(1.0, 2.0, 3.0), distance = 2.0 })
```

**Representative console output**

```text
ok = true, view.key = 'container:stash-box-9'
```

### `KoraInventory.containers.open(source, id)`

Opens an existing container for a player through the normal access checks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player server id. |
| `id` | string | Container id. |

**Returns**

- **opened** — boolean.
- **result** — session payload or `invalid container open request`, `container not found`, an access reason.

**Example**

```lua
KoraInventory.containers.open(src, 'stash-box-9')
```

**Representative console output**

```text
The container opens beside the player's inventory.
```

### `KoraInventory.containers.bindItem(source, slot, options?)`

Binds a new container to the unique item in a player's slot and writes the generated id into the item. Returns the existing id if already bound.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player server id. |
| `slot` | integer | Slot holding the item. |
| `options?` | table | Container options as `create`; `portable = true` makes it possession-based instead of owner-based. |

**Returns**

- **bound** — true with the container id.
- **reason** — `invalid item container request`, `item or player not found`, `invalid container options`, `container identifier limit is too small`, or a write error.

**Example**

```lua
local ok, id = KoraInventory.containers.bindItem(src, 4, { label = 'Duffel', slots = 15, maxWeight = 40000, portable = true })
```

**Representative console output**

```text
ok = true, id = 'item-source-12-4-1523-482913'
```

### `KoraInventory.containers.openItem(source, slot)`

Opens the container bound to the item in a slot.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player server id. |
| `slot` | integer | Slot with a bound item. |

**Returns**

- **opened** — boolean.
- **result** — payload or `item has no server-bound container`.

**Example**

```lua
KoraInventory.containers.openItem(src, 4)
```

**Representative console output**

```text
Opens container:<id>.
```

### `KoraInventory.containers.openConfiguredItem(source, slot)`

The entry point used by the Use action: resolves the item definition from `containers.items`, binds on first use, re-installs the possession policy and opens it.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player server id. |
| `slot` | integer | Slot with the configured item. |

**Returns**

- **opened** — boolean.
- **result** — payload or `item is not a portable container`, `bound container not found`, a bind error.

**Example**

```lua
KoraInventory.containers.openConfiguredItem(src, 7)
```

**Representative console output**

```text
The backpack opens; `kora_inventory:server:openedContainer` fires from the use flow.
```

### `KoraInventory.containers.isPortableItem(item)`

True when the item name is configured in `containers.items`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `item` | table | Item table with a `name`. |

**Returns**

- **portable** — boolean.

**Example**

```lua
if KoraInventory.containers.isPortableItem(item) then end
```

**Representative console output**

```text
true for backpack
```

### `KoraInventory.containers.allowNested(item)`

True when that portable item may be stored inside another container (`allowNested = true`).

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `item` | table | Item table. |

**Returns**

- **allowed** — boolean.

**Example**

```lua
local ok = KoraInventory.containers.allowNested(item)
```

**Representative console output**

```text
false by default
```

## Common use cases

- Backpacks, duffels and other items that carry their own storage.
- Police evidence lockers and confiscation with an on-duty policy.

## Limits and related APIs

None of these functions is an export, so another resource cannot call them. The only supported external hooks are the backpack item, `Config.kora_inventory.containers.items` and the `containers.evidence.access` callback in `config.lua` (the shipped one allows only on-duty police). Never forward client-supplied container ids, evidence ids, targets or item records into these calls if you extend the resource. Evidence is denied entirely if the access setting is not a function.

## Related guides

- [Stashes](./stashes.md)
- [Items and metadata](./items.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

`server/containers.lua` is a trusted, server-only domain with no NUI callback or client net event. Container ids, owners, evidence cases, target players, item records and slots must be resolved by trusted server code.

### What is reachable from other resources

The module tables `KoraInventory.containers`, `KoraInventory.evidence` (alias `KoraInventory.confiscation`) are globals inside this resource's server realm. **No export exposes them.** Other resources can reach this domain through:

- the configured portable container items (using the item from the player's inventory opens it, no extra code),
- `Config.kora_inventory.containers.evidence.access`, the trusted callback that authorises evidence actions,
- the `kora_inventory:server:openedContainer` and `kora_inventory:server:evidenceMoved` events.

The functions below describe the module for code that runs inside kora_inventory.

### Generic containers

`containers.create(id, options)` makes a secondary inventory `container:<id>`. Ids are strict, bounded identifiers (`containers.maxIdentifierLength`). A new container is rejected unless it has an owner derived from `ownerSource`, a trusted `access` or `groups` policy, or fixed `coords`. Options include `label`, `slots`, `maxWeight`, `groups`, `coords`, `distance`, `access`, `temporary`, `items` (validated by the normal slot, item and weight rules). `containers.open(source, id)` opens an existing container through the normal access and distance checks.

### Portable containers

`containers.bindItem(source, slot, options)` reads the real kora_core-owned slot, derives the caller's citizen id, generates a container id on the server and writes it to the item's `info.containerId` through kora_core's mutation funnel. `containers.openItem(source, slot)` reads the same current slot. A browser item table, owner or container id is never accepted.

`Config.kora_inventory.containers.items` promotes named unique items to portable containers. The shipped `backpack` is 20 slots and 60000 weight: using it from the player's own inventory binds an id on first use and opens it afterwards. Its access policy proves current possession of that exact item on every open and transfer, so giving the item gives access without exposing the id. Portable containers cannot be put into other containers, nor inside themselves, unless `allowNested = true` together with an explicit server policy.

### Evidence and confiscation

- `evidence.open(source, evidenceId)`
- `evidence.seize(source, targetSource, evidenceId, sourceSlot, amount, evidenceSlot?)`
- `evidence.release(source, targetSource, evidenceId, evidenceSlot, amount, playerSlot?)`

Evidence is default-deny. `containers.evidence.access(source, action, context)` must return `true` (or `false, reason`); the default allows only an on-duty `police` job. Seize and release resolve both player inventories on the server and check target entity existence, routing bucket, range (`distance`), the exact slot and amount, capacity and the policy again while holding deterministic locks. Metadata is carried only from the server item record. A successful move fires `kora_inventory:server:evidenceMoved` after both views were broadcast.

Do not add a generic net event such as `openContainer` or `seizeEvidence`; a resource that wants a player-facing action translates its own validated interaction into a server call.
