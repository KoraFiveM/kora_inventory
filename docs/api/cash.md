---
title: "Physical cash bridge"
sidebar_position: 17
---


# Physical cash bridge

When `Config.kora_inventory.cash.asItem` is on, the cash account lives as a stackable item. These seven exports are the private bridge kora_core uses to read and change that stack. They answer only to kora_core: any other caller receives `physical cash is restricted to kora_core`. Gameplay resources keep using kora_core's money API (`addMoney`, `removeMoney`, `getMoney`) or `AddItem`/`RemoveItem` on the cash item, which are routed there.

Namespace: `exports.kora_inventory` · Source: `server.lua (physicalCash* functions)`

## How it works

Each function checks that the invoking resource is `kora_core` and that the account matches the configured one, then works under a lock on the player. Credits go through the normal add path (capacity checks, revision bump, live patch, audit entry `cash-add`, item receipt). Debits plan across the cash stacks lowest slot first and fail with `insufficient funds` without partial removal. A transfer debits one player and credits the other under both locks and rolls back the debit if the credit fails.

## Functions

Documented for completeness. Do not call these from your own resources.

### `exports.kora_inventory:physicalCashGet(src, account)`

Returns the player's cash balance as the sum of all cash stacks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `account` | string | Configured account name. |

**Returns**

- **balance** — number, or nil with `physical cash is restricted to kora_core` / `physical cash is not configured for this account`.

**Example**

```lua
-- kora_core only
local balance = exports.kora_inventory:physicalCashGet(src, 'cash')
```

**Representative console output**

```text
2450
```

### `exports.kora_inventory:physicalCashAdd(src, account, amount, reason?)`

Credits cash items.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `account` | string | Account name. |
| `amount` | integer | Positive whole amount. |
| `reason?` | string | Audit text. |

**Returns**

- **added** — true, or false with `invalid cash amount`, a capacity reason (`over weight`, `no free slot`) or the restriction message.

**Example**

```lua
exports.kora_inventory:physicalCashAdd(src, 'cash', 500, 'paycheck')
```

**Representative console output**

```text
true; a +500 receipt is shown.
```

### `exports.kora_inventory:physicalCashRemove(src, account, amount, reason?)`

Debits cash items across stacks.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `account` | string | Account name. |
| `amount` | integer | Positive whole amount. |
| `reason?` | string | Audit text. |

**Returns**

- **removed** — true, or false with `insufficient funds`, `invalid cash amount` or the restriction message.

**Example**

```lua
exports.kora_inventory:physicalCashRemove(src, 'cash', 120, 'fine')
```

**Representative console output**

```text
true or false, 'insufficient funds'
```

### `exports.kora_inventory:physicalCashSet(src, account, amount, reason?)`

Makes the balance exactly `amount` by crediting or debiting the difference.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `account` | string | Account name. |
| `amount` | integer | Non-negative whole amount. |
| `reason?` | string | Audit text. |

**Returns**

- **set** — true, or false with `invalid cash amount` or a credit/debit failure.

**Example**

```lua
exports.kora_inventory:physicalCashSet(src, 'cash', 0, 'reset')
```

**Representative console output**

```text
true
```

### `exports.kora_inventory:physicalCashTransfer(fromSrc, toSrc, account, amount, reason?)`

Moves cash from one player to another atomically, checking the recipient can carry it.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `fromSrc` | integer | Paying player. |
| `toSrc` | integer | Receiving player. |
| `account` | string | Account name. |
| `amount` | integer | Positive whole amount. |
| `reason?` | string | Audit text. |

**Returns**

- **transferred** — true, or false with `invalid cash transfer`, `player unavailable`, `insufficient funds` or a capacity reason.

**Example**

```lua
exports.kora_inventory:physicalCashTransfer(a, b, 'cash', 200, 'trade')
```

**Representative console output**

```text
true; audit entry `cash-transfer`.
```

### `exports.kora_inventory:physicalCashImport(src, account, amount)`

Converts a legacy ledger balance into cash items when physical cash is first activated.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `account` | string | Account name. |
| `amount` | integer | Non-negative whole legacy balance. |

**Returns**

- **imported** — true (also for 0), or false with `invalid legacy cash balance` or a capacity reason.

**Example**

```lua
exports.kora_inventory:physicalCashImport(src, 'cash', 3000)
```

**Representative console output**

```text
true
```

### `exports.kora_inventory:physicalCashCanImport(src, account, amount)`

Checks whether the player could receive an imported balance.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `src` | integer | Player server id. |
| `account` | string | Account name. |
| `amount` | integer | Non-negative whole amount. |

**Returns**

- **possible** — boolean, with a reason (`invalid cash amount`, `over weight`, `no free slot`) on false.

**Example**

```lua
local ok, why = exports.kora_inventory:physicalCashCanImport(src, 'cash', 3000)
```

**Representative console output**

```text
true
```

## Limits and related APIs

kora_core is the only caller allowed. Physical cash cannot be stocked in shops, replaced by `SetInventory`, or changed by a whole-inventory replace. Enabling or disabling `cash.asItem` on a live server is a data migration. If kora_inventory stops, kora_core fails closed rather than creating a second balance.

## Related guides

- [Configuration](./configuration.md)
- [Player items](./player-items.md)
