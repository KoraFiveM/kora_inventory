-- Source-contract coverage for security boundaries that need an FXServer to
-- exercise at runtime. These assertions intentionally inspect the public
-- transport shape instead of pretending a plain Lua process can emulate Cfx.
local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local source = file:read('*a')
    file:close()
    return source
end

local server = read('server.lua')
local persistence = read('server/persistence.lua')
local client = read('client.lua')
local bridge = read('client/ui.lua')
local manifest = read('fxmanifest.lua')

-- Client data is an intent, never an inventory snapshot to replace server
-- state with. In particular, retain the old qb-inventory replacement event as
-- an explicit regression guard.
H.ok(not server:find('SetInventoryData', 1, true), 'server exposes no full-inventory replacement endpoint')
H.ok(not client:find('SetInventoryData', 1, true), 'client cannot submit full-inventory replacement')
H.ok(server:find("RegisterNetEvent('qbinventory:server:transfer'", 1, true), 'transfer transport is explicitly registered')
H.ok(server:find("RegisterNetEvent('qbinventory:server:intent'", 1, true), 'restricted intent transport is explicitly registered')
H.ok(server:find("if type(request) ~= 'table'", 1, true), 'server rejects malformed transfer requests')

-- Shops are read-only to generic transfers. Purchases have their own session,
-- revision, stock and payment path, preventing free shop withdrawals.
H.ok(server:find("if from.type == 'shop' then return false, 'shop items must be purchased' end", 1, true), 'shop cannot be source of generic transfer')
H.ok(server:find("if to.type == 'shop' then return false, 'shop inventory is read only' end", 1, true), 'shop cannot be target of generic transfer')
H.ok(server:find("if request.action == 'buy' then return intentBuy(src, request) end", 1, true), 'buy uses dedicated server intent')
H.ok(server:find("if shop.type ~= 'shop' then return false, 'secondary inventory is not a shop' end", 1, true), 'buy verifies target is a shop')
H.ok(server:find('exports.qbcore:removeMoney', 1, true), 'purchase takes server-side payment')
H.ok(server:find("'qbinventory-refund'", 1, true), 'failed purchase is refunded server-side')
H.ok(server:find('local function normaliseShopStock(rows, slots)', 1, true), 'configured shop stock is normalised server-side')
H.ok(server:find('local item, err = buildItem(row.name, amount, slot, row.info or row.metadata)', 1, true), 'shop stock uses canonical shared item definitions')
H.ok(server:find("if not amount or not price or price < 0 then return nil, 'invalid shop amount or price' end", 1, true), 'shop stock rejects invalid prices and counts')

-- A lease grants access to exactly two server-resolved inventories. Both
-- revisions are checked before and again inside the lock, so stale viewers do
-- not overwrite newer slots.
H.ok(server:find("if not session or token ~= session.token then return nil, 'invalid session' end", 1, true), 'session token is verified')
H.ok(server:find("if now() > session.expires then close(src, 'expired')", 1, true), 'expired session is closed')
H.ok(server:find("return nil, 'inventory not in session'", 1, true), 'session limits inventory keys')
H.ok(server:find("return nil, 'stale source inventory'", 1, true), 'source revision is checked')
H.ok(server:find("return nil, 'stale target inventory'", 1, true), 'target revision is checked')
H.ok(server:find('return lock({ fromKey, toKey }, function()', 1, true), 'transfer uses deterministic lock wrapper')
H.ok(server:find('local session, currentFrom, currentTo = validSession', 1, true), 'transfer revalidates inside lock')
H.ok(server:find("if not sameBucket(src, inv.source)", 1, true), 'player inspection checks routing bucket')
H.ok(server:find("'too far away'", 1, true), 'access path rejects distance failures')

-- qbcore remains the sole player data owner. Secondary persistence has a
-- separate schema and operational, non-destructive migration path.
H.ok(server:find('exports.qbcore:getPlayerData', 1, true), 'player state is read from qbcore')
H.ok(server:find('exports.qbcore:setPath', 1, true), 'player mutation uses qbcore funnel')
H.ok(not server:find('INSERT INTO `players`', 1, true) and not server:find('UPDATE `players`', 1, true), 'authority does not write players table')
H.ok(persistence:find("inv.type == 'player'", 1, true), 'persistence excludes player inventories')
H.ok(persistence:find("RegisterCommand('qbinventory-migrate'", 1, true), 'migration is an explicit operator command')
H.ok(persistence:find('INFORMATION_SCHEMA', 1, true) and persistence:find("'unsupported legacy table'", 1, true), 'legacy import is defensive')
H.ok(persistence:find('qbinventory_migration_rows', 1, true), 'migration tracks idempotency rows')

-- NUI is deliberately one-way presentation plumbing. The bridge is the only
-- UI owner, makes a local hand-off, and client.lua still decides the limited
-- server transport. Server authority has no NUI APIs at all.
H.ok(not server:find('SendNUIMessage', 1, true) and not server:find('RegisterNUICallback', 1, true), 'server has no NUI authority')
H.ok(not client:find('SendNUIMessage', 1, true) and not client:find('RegisterNUICallback', 1, true), 'client transport has no NUI bridge')
H.ok(bridge:find('RegisterNUICallback', 1, true) and bridge:find('SendNUIMessage', 1, true), 'NUI bridge owns browser transport')
H.ok(not bridge:find('TriggerServerEvent', 1, true), 'NUI bridge cannot mutate server directly')
H.ok(bridge:find("TriggerEvent('qbinventory:client:submitIntent'", 1, true), 'NUI bridge hands intents to headless client transport')
H.ok(client:find("if intent.token and intent.token ~= session.token then return false, 'stale session' end", 1, true), 'client rejects stale NUI token')
H.ok(client:find("TriggerServerEvent('qbinventory:server:intent'", 1, true), 'client forwards only approved server intent actions')
H.ok(manifest:find("'client/ui.lua'", 1, true) and manifest:find("ui_page 'web/build/index.html'", 1, true), 'bundled UI is isolated to its client bridge')

H.finish()
