---
title: "Durable player exchanges"
sidebar_position: 15
---


# Durable player exchanges

A durable exchange swaps items, cash and dealer reputation for a player in one atomic, idempotent database transaction with a permanent receipt. It exists for trusted gameplay domains (the shipped allow-list is `kora_drugs`) that must never pay out twice, even across crashes and restarts. Your gameplay resource decides the terms; the inventory plans capacity and commits.

Namespace: `exports.kora_inventory` · Source: `server/exchange.lua`

## How it works

The export validates the request shape and size, takes the player's inventory lock, joins any earlier worker for the same key, and looks up an existing receipt. If none exists it opens a kora_core column fence on the recipient's `inventory`, `money` and `metadata`, plans the exchange against the current items (removing `take` entries, adding `give` entries, adding cash as money or as the cash item, adjusting `metadata.rep.dealer`), then writes the receipt and the player row in one SQL transaction. An unknown outcome stays fenced and is reconciled later; the same key returns the original receipt. A background loop every 30 seconds reconciles pending operations, including offline recipients.

## Paying out safely

1. **Authorise and price the deal** — Your resource checks the player, the location and the terms on the server and picks a unique operation key per real-world event.
2. **Execute** — Call `ExecutePlayerExchange(source, key, request)`. Do not pay anything else yourself.
3. **Handle pending** — If the result is `nil, 'pending', message`, retry with the same key; never create a new key.
4. **Read the receipt** — Use the returned receipt, or `GetPlayerExchange(key)` later, as the proof of payout.

## Terms used on this page

| Term | Meaning |
| --- | --- |
| Operation key | Your idempotency key, 1 to 128 characters. Reusing it with identical terms and recipient returns the first receipt; changing terms or recipient returns `conflict`. |
| Fence | kora_core's per-player column lock that blocks ordinary writes while an exchange is unsettled. |
| Receipt | The permanent row in `kora_inventory_player_exchanges`. |

## Exchange request

The request must contain only these keys; unknown keys reject the whole request.

| Option | Type | Description |
| --- | --- | --- |
| `citizenid` | string | Required. 1 to 50 characters; must equal the online player's character. |
| `take` | table[] | Up to 32 `{ name, amount }` entries (amount 1 to 1,000,000,000) removed from the player. No `info`. |
| `give` | table[] | Up to 32 `{ name, amount, info? }` entries added. Weapon items and, with physical cash on, the cash item are refused. |
| `cash` | integer | Non-negative whole amount (0 to 1,000,000,000) credited as cash. Rejected while the cash account has a transaction tax for adds. |
| `dealerRep` | integer | Signed whole change to `metadata.rep.dealer` (-1,000,000 to 1,000,000); the result never drops below 0. |
| `reason` | string | Up to 120 characters, default `Domain exchange`. |

## Functions

Both exports are callable only by resources named in `Config.kora_inventory.exchangeCallers`. The calling resource owns its own key namespace.

### `exports.kora_inventory:ExecutePlayerExchange(source, operationKey, request)`

Performs a durable exchange for an online player and returns its receipt.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `source` | integer | Player server id (1 to 65535). |
| `operationKey` | string | Idempotency key. |
| `request` | table | See the exchange request table. |

**Returns**

- **receipt** — `{ provider, operationKey, citizenid, cash, dealerRep, request, completedAt }`, or nil.
- **code** — on failure `rejected`, `pending`, `conflict` or `unavailable` (or a kora_core / SQL code).
- **message** — human-readable detail, for example `Insufficient exchange items.`, `Unsupported exchange item.`, `Exchange key has different terms or recipient.`, `Inventory storage is not ready.`, `Exchange is already running.`.

**Example**

```lua
local receipt, code, message = exports.kora_inventory:ExecutePlayerExchange(src, ('sale-%s-%d'):format(citizenid, saleId), {
    citizenid = citizenid,
    take = { { name = 'weed_baggy', amount = 5 } },
    cash = 2500,
    dealerRep = 2,
    reason = 'street sale',
})
if not receipt then
    print(code, message)   -- on 'pending' retry with the SAME key
end
```

**Representative console output**

```text
receipt = { provider = 'kora_drugs', operationKey = 'sale-ABC123-77', citizenid = 'ABC123', cash = 2500, dealerRep = 2, completedAt = 1767225600, ... }
```

### `exports.kora_inventory:GetPlayerExchange(operationKey)`

Reads (and reconciles) a receipt belonging to the calling resource.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `operationKey` | string | The key you used. |

**Returns**

- **receipt** — the stored receipt, or nil.
- **code** — `not_found` only after earlier workers have settled and a locking read confirms no receipt; otherwise `pending`.
- **message** — detail.

**Example**

```lua
local receipt, code = exports.kora_inventory:GetPlayerExchange('sale-ABC123-77')
if not receipt and code == 'not_found' then
    -- safe to run the exchange for the first time
end
```

**Representative console output**

```text
receipt table, or nil, 'not_found'
```

## Common use cases

- Drug sales that remove product and pay cash and reputation atomically.
- Any reward that must never duplicate after a crash.

## Limits and related APIs

Only resources listed in `exchangeCallers` can call it. The recipient must be online for `ExecutePlayerExchange`. Weapon outputs and direct cash-item legs are rejected. Cash rewards need transaction tax to be zero. Never expose these exports to a client event.

## Related guides

- [Player items](./player-items.md)
- [Persistence](./persistence.md)
- [Configuration](./configuration.md)

## Operating notes (from the code)

Facts below were written from the current code of this resource; they add to, and where noted refine, the reference above.

`ExecutePlayerExchange(source, operationKey, request)` is a server-only export for trusted gameplay resources named in `Config.kora_inventory.exchangeCallers` (default `{ kora_drugs = true }`). It swaps items, cash and dealer reputation for one player in a single durable, idempotent operation. No client event exposes it; the caller must authorise the interaction and choose every term on the server. The calling resource owns its key namespace.

```lua
local receipt, code, message = exports.kora_inventory:ExecutePlayerExchange(source, 'sale:' .. saleId, {
    citizenid = citizenid,
    take = { { name = 'weed_bag', amount = 5 } },
    give = { { name = 'marked_bills', amount = 1, info = { worth = 500 } } },
    cash = 250,
    dealerRep = 2,
    reason = 'Street sale',
})
```

### Request

| Field | Rules |
| --- | --- |
| `citizenid` | Required string, 1-50 characters. |
| `take` | List (up to 32) of `{ name, amount }`; amount a whole number 1 to 1000000000. |
| `give` | List (up to 32) of `{ name, amount, info? }`. Weapon outputs and direct physical-currency item legs are rejected; use `cash`. |
| `cash` | Non-negative whole number, default 0. |
| `dealerRep` | Signed whole number, default 0. Updates `metadata.rep.dealer`; a negative result is clamped to zero. |
| `reason` | String up to 120 characters. |

Unknown fields are rejected, and an exchange with no terms at all is rejected. The operation key is a string of 1-128 characters.

### Behaviour

The export plans against the current inventory, validates capacity, and uses kora_core's durable inventory, money and metadata fences. One SQL transaction writes the player values and a permanent resource-scoped receipt into `kora_inventory_player_exchanges`.

- Success returns the receipt: provider, operation key, citizen id, cash, reputation delta, canonical request fingerprint and completion time.
- Failure returns `nil, code, message`.
- Reusing a key with identical terms and recipient returns the original receipt. Changing terms or recipient returns `conflict`.
- Unknown outcomes stay fenced (`pending`). Retry the same key; never create a new reward key. Recovery also reconciles pending operations after restarts, including offline recipients.
- `GetPlayerExchange(operationKey)` returns the calling resource's receipt and reports `not_found` only after the earlier worker has settled and a locking read confirms there is none.
- Cash rewards honour the configured item-backed cash authority. A nonzero cash transaction tax is rejected, so profiles that use these rewards need the tax disabled. Marked-bill output metadata is preserved, but the item must exist in the registry.
