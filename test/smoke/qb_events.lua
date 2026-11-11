-- Contract coverage for the qb-inventory net-event bridge.
--
-- The security-critical one is SetInventoryData. Upstream's protocol names the
-- source and target inventories in the client payload and carries no session
-- token or revisions, so the bridge must supply those itself and must refuse
-- any inventory the caller's own server-issued session does not already hold.
local H = dofile('test/harness.lua')

local handlers, rejected, transfers, closed, used, opened = {}, {}, {}, {}, {}, {}
local invokingResource
RegisterNetEvent = function(name, fn) handlers[name] = fn end
TriggerClientEvent = function(name, src, reason) rejected[#rejected + 1] = { name = name, src = src, reason = reason } end
GetInvokingResource = function() return invokingResource end

local session = { token = 'tok-1', primary = 'player:7', secondary = 'stash:locker', expires = 999 }
local inventories = {
    ['player:7'] = { key = 'player:7', type = 'player', id = 7 },
    ['player:9'] = { key = 'player:9', type = 'player', id = 9 },
    ['stash:locker'] = { key = 'stash:locker', type = 'stash', id = 'locker' },
    ['stash:secret'] = { key = 'stash:secret', type = 'stash', id = 'secret' },
}

KoraInventory = {
    internal = {
        playerKey = function(src) return 'player:' .. src end,
        resolveInventory = function(ref) return ref, inventories[ref] end,
        getRevision = function() return 42 end,
        sessionOf = function() return session end,
        transfer = function(src, request) transfers[#transfers + 1] = { src = src, request = request }; return true end,
        close = function(src, reason) closed[#closed + 1] = { src = src, reason = reason } end,
    },
    api = {
        useItem = function(src, slot) used[#used + 1] = { src = src, slot = slot } end,
        OpenInventory = function(src, id, opts) opened[#opened + 1] = { src = src, id = id, opts = opts } end,
    },
}

dofile('server/compat/qb_events.lua')

for _, name in ipairs({
    'qb-inventory:server:SetInventoryData', 'qb-inventory:server:closeInventory',
    'qb-inventory:server:useItem', 'qb-inventory:server:openDrop',
    'qb-inventory:server:openVending', 'qb-inventory:server:updateDrop',
    'qb-inventory:server:snowball',
}) do
    H.ok(type(handlers[name]) == 'function', 'registers upstream event ' .. name)
end

-- SetInventoryData
local setData = handlers['qb-inventory:server:SetInventoryData']

source = 7
setData('player', 'stash-name-the-client-made-up', 1, 2, 5)
H.equal(#transfers, 0, 'a target the session does not hold is refused')
H.ok(#rejected > 0, 'the caller is told why')

rejected = {}
setData('player', 'locker', 1, 2, 5)
H.equal(#transfers, 1, 'the session secondary is accepted by its bare identifier')
local request = transfers[1].request
H.equal(request.fromInventory, 'player:7', "'player' resolves to the session primary")
H.equal(request.toInventory, 'stash:locker', 'the identifier resolves to the session secondary key')
H.equal(request.token, 'tok-1', 'the bridge supplies the session token, never the client')
H.equal(request.fromRevision, 42, 'the bridge supplies the current source revision')
H.equal(request.toRevision, 42, 'the bridge supplies the current target revision')
H.equal(request.fromSlot, 1, 'source slot forwarded')
H.equal(request.toSlot, 2, 'target slot forwarded')
H.equal(request.amount, 5, 'amount comes from the upstream fromAmount argument')

invokingResource = 'another-server-resource'
setData('player', 'locker', 1, 2, 5)
H.equal(#transfers, 1, 'a server resource cannot invoke the client-only transfer event')
invokingResource = nil

-- Another player's inventory is only reachable if the session actually holds it.
transfers = {}
setData('otherplayer-9', 'player', 1, 2, 1)
H.equal(#transfers, 0, 'an unrelated player inventory is refused')

session.secondary = 'player:9'
transfers = {}
setData('otherplayer-9', 'player', 1, 2, 1)
H.equal(#transfers, 1, 'a player inventory the session holds is accepted')
H.equal(transfers[1].request.fromInventory, 'player:9', 'otherplayer-<id> maps to that player key')
session.secondary = 'stash:locker'

-- No session at all means no transfer, whatever the payload says.
transfers, rejected = {}, {}
local realSessionOf = KoraInventory.internal.sessionOf
KoraInventory.internal.sessionOf = function() return nil end
setData('player', 'locker', 1, 2, 1)
H.equal(#transfers, 0, 'no open session means no transfer')
KoraInventory.internal.sessionOf = realSessionOf

-- the rest
handlers['qb-inventory:server:closeInventory']()
H.equal(closed[1].src, 7, 'closeInventory closes the calling session')

handlers['qb-inventory:server:useItem']({ slot = 3, name = 'spoofed', weight = 0 })
H.equal(used[1].slot, 3, 'useItem reads only the slot from the client payload')
used = {}
handlers['qb-inventory:server:useItem']({ name = 'no-slot' })
H.equal(#used, 0, 'a payload without a slot is ignored')

handlers['qb-inventory:server:openDrop']('drop-12')
H.equal(opened[1].opts.type, 'drop', 'openDrop routes through the access-checked open')

-- Deliberate no-ops: these upstream events write authority state from the
-- client, which this resource refuses by design.
local ok = pcall(handlers['qb-inventory:server:updateDrop'], { x = 1 })
H.ok(ok, 'updateDrop is an inert no-op rather than a client-writable coord')
ok = pcall(handlers['qb-inventory:server:snowball'], 'add')
H.ok(ok, 'snowball is an inert no-op rather than a client-granted item')

H.finish()
