---
title: "Player trades"
sidebar_position: 25
---


# Player trades

Two nearby players can open a trade window, each put items and cash on their side, and swap everything at once after both have confirmed. Nothing moves until the very end, and then either the whole swap happens or nothing does.

Namespace: net events and the `trade` intent · Sources: `server/trade_state.lua` (rules), `server/trade.lua` (server wiring), `client/trade.lua` (prompt, command, keybind), `web/src/components/TradePanel.tsx` (window)

## How it works

1. **Request.** A player presses **Trade** in the top bar of their inventory (shown only while another player is in range), types `/trade`, or uses the trade keybind (unbound by default). The nearest player is picked locally with the same resolver the give action uses; with several players close by, the player points at one with kora_target. Only that player's server id is sent. The server checks that both players are online, in the same routing bucket, within `trade.distance` metres, not downed or cuffed, and not already trading, and applies the `trade.requestCooldown`.
2. **Answer.** The other player gets a kora_lib dialog ("A nearby player wants to trade with you") and has `trade.requestTimeout` seconds to accept. Declining, ignoring it or walking away ends the request. Neither player's name is shown anywhere.
3. **Offer.** On accept both players' inventories open, with the trade window in place of the second inventory (in every layout). Each side has `trade.slots` offer slots and, with `trade.allowCash`, a cash field. Drag a stack from your inventory onto **You offer**, or Shift+click it. A single item is offered at once; for a stack you are asked how many (Ctrl+drag offers half and Alt+drag one, as for moves). Right-click an offer, or drag it out of the trade column, to take it back. **They offer** is read-only and shows what the server says the other player offered.
4. **Ready.** When both press **Ready**, the offers freeze for `trade.confirmDelay` seconds (a countdown on the Confirm button).
5. **Confirm.** After the countdown both press **Confirm trade**. The server re-checks everything and commits.

Any change to either side, and any change to either player's inventory (a move, a drop, an item used up, anything that bumps its revision), clears both players' Ready and Confirm and unfreezes the offers. An offer whose slot no longer holds the item it pointed at is removed; cash above the player's balance is reset to 0. Both players must look again and press Ready again.

## Offers are references

An offer is `slot` plus `amount` in the offerer's own inventory, remembered together with that item's name and metadata. The item stays in the inventory until the commit and can still be moved or used (which simply un-readies the trade). Offered stacks carry a small badge with the offered amount in your inventory.

## The commit

Commit runs on the server only, under both players' inventory locks (taken together in a fixed order, so two trades can never deadlock; a lock that is held returns "inventory busy" instead of waiting). Inside the lock the server checks again:

- trading is enabled, both players are online, in the same routing bucket, within `trade.distance`, and not downed or cuffed;
- each offered slot still holds exactly the stack captured when both pressed Ready (same name, metadata and amount), the inventory revision has not moved since, and the slot is not busy with an item use;
- each cash offer is still covered by the player's balance;
- each player can carry what they receive once what they give has left (weight and slots);
- ox-style `swapItems` hooks (action `give`, one per offered stack, with a `trade` field) do not refuse.

It then builds both final inventories as drafts, re-checks after the hooks that neither inventory or player changed, writes only the slots that differ through kora_core's `setPath`, and, for ledger cash, moves the difference between the two cash offers with kora_core `transferMoney`. If any write or the cash transfer fails, every slot already written is put back exactly as it was, so both players end with what they started with. Unique items such as weapons keep their metadata (serial, durability, attachments) exactly.

When the commit is refused because an item, the cash or the room changed, the trade goes back to the offer stage with the reason shown in the window. When it is refused because a player left, walked away, changed bucket or was downed or cuffed, the trade ends.

## Cash

The cash field uses the server's cash:

- **Ledger cash** (default): the kora_core account named by `cash.account` (`cash`). The balance shown is `getMoney`; the swap is one `transferMoney` of the net difference, with the transaction tax skipped so each player receives exactly what both confirmed.
- **Physical cash** (`cash.asItem = true` and registered with kora_core): the cash item stacks. They are taken from the payer's lowest slots first and added to the receiver like any item, inside the same draft and rollback as the items. The cash item cannot be put in an item slot; use the cash field.

## When a trade ends without changes

Either player presses **Cancel trade**, closes their inventory (or opens another one), disconnects, is downed or cuffed, they move further apart than `trade.distance` or into different routing buckets, the trade has been open `trade.maxDuration` seconds, or trading is turned off. Each player can be in only one trade (or pending request) at a time.

## Transport

The browser never sends an item record, name, label, metadata, price or target. See [Security model](../security.md#player-trades) for the full rules.

| Message | Direction | Payload | Checked against |
| --- | --- | --- | --- |
| `kora_inventory:server:tradeRequest` | client to server | target server id | integer, cooldown, not trading, presence, bucket, distance, downed/cuffed |
| `kora_inventory:server:tradeRespond` | client to server | trade id, boolean | the trade exists, is pending, not expired, and the sender is the invited player; accept re-checks presence |
| `kora_inventory:server:tradeCancel` | client to server | trade id | the sender is in that trade |
| intent `trade` | client to server | `op`, `id`, and `slot`, `amount`, `cash` or `revision` | session token and lease (`validSession`), the trade's own session, membership, phase; `offer` and `unoffer` also the inventory revision |
| `kora_inventory:client:tradeInvite` | server to client | trade id, timeout ms | |
| `kora_inventory:client:tradeState` | server to client | the trade view for that player | |
| `kora_inventory:client:tradeEnded` | server to client | trade id, reason, completed | |

Intent operations (`payload.op`):

| op | Fields | Phase | Effect |
| --- | --- | --- | --- |
| `offer` | `slot`, `amount` (whole number; omitted = whole stack) | open | Adds or changes the offer for that slot. |
| `unoffer` | `slot` | open | Removes the offer for that slot. |
| `cash` | `cash` (whole number, 0 to the balance) | open | Sets your cash offer. |
| `ready` | `revision` (the trade revision you saw) | open | Marks you ready; both ready freezes the offers. |
| `unready` | none | open or locked | Clears your Ready; while frozen it clears both and unfreezes. |
| `confirm` | `revision` | locked, after the countdown | Marks you confirmed; both confirmed commits. |
| `cancel` | none | any | Ends the trade with no changes. |
| `keepalive` | none | any | Sent by the window every 30 seconds so the inventory lease does not expire while you wait for the other player. |

The trade view (`kora_inventory:nui:trade` in the page) contains `id`, `phase` (`open`, `locked`, `committing`), `revision`, `slots`, `allowCash`, `you` and `them` (each `offers`, `cash`, `ready`, `confirmed`; `you.balance` is your cash), `confirmInMs`, `confirmDelayMs`, `endsInMs` and `lastError`. Offers carry the slot, amount and the display fields the inventory already shows (label, image, weight, description, `displayMeta`); a partner's raw item metadata is not sent.

## Server events

| Event | Arguments | When |
| --- | --- | --- |
| `kora_inventory:server:tradeCompleted` | trade id, source A, source B, summary | After a committed trade. The summary has, per source, `gave` (name, amount, slot, metadata per stack) and `cash`. |
| `kora_inventory:server:itemsMoved` | source, payload with `action = 'trade'` | Once per stack that changed hands. |
| `kora_inventory:server:audit` | `'trade'`, source, details | Once per player with `trade`, `with`, `gave`, `received`, `cashGiven`, `cashReceived`, `cashMode`. |

## Client export

`exports.kora_inventory:requestTrade()` starts a request with the nearest player exactly as `/trade` does (returns `false, reason` when it cannot start). The server validates it like any other request.

## Configuration

`Config.kora_inventory.trade`, all editable in `/config`. Everything except `command` is read when it is used, so changes apply at once (`slots` and `allowCash` reach an open window the next time the inventory opens).

| Option | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Turns the feature on. Off hides the Trade button, refuses requests and ends open trades. |
| `slots` | `8` | Offer slots per side (1 to 32). |
| `allowCash` | `true` | Adds the cash field. |
| `distance` | `3.0` | Metres the players must stay within. |
| `requestTimeout` | `20` | Seconds to answer a request. |
| `confirmDelay` | `3` | Seconds offers stay frozen after both are ready before Confirm is accepted. |
| `maxDuration` | `300` | Seconds before an open trade is cancelled. |
| `requestCooldown` | `10` | Seconds between requests from one player. |
| `command` | `'trade'` | Chat command; empty for none. Read at resource start. |

## Limits

- The request dialog is kora_lib's alert; it cannot be closed from the server, so if the request ends while it is still open (timeout, cancelled, a player left) the player's answer is not sent; both players were already told the request ended.
- Trade cash is the single cash account; bank transfers are not part of a trade.
- Extra top-level fields on an item record (outside its metadata) are rebuilt from the item definition on arrival, the same as a give.

## Related guides

- [Security model](../security.md)
- [Configuration](./configuration.md)
- [Events and callbacks](./events.md)
- [Commands and keybinds](../commands.md)
