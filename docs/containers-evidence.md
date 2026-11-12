---
title: Containers and evidence
sidebar_position: 11
---

# Item containers, evidence and confiscation

`server/containers.lua` is a trusted, server-only domain with no NUI callback or client net event. Container ids, owners, evidence cases, target players, item records and slots must be resolved by trusted server code.

## What is reachable from other resources

The module tables `KoraInventory.containers`, `KoraInventory.evidence` (alias `KoraInventory.confiscation`) are globals inside this resource's server realm. **No export exposes them.** Other resources can reach this domain through:

- the configured portable container items (using the item from the player's inventory opens it, no extra code),
- `Config.kora_inventory.containers.evidence.access`, the trusted callback that authorises evidence actions,
- the `kora_inventory:server:openedContainer` and `kora_inventory:server:evidenceMoved` events.

The functions below describe the module for code that runs inside kora_inventory.

## Generic containers

`containers.create(id, options)` makes a secondary inventory `container:<id>`. Ids are strict, bounded identifiers (`containers.maxIdentifierLength`). A new container is rejected unless it has an owner derived from `ownerSource`, a trusted `access` or `groups` policy, or fixed `coords`. Options include `label`, `slots`, `maxWeight`, `groups`, `coords`, `distance`, `access`, `temporary`, `items` (validated by the normal slot, item and weight rules). `containers.open(source, id)` opens an existing container through the normal access and distance checks.

## Portable containers

`containers.bindItem(source, slot, options)` reads the real kora_core-owned slot, derives the caller's citizen id, generates a container id on the server and writes it to the item's `info.containerId` through kora_core's mutation funnel. `containers.openItem(source, slot)` reads the same current slot. A browser item table, owner or container id is never accepted.

`Config.kora_inventory.containers.items` promotes named unique items to portable containers. The shipped `backpack` is 20 slots and 60000 weight: using it from the player's own inventory binds an id on first use and opens it afterwards. Its access policy proves current possession of that exact item on every open and transfer, so giving the item gives access without exposing the id. Portable containers cannot be put into other containers, nor inside themselves, unless `allowNested = true` together with an explicit server policy.

## Evidence and confiscation

- `evidence.open(source, evidenceId)`
- `evidence.seize(source, targetSource, evidenceId, sourceSlot, amount, evidenceSlot?)`
- `evidence.release(source, targetSource, evidenceId, evidenceSlot, amount, playerSlot?)`

Evidence is default-deny. `containers.evidence.access(source, action, context)` must return `true` (or `false, reason`); the default allows only an on-duty `police` job. Seize and release resolve both player inventories on the server and check target entity existence, routing bucket, range (`distance`), the exact slot and amount, capacity and the policy again while holding deterministic locks. Metadata is carried only from the server item record. A successful move fires `kora_inventory:server:evidenceMoved` after both views were broadcast.

Do not add a generic net event such as `openContainer` or `seizeEvidence`; a resource that wants a player-facing action translates its own validated interaction into a server call.
