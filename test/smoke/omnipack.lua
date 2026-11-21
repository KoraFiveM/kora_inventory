-- Admin omnipack: ACE on open and on EVERY take, unknown items refused,
-- quantity bounds, fresh weapon serials, audit entry written, never persisted.
-- Runs the real server.lua + server/omnipack.lua without an FXServer.
local logSpy = dofile('test/logging_spy.lua')
local H = dofile('test/harness.lua')
Config = {}
dofile('config.lua')
dofile('shared.lua')

local events, registered, callbacks = {}, {}, {}
local invokingResource
local aceCalls, aceAllowed = {}, { [7] = true }
local data = { [7] = { citizenid = 'ADMIN7', items = {} }, [8] = { citizenid = 'PLAYER8', items = {} } }
local definitions = {
    bread = { name = 'bread', label = 'Bread', weight = 1 },
    wood = { name = 'wood', label = 'Wood', weight = 1 },
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', type = 'weapon', unique = true, weight = 1, ammotype = 'AMMO_PISTOL' },
}
local function noop() end
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return invokingResource end
GetGameTimer = function() return 1000 end
GetPlayerPed = function(source) return source end
GetEntityCoords = function() return { x = 1, y = 2, z = 3 } end
GetPlayerRoutingBucket = function() return 0 end
IsPlayerAceAllowed = function(player, ace)
    aceCalls[#aceCalls + 1] = { player = player, ace = ace }
    return aceAllowed[tonumber(player)] == true and ace == 'kora_inventory.omnipack'
end
CreateThread, Wait, RegisterCommand, TriggerClientEvent = noop, noop, noop, noop
AddEventHandler = function(name, callback) events[name] = callback end
RegisterNetEvent = AddEventHandler
TriggerEvent = function(name, ...) if events[name] then events[name](...) end end
Kora = {
    util = { deepClone = function(value)
        local seen = {}
        local function clone(v)
            if type(v) ~= 'table' then return v end
            if seen[v] then return seen[v] end
            local copy = {}
            seen[v] = copy
            for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
            return copy
        end
        return clone(value)
    end, clamp = function(value, min, max) return math.max(min, math.min(max, value)) end },
    resources = { serverRegistry = function() return { track = noop, untrack = noop } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    distance = { player = function() return true end },
    notify = { send = noop },
    sql = {},
}
exports = setmetatable({}, {
    __call = function(_, name, callback) registered[name] = callback end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    local source, field, value = ...
                    if name == 'allShared' then
                        if source == 'items' then
                            return { definitions.wood, definitions.bread }
                        elseif source == 'weapons' then
                            return { definitions.weapon_pistol }
                        end
                        return {}
                    end
                    if name == 'registerPhysicalCash' then return true end
                    if name == 'getShared' then return definitions[field] end
                    if name == 'getPlayerData' then
                        local player = data[source]
                        if not player or not field then return player end
                        if field[1] == 'items' and field[2] then return player.items[field[2]] end
                        return player[field[1]]
                    end
                    if name == 'setPath' then
                        if field[2] then data[source].items[field[2]] = value else data[source].items = value end
                        TriggerEvent('kora_core:server:inventoryChanged', source)
                        return true
                    end
                end
                return registered[name] and registered[name](...)
            end
        end })
    end,
})

dofile('server/audit_log.lua')
dofile('server.lua')
dofile('server/crafting.lua') -- weapon metadata (fresh serials)
dofile('server/omnipack.lua')
dofile('server/admin_tools.lua')

local inventory = KoraInventory
local internal, omnipack, audit = inventory.internal, inventory.omnipack, inventory.auditLog
local clock = 1000000
audit.clock = function() return clock end
audit.sink = function(rows) return #rows end

local function intent(src, request) return callbacks['kora_inventory:server:intent'](src, request) end
local function openFor(src)
    local ok, result = omnipack.open(src)
    return ok, result
end
local function buyRequest(src, slot, amount, extra)
    local session = internal.sessionOf(src)
    local request = {
        action = 'buy',
        token = session.token,
        primaryRevision = internal.getRevision(session.primary),
        secondaryRevision = internal.getRevision(session.secondary),
        payload = { inventory = session.secondary, slot = slot, amount = amount },
    }
    for key, value in pairs(extra or {}) do request.payload[key] = value end
    return request
end
local function slotOf(name)
    for slot, item in pairs(internal.getInventory('shop:omnipack').items) do
        if item.name == name then return slot end
    end
end
local function countOf(src, name)
    local total = 0
    for _, item in pairs(data[src].items) do if item.name == name then total = total + item.amount end end
    return total
end
local function lastAudit()
    local rows = audit.query({ range = '1h' }).rows
    return rows[1], #rows
end

-- ---------------------------------------------------------------------------
-- Config defaults and wiring.
-- ---------------------------------------------------------------------------
local cfg = Config.kora_inventory.omnipack
H.equal(cfg.enabled, true, 'omnipack defaults on')
H.equal(cfg.command, 'omnipack', 'default command name')
H.equal(cfg.ace, 'kora_inventory.omnipack', 'default ACE name')
H.ok(registered.openOmnipack, 'the openOmnipack export exists')

-- ---------------------------------------------------------------------------
-- ACE is checked on open.
-- ---------------------------------------------------------------------------
local ok, why = openFor(8)
H.equal(ok, false, 'a player without the ACE cannot open the omnipack')
H.equal(why, 'not authorised', 'and is told they are not authorised')
H.equal(internal.sessionOf(8), nil, 'no session is created for them')
H.equal(aceCalls[#aceCalls].ace, 'kora_inventory.omnipack', 'the configured ACE is what is checked')
H.equal(aceCalls[#aceCalls].player, '8', 'the check is made for the requesting player')
ok = registered.openOmnipack(8)
H.equal(ok, false, 'the export refuses a player without the ACE too')

Config.kora_inventory.omnipack.enabled = false
ok, why = openFor(7)
H.equal(ok, false, 'a disabled omnipack refuses even an admin')
H.equal(why, 'omnipack is disabled', 'with a clear reason')
Config.kora_inventory.omnipack.enabled = true

ok = openFor(7)
H.equal(ok, true, 'an admin with the ACE opens the omnipack')
local session = internal.sessionOf(7)
H.equal(session.secondary, 'shop:omnipack', 'the session secondary is the omnipack shop')
local shop = internal.getInventory('shop:omnipack')
H.equal(shop.omnipack, true, 'the inventory carries the omnipack flag')
H.equal(shop.type, 'shop', 'it is an ordinary shop inventory')

-- Catalogue: every registered item AND weapon, sorted, free, infinite.
local names = {}
for slot = 1, shop.slots do names[slot] = shop.items[slot] and shop.items[slot].name end
H.equal(table.concat(names, ','), 'bread,weapon_pistol,wood', 'every item and weapon is listed, sorted')
H.equal(shop.items[1].price, 0, 'prices are 0')
H.equal(shop.items[1].amount, cfg.maxAmount, 'the displayed stock is the largest take, so the amount picker is bounded')
local view = internal.view('shop:omnipack')
H.equal(view.omnipack, true, 'the view tells the UI this is the omnipack')
H.equal(view.stock, nil, 'the list is not sent twice')
H.equal(view.slots, 3, 'the view has one slot per registered item')
local persistenceSource = assert(io.open('server/persistence.lua', 'r')):read('*a')
H.ok(persistenceSource:find("inv.omnipack == true", 1, true), 'the omnipack is never persisted')

-- ---------------------------------------------------------------------------
-- A take: normal add path, audit entry, infinite stock, no shop re-send.
-- ---------------------------------------------------------------------------
local shopRevision = internal.getRevision('shop:omnipack')
local breadSlot = slotOf('bread')
local okTake, err = intent(7, buyRequest(7, breadSlot, 3))
H.equal(okTake, true, 'an admin can take items: ' .. tostring(err))
H.equal(countOf(7, 'bread'), 3, 'the items arrive in the admin inventory')
H.equal(internal.getInventory('shop:omnipack').items[breadSlot].amount, cfg.maxAmount, 'stock is never decremented')
H.equal(internal.getRevision('shop:omnipack'), shopRevision, 'the omnipack list is not re-sent or re-versioned after a take')
local row, count = lastAudit()
H.equal(count, 1, 'one audit entry for the take')
H.equal(row.action, 'omnipack', "it is recorded with the action 'omnipack'")
H.equal(row.item, 'bread', 'with the item')
H.equal(row.amount, 3, 'the amount')
H.equal(row.citizenid, 'ADMIN7', 'and the admin')
H.equal(row.source, 7, 'with their server id')
H.equal(row.inventory, 'player:7', 'the destination inventory')

-- Weapons get a fresh serial each time.
local pistolSlot = slotOf('weapon_pistol')
H.ok(intent(7, buyRequest(7, pistolSlot, 1)), 'a weapon can be taken')
H.ok(intent(7, buyRequest(7, pistolSlot, 1)), 'a second weapon can be taken')
local serials, pistols = {}, 0
for _, item in pairs(data[7].items) do
    if item.name == 'weapon_pistol' then
        pistols = pistols + 1
        local serial = (item.info or {}).serial
        H.ok(type(serial) == 'string' and serial ~= '', 'each weapon gets a serial')
        H.equal(serials[serial], nil, 'serials are unique')
        serials[serial] = true
    end
end
H.equal(pistols, 2, 'two separate weapon items')
H.equal(select(2, lastAudit()), 3, 'every take is audited')

-- The browser only names a slot: a smuggled item name is ignored.
local before = countOf(7, 'wood')
H.ok(intent(7, buyRequest(7, breadSlot, 1, { name = 'weapon_pistol', item = 'wood', price = 0 })), 'extra payload fields do not break the take')
H.equal(countOf(7, 'wood'), before, 'a client-supplied item name is never used')
H.equal(countOf(7, 'bread'), 4, 'the slot decides the item')

-- ---------------------------------------------------------------------------
-- Quantity bounds and unknown items.
-- ---------------------------------------------------------------------------
local function refused(request, label)
    local before = countOf(7, 'bread') + countOf(7, 'wood')
    local took, reason = intent(7, request)
    H.equal(took, false, label)
    H.equal(countOf(7, 'bread') + countOf(7, 'wood'), before, label .. ' (nothing added)')
    return reason
end
H.equal(refused(buyRequest(7, breadSlot, 0), 'amount 0 is refused'), 'invalid amount', 'zero is an invalid amount')
refused(buyRequest(7, breadSlot, -5), 'a negative amount is refused')
refused(buyRequest(7, breadSlot, 'lots'), 'a non-numeric amount is refused')
refused(buyRequest(7, breadSlot, 1 / 0), 'an infinite amount is refused')
H.equal(refused(buyRequest(7, breadSlot, cfg.maxAmount + 1), 'above maxAmount is refused'), 'invalid amount', 'the limit is maxAmount')
H.ok(intent(7, buyRequest(7, breadSlot, cfg.maxAmount)), 'maxAmount itself is the largest take')
H.equal(refused(buyRequest(7, 99, 1), 'an unknown slot is refused'), 'unknown item', 'an unknown slot names no item')
refused(buyRequest(7, 0, 1), 'slot 0 is refused')
refused(buyRequest(7, -1, 1), 'a negative slot is refused')
Config.kora_inventory.omnipack.maxAmount = 5
H.equal(refused(buyRequest(7, breadSlot, 6), 'maxAmount follows the config at call time'), 'invalid amount', 'a lowered limit applies at once')
H.ok(intent(7, buyRequest(7, breadSlot, 5)), 'and a take at the new limit works')
Config.kora_inventory.omnipack.maxAmount = 100

-- An item that left the registry after the list was built is refused.
local saved = definitions.wood
definitions.wood = nil
H.equal(refused(buyRequest(7, slotOf('wood'), 1), 'an item no longer registered is refused'), 'unknown item', 'the registry is the authority at use time')
definitions.wood = saved

-- Stale revisions are refused like any other intent.
local stale = buyRequest(7, breadSlot, 1)
stale.primaryRevision = stale.primaryRevision - 1
H.equal(intent(7, stale), false, 'a stale primary revision is refused')

-- Another player's session cannot be used.
H.equal(intent(8, buyRequest(7, breadSlot, 1)), false, 'a player without a session cannot take')

-- ---------------------------------------------------------------------------
-- ACE is re-checked on EVERY take, not just on open.
-- ---------------------------------------------------------------------------
local calls = #aceCalls
H.ok(intent(7, buyRequest(7, breadSlot, 1)), 'the take works while permitted')
H.ok(#aceCalls > calls, 'a take consults the ACE')
local breadBefore = countOf(7, 'bread')
local auditsBefore = select(2, lastAudit())
local requestAfterRevoke = buyRequest(7, breadSlot, 1)
aceAllowed[7] = false
local took, reason = intent(7, requestAfterRevoke)
H.equal(took, false, 'a take after the ACE was revoked is refused')
H.equal(reason, 'not authorised', 'with the authorisation reason')
H.equal(countOf(7, 'bread'), breadBefore, 'nothing is added')
H.equal(internal.sessionOf(7), nil, 'the session is closed when the permission disappears')
H.equal(select(2, lastAudit()), auditsBefore, 'a refused take writes no audit entry')

-- Re-granted admins must open it again; a stale token is refused.
aceAllowed[7] = true
H.equal(intent(7, requestAfterRevoke), false, 'the old session token is dead after the revocation')
H.ok(openFor(7), 'it can be opened again once the ACE is back')

-- Disabling the feature stops takes immediately.
Config.kora_inventory.omnipack.enabled = false
H.equal(intent(7, buyRequest(7, breadSlot, 1)), false, 'disabling the omnipack refuses the next take')
Config.kora_inventory.omnipack.enabled = true
H.ok(openFor(7), 'and enabling it again allows opening')

-- ACE name is configurable and read at call time.
Config.kora_inventory.omnipack.ace = 'custom.ace'
H.equal(intent(7, buyRequest(7, breadSlot, 1)), false, 'a changed ACE name applies immediately (admin lacks the new one)')
Config.kora_inventory.omnipack.ace = 'kora_inventory.omnipack'

-- The access policy itself is the ACE: even the generic session validator
-- (used by every other intent) denies a player who lost it.
H.ok(openFor(7), 'reopen for the access check')
local inv = internal.getInventory('shop:omnipack')
H.equal(internal.canAccess(7, inv), true, 'canAccess allows the admin')
aceAllowed[7] = false
H.equal(internal.canAccess(7, inv), false, 'canAccess denies them once the ACE is gone')
H.equal(internal.canAccess(8, inv), false, 'and never allows another player')
aceAllowed[7] = true

-- The generic purchase export cannot be used to take from the omnipack.
local bought, boughtErr = registered.buyItem(7, 'omnipack', slotOf('bread'), 1)
H.equal(bought, false, 'BuyItem cannot reach the omnipack')
H.equal(boughtErr, 'shop not found', 'it behaves as if the shop does not exist')

-- The omnipack never takes cash as an item (no ledger-less money).
local source = assert(io.open('server.lua', 'r')):read('*a')
H.ok(source:find("cash cannot be taken from the omnipack", 1, true), 'physical cash is refused in the omnipack')
H.ok(source:find("omnipack.allowed(src)", 1, true), 'every take re-checks the ACE')
H.ok(source:find("function ext.omnipackTake", 1, true), 'the take has its own validated path')

H.finish()
