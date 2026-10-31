-- Contract coverage for the qb-inventory callback bridge.
--
-- Two things matter here. First, the handlers must be registered in kora_lib's
-- RETURN-VALUE form: upstream's `function(source, cb, ...)` shape would bind
-- `cb` to the first real argument and nothing would ever resolve on the client.
-- Second, and security-critical: upstream takes the item name, amount, price
-- and metadata straight from the browser payload. Every assertion below that
-- feeds a forged field checks the authority's own record was used instead, and
-- that a payload naming an inventory the caller has no session for is refused
-- before anything is removed.
local H = dofile('test/harness.lua')

local handlers = {}
local rejected, removed, added, dropped, purchases, prints = {}, {}, {}, {}, {}, {}

Kora = {
    callback = { register = function(name, fn) handlers[name] = fn end },
    distance = { player = function(_, coords, max) return (coords.d or 0) <= max end },
}

TriggerClientEvent = function(name, src, reason) rejected[#rejected + 1] = { name = name, src = src, reason = reason } end
print = function(message) prints[#prints + 1] = message end

local peds = { [7] = 70, [9] = 90 }
local pedCoords = { [70] = { x = 1, y = 1, z = 1, d = 0 }, [90] = { x = 1, y = 1, z = 1, d = 1.0 } }
local buckets = { [7] = 0, [9] = 0 }
local metadata = {
    [7] = { isdead = false, inlaststand = false, ishandcuffed = false },
    [9] = { isdead = false, inlaststand = false, ishandcuffed = false },
}

GetPlayerPed = function(src) return peds[src] or 0 end
GetEntityCoords = function(ped) return pedCoords[ped] end
GetPlayerRoutingBucket = function(src) return buckets[src] end
exports = { kora_core = { getPlayerData = function(_, src, fields)
    if fields and fields[1] == 'metadata' then return metadata[src] end
    return nil
end } }

local session = { token = 'tok-1', primary = 'player:7', secondary = 'stash:locker', expires = 999 }
local inventories = {
    ['player:7'] = { key = 'player:7', type = 'player', id = 7, slots = 41, items = {
        [3] = { name = 'water', amount = 5, slot = 3, weight = 100, info = { serial = 'AAA' } },
    } },
    ['player:9'] = { key = 'player:9', type = 'player', id = 9, slots = 41, items = {} },
    ['stash:secret'] = { key = 'stash:secret', type = 'stash', id = 'secret', slots = 50, items = {
        [1] = { name = 'diamond', amount = 99, slot = 1 },
    } },
    ['shop:ammunation'] = { key = 'shop:ammunation', type = 'shop', id = 'ammunation', slots = 10,
        label = 'Ammunation', items = {}, stock = {
            [2] = { name = 'pistol_ammo', amount = 10, price = 40, slot = 2 },
        } },
}

local function copy(value)
    if type(value) ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local nextDropId, canAdd, addSucceeds = 1, true, true

QbInventory = {
    internal = {
        key = function(kind, id) return ('%s:%s'):format(kind, tostring(id)) end,
        playerKey = function(src) return 'player:' .. src end,
        resolveInventory = function(ref) return ref, inventories[ref] end,
        sessionOf = function() return session end,
        sameDropBucket = function(src, inv)
            return inv.bucket == nil or inv.bucket == GetPlayerRoutingBucket(src)
        end,
        copy = copy,
        config = { interactionDistance = 3.0, requireSameBucket = true },
        lock = function(keys, fn) return fn(keys) end,
    },
    api = {
        CanAddItem = function(src, name, amount) return canAdd, canAdd or 'weight' end,
        RemoveItem = function(src, name, amount, slot, reason)
            local inv = inventories['player:' .. src]
            local item = inv and inv.items[slot]
            if not item or item.name ~= name or item.amount < amount then return false, 'item not in slot' end
            item.amount = item.amount - amount
            if item.amount == 0 then inv.items[slot] = nil end
            removed[#removed + 1] = { src = src, name = name, amount = amount, slot = slot, reason = reason }
            return true
        end,
        AddItem = function(src, name, amount, slot, info, reason)
            added[#added + 1] = { src = src, name = name, amount = amount, slot = slot, info = info, reason = reason }
            if not addSucceeds and reason ~= 'give-rollback' then return false, 'no room' end
            return true
        end,
        dropCreate = function(coords, items, bucket)
            local id = nextDropId
            nextDropId = nextDropId + 1
            inventories['drop:' .. id] = { key = 'drop:' .. id, type = 'drop', id = id, label = 'Ground drop',
                slots = 50, maxWeight = 100000, coords = coords, items = items, bucket = bucket }
            dropped[#dropped + 1] = { id = id, coords = coords, items = items, bucket = bucket }
            return id
        end,
        BuyItem = function(src, shopId, slot, amount)
            purchases[#purchases + 1] = { src = src, shopId = shopId, slot = slot, amount = amount }
            return true
        end,
    },
}

dofile('server/compat/qb_callbacks.lua')

for _, name in ipairs({
    'qb-inventory:server:GetCurrentDrops', 'qb-inventory:server:createDrop',
    'qb-inventory:server:attemptPurchase', 'qb-inventory:server:giveItem',
}) do
    H.ok(type(handlers[name]) == 'function', 'registers upstream callback ' .. name)
end

-- Registration form: kora_lib calls handler(src, ...) and uses the RETURN value.
-- If the bridge had copied upstream's (source, cb, item) signature, the second
-- positional argument would be the item, so this call would explode.
H.equal(handlers['qb-inventory:server:createDrop'](7, 'not-a-table'), false,
    'handlers take (src, ...) and return a value rather than upstream cb(...)')

-- --- createDrop ---
local createDrop = handlers['qb-inventory:server:createDrop']

-- A payload naming an inventory the session does not authorise is refused
-- before any removal happens, even though the caller HAS an open session.
local id = createDrop(7, { inventory = 'stash:secret', fromSlot = 1, amount = 99, name = 'diamond' })
H.equal(id, false, 'a drop from an inventory the session does not hold is refused')
H.equal(#removed, 0, 'the refused drop removed nothing')
H.equal(inventories['stash:secret'].items[1].amount, 99, 'the unrelated stash is untouched')
H.ok(#rejected > 0, 'the caller is told why')

-- The session secondary is not a legal drop source either.
rejected = {}
H.equal(createDrop(7, { inventory = 'stash:locker', fromSlot = 1 }), false,
    'even the session secondary cannot be dropped from')

-- Happy path, with every client-supplied item field forged.
rejected = {}
id = createDrop(7, { fromSlot = 3, amount = 2, name = 'diamond', weight = 0, info = { serial = 'FORGED' } })
H.equal(id, 1, 'a valid drop returns the new drop id')
H.equal(#removed, 1, 'exactly one removal')
H.equal(removed[1].name, 'water', 'the removed item name comes from the authority, not the payload')
H.equal(removed[1].amount, 2, 'the amount is the only quantity the payload contributes')
H.equal(removed[1].slot, 3, 'the slot is read from the payload')
H.equal(dropped[1].items[1].name, 'water', 'the dropped record is the real item, not the forged one')
H.equal(dropped[1].items[1].info.serial, 'AAA', 'metadata comes from the source item')
H.equal(dropped[1].items[1].amount, 2, 'the dropped amount matches what was removed')
H.equal(dropped[1].items[1].slot, 1, 'the drop is normalised to slot 1')
H.equal(dropped[1].coords, pedCoords[70], 'the drop position is read from the ped, never from the client')
H.equal(dropped[1].bucket, buckets[7], 'the drop bucket is read from the server')

-- Over-drawing and bad slots are refused.
removed = {}
H.equal(createDrop(7, { fromSlot = 3, amount = 99 }), false, 'dropping more than is held is refused')
H.equal(createDrop(7, { fromSlot = 3, amount = -1 }), false, 'a negative amount is refused')
H.equal(createDrop(7, { fromSlot = 40 }), false, 'an empty slot is refused')
H.equal(#removed, 0, 'none of the refused drops removed anything')

-- No session at all means no drop, whatever the payload says.
local realSessionOf = QbInventory.internal.sessionOf
QbInventory.internal.sessionOf = function() return nil end
H.equal(createDrop(7, { fromSlot = 3, amount = 1 }), false, 'no open session means no drop')
H.equal(#removed, 0, 'the sessionless drop removed nothing')
QbInventory.internal.sessionOf = realSessionOf

-- --- GetCurrentDrops ---
local drops = handlers['qb-inventory:server:GetCurrentDrops'](7)
H.equal(drops['1'].name, 'drop-1', 'the drop carries its upstream name')
H.ok(drops['1'].items == nil, 'drop contents are never handed to a client that has no session for them')
H.equal(drops['1'].coords, pedCoords[70], 'the already-broadcast coords are reported')
H.equal(drops['1'].entityId, 0, 'the bag prop is local to each client, so there is no network id to hand out')
buckets[9] = 22
H.equal(next(handlers['qb-inventory:server:GetCurrentDrops'](9)), nil, 'foreign-bucket drops are not listed')
H.ok(handlers['qb-inventory:server:GetCurrentDrops'](7)['1'], 'a foreign read cannot prune a live drop')
buckets[9] = 0

-- A drop taken from the authority stops being reported.
inventories['drop:1'] = nil
drops = handlers['qb-inventory:server:GetCurrentDrops'](7)
H.equal(next(drops), nil, 'a drop that no longer exists is pruned rather than reported')

-- --- attemptPurchase ---
local attemptPurchase = handlers['qb-inventory:server:attemptPurchase']

H.equal(attemptPurchase(7, { shop = 'shop-ammunation', amount = 2,
    item = { slot = 2, name = 'weapon_carbinerifle', price = 0, info = { forged = true } } }), true,
    'a valid purchase is allowed')
H.equal(#purchases, 1, 'exactly one purchase reached the authority')
H.equal(purchases[1].shopId, 'ammunation', "the 'shop-' prefix is stripped as upstream does")
H.equal(purchases[1].slot, 2, 'only the slot is taken from the payload')
H.equal(purchases[1].amount, 2, 'only the amount is taken from the payload')
H.ok(purchases[1].name == nil and purchases[1].price == nil,
    'no client-supplied name, price or metadata is forwarded to BuyItem')

purchases = {}
H.equal(attemptPurchase(7, { shop = 'shop-ammunation', amount = -5, item = { slot = 2 } }), false,
    'a negative amount is refused')
H.equal(attemptPurchase(7, { shop = 'shop-ammunation', amount = 'nope', item = { slot = 2 } }), false,
    'a non-numeric amount is refused')
H.equal(attemptPurchase(7, { shop = 'shop-invented', amount = 1, item = { slot = 2 } }), false,
    'a shop the server does not know is refused')
H.equal(attemptPurchase(7, { shop = 'shop-ammunation', amount = 999, item = { slot = 2 } }), false,
    'buying more than the authoritative stock is refused')
H.equal(attemptPurchase(7, { shop = 'shop-ammunation', amount = 1, item = { slot = 9 } }), false,
    'an empty shop slot is refused')
H.equal(#purchases, 0, 'none of the refused purchases reached the authority')

canAdd = false
H.equal(attemptPurchase(7, { shop = 'shop-ammunation', amount = 1, item = { slot = 2 } }), false,
    'a purchase the player cannot carry is refused')
H.equal(#purchases, 0, 'the capacity check runs before the money is taken')
canAdd = true

-- --- giveItem ---
local giveItem = handlers['qb-inventory:server:giveItem']
inventories['player:7'].items[3] = { name = 'water', amount = 5, slot = 3, weight = 100, info = { serial = 'AAA' } }
removed, added, rejected = {}, {}, {}

H.equal(giveItem(7, 9, 'diamond', 2, 3, { forged = true }), true, 'a valid give succeeds')
H.equal(removed[1].name, 'water', 'the given item is re-read from the slot, not taken from the payload')
H.equal(added[1].src, 9, 'the recipient is the requested target')
H.equal(added[1].name, 'water', 'the recipient receives the real item')
H.equal(added[1].amount, 2, 'the recipient receives the requested amount')
H.equal(added[1].info.serial, 'AAA', 'metadata comes from the source item, never from the payload')
H.ok(added[1].info.forged == nil, 'client-supplied metadata is discarded')

removed, added = {}, {}
H.equal(giveItem(7, 7, 'water', 1, 3), false, 'giving to yourself is refused')
H.equal(giveItem(7, 0, 'water', 1, 3), false, 'an invalid target id is refused')
H.equal(giveItem(7, 9, 'water', 99, 3), false, 'giving more than is held is refused')
H.equal(giveItem(7, 9, 'water', 1, 40), false, 'an empty slot is refused')
H.equal(#removed, 0, 'none of the refused gives removed anything')

metadata[9].isdead = true
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a dead recipient is refused')
metadata[9].isdead = false
metadata[7].ishandcuffed = true
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a handcuffed giver is refused')
metadata[7].ishandcuffed = false
metadata[9].inlaststand = true
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a downed recipient is refused')
metadata[9].inlaststand = false

pedCoords[90].d = 25.0
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a distant recipient is refused')
pedCoords[90].d = 1.0

buckets[9] = 3
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a recipient in another routing bucket is refused')
buckets[9] = 0

canAdd = false
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a recipient who cannot carry it is refused')
canAdd = true
H.equal(#removed, 0, 'still nothing removed by any refused give')

QbInventory.internal.sessionOf = function() return nil end
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'no open session means no give')
H.equal(#removed, 0, 'the sessionless give removed nothing')
QbInventory.internal.sessionOf = realSessionOf

-- A failed hand-off puts the item back in its original slot.
addSucceeds = false
removed, added = {}, {}
H.equal(giveItem(7, 9, 'water', 1, 3), false, 'a give the recipient rejects fails')
H.equal(#removed, 1, 'the item was removed before the hand-off')
H.equal(added[2].src, 7, 'the rollback returns the item to the giver')
H.equal(added[2].slot, 3, 'the rollback restores the original slot')
H.equal(added[2].reason, 'give-rollback', 'the rollback is auditable')
addSucceeds = true

-- Slot omitted: the name may select one of the caller's OWN slots, but it can
-- never assert what that slot contains.
inventories['player:7'].items[3] = { name = 'water', amount = 5, slot = 3, info = { serial = 'AAA' } }
removed, added = {}, {}
H.equal(giveItem(7, 9, 'water', 1, nil), true, 'a give without a slot resolves one by name')
H.equal(removed[1].slot, 3, 'the resolved slot is the one really holding that item')
removed, added = {}, {}
H.equal(giveItem(7, 9, 'diamond', 1, nil), false, 'a name the caller does not hold resolves to nothing')
H.equal(#removed, 0, 'and removes nothing')

H.finish()
