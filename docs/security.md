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
- **Net event guard.** Internal events reject calls that come from another resource (`GetInvokingResource()`).
- **Containers and evidence** have no client entry point; see [Containers and evidence](./api/containers.md).
- **Provider conflicts.** Start is refused if a real `qb-inventory`, `ox_inventory` or `qb-weapons` is running.
- **Audit.** Mutations are recorded in an in-memory ring (`auditLimit`) and emitted as `kora_inventory:server:audit`. Every item *creation* is additionally written, with the invoking resource, to the `kora_inventory_audit` table in batches (see [Item-creation audit log](./api/persistence.md#item-creation-audit-log)), and unusual volumes raise `kora_inventory:server:auditAnomaly`.
- **Admin tools.** `/invaudit` needs the ACE `kora_inventory.audit` and `/omnipack` needs `kora_inventory.omnipack` (names configurable). Neither command is trusted on its own: the audit viewer's data callback re-checks the ACE on every request, and the omnipack re-checks it when it opens, on every request of the open window and on every take. Both reach the browser only as presentation. The audit overlay is read-only and has no write path; the omnipack takes an item name from the server's own list by slot, never from the browser, bounds the amount (`omnipack.maxAmount`), refuses cash items and items no longer registered, and records every take as an `omnipack` audit entry. Grant these ACEs only to trusted staff; see [Commands](./commands.md#convars-and-aces).
