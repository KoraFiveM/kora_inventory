---
title: "Evidence and confiscation"
sidebar_position: 14
---


# Evidence and confiscation

Evidence inventories (`evidence:<id>`) hold items taken from players or crime scenes. They are default-deny: every open, seize and release first runs the trusted policy `Config.kora_inventory.containers.evidence.access(source, action, context)`, and the move itself re-checks both players on the server. The Lua table `KoraInventory.evidence` (also `KoraInventory.confiscation`) is internal to kora_inventory; external resources interact by supplying the policy in `config.lua`, opening the evidence inventory through the inventory UI, and listening to `kora_inventory:server:evidenceMoved`.

Namespace: `KoraInventory.evidence` · Source: `server/containers.lua (evidence table), config.lua containers.evidence`

## How it works

An evidence inventory is created on first use with `evidence.slots` and `evidence.maxWeight` and an access function that calls the policy with action `open`. Seizing and releasing take the policy decision, then check the target player's ped, routing bucket (`evidence.requireSameBucket`) and distance (`evidence.distance`, 3.0), resolve both inventories under deterministic locks, re-read the exact source slot and amount, check capacity with `canAdd`, and move the item with a rollback if the second half fails. Metadata always comes from the source item. After both inventories are bumped and broadcast, `kora_inventory:server:evidenceMoved` fires.

## Setting up evidence handling

1. **Write the policy** — Edit `containers.evidence.access` in `config.lua` so it returns true only for staff you trust. The shipped version allows only an on-duty `police` job.
2. **Resolve everything on the server** — Your police resource decides which officer, target, case id, slot and amount, then calls the evidence functions (inside this resource) or opens the evidence inventory for the officer.
3. **React to the move** — Listen to `kora_inventory:server:evidenceMoved(action, source, target, evidenceId, item)` to log chain of custody.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Action | The string passed to the policy: `open`, `seize` or `release`. |
| Context | Extra data given to the policy: `{ evidenceId }` for open; `{ evidenceId, target, slot, amount }` for moves. |

## Functions

These are resource-internal functions, documented so you can understand and extend the behaviour. The policy callback in `config.lua` is the supported way to control them.

### `KoraInventory.evidence.open(source, id)`

Opens an evidence inventory after the evidence policy approves `open`.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Officer server id. |
| `id` | string | Evidence id. |

**Returns**

- **opened** — boolean.
- **result** — session payload, or `invalid evidence open request`, `evidence access is not configured`, `evidence access policy failed`, or the policy's reason.

**Example**

```lua
local ok, result = KoraInventory.evidence.open(src, 'case-114')
```

**Representative console output**

```text
ok = true for an on-duty police officer.
```

### `KoraInventory.evidence.seize(source, target, evidenceId, slot, amount, evidenceSlot?)`

Moves items from a target player into evidence. Both players are resolved on the server; the policy, range, bucket, slot, amount and capacity are checked under locks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Officer server id. |
| `target` | integer | Target player server id. |
| `evidenceId` | string | Evidence id. |
| `slot` | integer | Slot in the target's inventory. |
| `amount` | integer | Amount. |
| `evidenceSlot?` | integer | Destination slot in evidence. |

**Returns**

- **moved** — true on success.
- **reason** — `invalid evidence transfer request`, a policy reason, `target player unavailable`, `different routing bucket`, `too far away`, `target player not found`, `item changed`, a capacity reason (`weight`, `slots`).

**Example**

```lua
local ok, why = KoraInventory.evidence.seize(officer, suspect, 'case-114', 5, 1)
```

**Representative console output**

```text
ok = true; `kora_inventory:server:evidenceMoved` fires with action `seize`.
```

### `KoraInventory.evidence.release(source, target, evidenceId, slot, amount, playerSlot?)`

Returns evidence items to a target player. Arguments mirror `seize`; `slot` is the slot in the evidence inventory.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Officer server id. |
| `target` | integer | Target player server id. |
| `evidenceId` | string | Evidence id. |
| `slot` | integer | Slot in evidence. |
| `amount` | integer | Amount. |
| `playerSlot?` | integer | Destination slot for the player. |

**Returns**

- **moved** — true on success.
- **reason** — as `seize`.

**Example**

```lua
KoraInventory.evidence.release(officer, suspect, 'case-114', 2, 1)
```

**Representative console output**

```text
ok = true; event action `release`.
```

## Common use cases

- Police evidence lockers.
- Confiscating items from a restrained player.
- Returning confiscated property.

## Limits and related APIs

Evidence is denied entirely if `containers.evidence.access` is not a function. A policy error is logged and treated as denial (`evidence access policy failed`). The functions are not exports; extend the resource or reach them through its UI. Never accept evidence ids, targets, slots or item data from a client.

## Related guides

- [Containers](./containers.md)
- [Events and callbacks](./events.md)
- [Configuration](./configuration.md)
