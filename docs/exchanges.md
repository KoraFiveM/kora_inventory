---
title: Player exchanges
sidebar_position: 14
---

# Durable player exchanges

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

## Request

| Field | Rules |
| --- | --- |
| `citizenid` | Required string, 1-50 characters. |
| `take` | List (up to 32) of `{ name, amount }`; amount a whole number 1 to 1000000000. |
| `give` | List (up to 32) of `{ name, amount, info? }`. Weapon outputs and direct physical-currency item legs are rejected; use `cash`. |
| `cash` | Non-negative whole number, default 0. |
| `dealerRep` | Signed whole number, default 0. Updates `metadata.rep.dealer`; a negative result is clamped to zero. |
| `reason` | String up to 120 characters. |

Unknown fields are rejected, and an exchange with no terms at all is rejected. The operation key is a string of 1-128 characters.

## Behaviour

The export plans against the current inventory, validates capacity, and uses kora_core's durable inventory, money and metadata fences. One SQL transaction writes the player values and a permanent resource-scoped receipt into `kora_inventory_player_exchanges`.

- Success returns the receipt: provider, operation key, citizen id, cash, reputation delta, canonical request fingerprint and completion time.
- Failure returns `nil, code, message`.
- Reusing a key with identical terms and recipient returns the original receipt. Changing terms or recipient returns `conflict`.
- Unknown outcomes stay fenced (`pending`). Retry the same key; never create a new reward key. Recovery also reconciles pending operations after restarts, including offline recipients.
- `GetPlayerExchange(operationKey)` returns the calling resource's receipt and reports `not_found` only after the earlier worker has settled and a locking read confirms there is none.
- Cash rewards honour the configured item-backed cash authority. A nonzero cash transaction tax is rejected, so profiles that use these rewards need the tax disabled. Marked-bill output metadata is preserved, but the item must exist in the registry.
