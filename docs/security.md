---
title: Security model
sidebar_position: 8
---

# Security model

- **Server authority.** Client data is intent only. Every client mutation validates an active session lease, both inventory revisions, access, routing bucket and distance before touching state. Item records, labels, weights, prices, definitions and inventory ids from clients are never trusted; the server resolves them again.
- **No bulk replacement.** There is no client event, callback or NUI endpoint that accepts a whole inventory.
- **Shops** are read-only in the generic transfer path; items leave only through the `buy` intent or `buyItem`.
- **Player data** is only changed through kora_core exports. Cash handling goes through kora_core (`addMoney`, `removeMoney`), optionally mirrored as a physical cash item.
- **Inspection** of another player's inventory is default-deny; see [Hooks](./api/hooks.md).
- **Downed, cuffed and busy** players cannot open or use the inventory (`blockWhenDowned`, `blockWhenCuffed`, `blockWhileBusy`, `uiBlockBag`). The server enforces the downed and cuffed rules from player metadata; the client mirrors them. While an item is in use its slot cannot be dropped, given or moved.
- **Coordinates.** A trusted `coords` policy may be one point or a list. Both pass the single `withinCoordinates` check; an empty or malformed non-nil policy denies, `nil` means unbounded. List entries may override `distance`.
- **Server-only data.** Durable secondary items may carry trusted top-level `serverData`; it is removed from client views, never copied into purchased item metadata, and only reaches integrations through post-commit server events.
- **Weapon carry.** Clients render the `kora_inventory:weaponCarry` state bag and may only confirm a draw the server requested; see [Weapons](./api/weapons.md).
- **Weapon upkeep.** `kora_inventory:server:clearJam` is payload-free on purpose: the server clears the jam on the weapon it recorded as drawn, so a client cannot name another weapon or slot, and it cannot clear a jam without the server-run progress bar and its minimum elapsed time. Jams, kits and cleaning are decided on the server from that same record. `kora_inventory:server:repairConfirm` carries only a counter index into the owner's config; it is honoured only against a live server-issued quote, after the player's position and routing bucket are re-checked and the price is recomputed. Shots reported while a weapon is jammed are rejected server-side, so a client that ignores the jam gains nothing. See [Weapons](./api/weapons.md).
- **Net event guard.** Internal events reject calls that come from another resource (`GetInvokingResource()`).
- **Containers and evidence** have no client entry point; see [Containers and evidence](./api/containers.md).
- **Provider conflicts.** Start is refused if a real `qb-inventory`, `ox_inventory` or `qb-weapons` is running.
- **Audit.** Mutations are recorded in an in-memory ring (`auditLimit`) and emitted as `kora_inventory:server:audit`. The `kora_inventory_audit` table exists but is not written by the shipped code (see [Database](./api/persistence.md)).
