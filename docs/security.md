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
- **Audit.** Mutations are recorded in an in-memory ring (`auditLimit`) and emitted as `kora_inventory:server:audit`. The `kora_inventory_audit` table exists but is not written by the shipped code (see [Database](./api/persistence.md)).

## Player trades

The trade window (see [Player trades](./api/trade.md)) is the classic duplication and scam target, so it follows these rules:

- **Ids only from clients.** Three net events and one intent exist. `kora_inventory:server:tradeRequest` takes a target server id; `kora_inventory:server:tradeRespond` takes a trade id and a strict boolean; `kora_inventory:server:tradeCancel` takes a trade id. All three ignore calls from other resources (`GetInvokingResource()`) and malformed values. Everything inside the window is the `trade` intent on the normal intent pipeline: the session token and lease are checked with the same `validSession` every intent uses (which also refuses downed and cuffed players), the token must be the session the server opened for this trade, the sender must be a member of the trade, and the operation must fit its phase. `offer` and `unoffer` also require the inventory revision the page rendered. No message carries an item record, name, label, metadata, price, weight or inventory id; an extra field is ignored, and the item is always read from the server's own copy of the slot.
- **Server-generated trade ids**, one trade (or pending request) per player, and a per-player request cooldown.
- **Offers are references.** An offer is a slot and an amount in the offerer's own inventory, recorded with the item's name and metadata. Nothing moves before the commit.
- **Any change un-readies both.** Every change to either side, and any revision change of either player's inventory, clears both players' Ready and Confirm and unfreezes the offers; offers that no longer match their slot are dropped. The monitor checks this twice a second, and every trade action checks it first.
- **Two-stage confirm.** Ready carries the trade revision the player saw; a stale one is refused. When both are ready the offers freeze and a snapshot of every offered stack is taken. Confirm is refused until `trade.confirmDelay` seconds have passed and also carries the revision the player saw.
- **Atomic commit.** Under both players' inventory locks (sorted, non-blocking, so no deadlock), the server re-validates presence, routing bucket, distance, downed/cuffed, the snapshot (name, metadata and amount of every offered stack and the revision), busy slots, cash balances and the receivers' weight and slots after outgoing items leave. `swapItems` hooks (action `give`) may refuse. It plans both final inventories as drafts, re-checks after the hooks that nothing moved, and writes only changed slots through kora_core's `setPath`; ledger cash moves last through kora_core `transferMoney`. If any write or the cash transfer fails, every written slot is restored exactly. Physical cash moves as items inside the same plan and rollback.
- **Cancellation is always safe** because nothing has moved: either player cancelling, closing the trade's inventory session, disconnecting, being downed or cuffed, moving out of range or bucket, `trade.maxDuration`, or trading being turned off.
- **No identity leak.** The partner's name and server id never reach the page; the request dialog does not name the requester; partner offers carry display fields (label, image, `displayMeta`) but not raw metadata.
- **Audit.** Each committed trade records a `trade` audit entry for both players and fires `kora_inventory:server:tradeCompleted` and one `itemsMoved` (`action = 'trade'`) per stack.
- **Tested.** `test/smoke/trade.lua` drives the state machine and commit against an in-memory world (every refusal leaves both inventories and balances untouched; a 300-round fuzz checks that item and cash totals are conserved and that refused commits change nothing) and runs a real trade through `server.lua`.
