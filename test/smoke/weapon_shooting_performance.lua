-- Exercise the real inventory mutation and replication funnels together.
local H = dofile('test/harness.lua')
local coreRoot = '../qbcore/'
local mocks = dofile(coreRoot .. 'test/mocks.lua')
local mock = mocks.install()
local clock, invoking = 1000, nil
GetGameTimer = function() return clock end
GetInvokingResource = function() return invoking end
RegisterCommand = function() end

for _, file in ipairs({
    'config.lua', 'shared/items.lua', 'shared/jobs.lua', 'shared/gangs.lua',
    'shared/vehicles.lua', 'shared/weapons.lua', 'shared/locations.lua',
    'modules/util/shared.lua', 'modules/registry/shared.lua', 'modules/registry/server.lua',
    'modules/player/shared.lua', 'modules/replication/server.lua', 'modules/persistence/server.lua',
    'modules/player/server.lua', 'modules/money/server.lua',
    'modules/inventory/shared.lua', 'modules/inventory/server.lua',
}) do dofile(coreRoot .. file) end

local coreExports, inventoryExports = {}, {}
for _, module in pairs(Core) do
    for name, fn in pairs(module) do
        if type(fn) == 'function' then coreExports[name] = fn end
    end
end
local function exported(resource, functions)
    return setmetatable({}, { __index = function(_, name)
        return function(_, ...)
            local previous = invoking
            invoking = resource == 'qbcore' and 'qbinventory' or 'qbcore'
            local results = table.pack(assert(functions[name], 'missing export ' .. name)(...))
            invoking = previous
            return table.unpack(results, 1, results.n)
        end
    end })
end
exports = setmetatable({
    qbcore = exported('qbcore', coreExports),
    qbinventory = exported('qbinventory', inventoryExports),
}, { __call = function(_, name, fn) inventoryExports[name] = fn end })
GetCurrentResourceName = function() return 'qbinventory' end
mock.resourceStates.qbinventory = 'started'
local threads = {}
CreateThread = function(fn) threads[#threads + 1] = fn end
for _, file in ipairs({ 'config.lua', 'shared.lua', 'server.lua', 'server/crafting.lua', 'server/weaponcarry.lua' }) do
    dofile(file)
end

local data = CoreInternal.player.freshData('SHOOTING-TEST', 'license:shooting', 1,
    { firstname = 'Test', lastname = 'Player' })
data.money.cash = 0
H.ok(Core.player.login(1, data.citizenid, data))
local inventory, internal = QbInventory, QbInventory.internal
local items = {}
for slot = 1, 20 do items[slot] = internal.buildItem('water_bottle', 1, slot, { batch = slot }) end
items[1] = internal.buildItem('weapon_pistol', 1, 1, assert(inventory.weapons.prepareMetadata('weapon_pistol', {
    ammo = 4, durability = 100, serial = 'SHOOTING-PISTOL',
})))
items[1].integrationData = { owner = 'another-resource' }
items[2] = internal.buildItem('weapon_carbinerifle', 1, 2, { ammo = 0, serial = 'CARRIED-RIFLE' })
items[20] = internal.buildItem('cash', 100, 20, { origin = 'existing-cash' })
H.ok(Core.player.setPath(1, { 'items' }, items))
Config.qbinventory.cash.asItem = true
threads[1]() -- Activate the real physical-cash provider; do not start the session sweep.
H.equal(Core.money.getMoney(1, 'cash'), 100)
H.ok(inventory.weaponCarry.toggle(1, items[1]))
mock.fireEvent('qbinventory:server:weaponToggled', 1, 1)
mock.drainTimeouts()

local player = CoreInternal.player.bySource[1]
local originalItems = player.PlayerData.items
local otherItems = {}
for slot = 2, 20 do otherItems[slot] = player.PlayerData.items[slot] end
local writes, changes, rounds, states = {}, {}, {}, {}
local originalSetPath = coreExports.setPath
coreExports.setPath = function(src, path, value)
    writes[#writes + 1] = { path = Core.util.deepClone(path), value = Core.util.deepClone(value) }
    return originalSetPath(src, path, value)
end
AddEventHandler('qbcore:server:inventoryChanged', function(src)
    if src == 1 then changes[#changes + 1] = Core.player.getPlayerData(1, { 'items', 1, 'info' }) end
end)
AddEventHandler('qbinventory:server:weaponRoundFired', function(_, round) rounds[#rounds + 1] = round end)
AddEventHandler('qbinventory:server:weaponStateChanged', function(_, _, state) states[#states + 1] = state end)
local firstEvent, firstState
local function reset()
    writes, changes, rounds, states = {}, {}, {}, {}
    firstEvent = #mock.clientEvents + 1
    firstState = #mock.stateWrites + 1
end
local function events(name)
    local out = {}
    for index = firstEvent, #mock.clientEvents do
        local event = mock.clientEvents[index]
        if event.name == name then out[#out + 1] = event end
    end
    return out
end
local function assertShot(ammo, durability)
    H.equal(#writes, 2, 'the existing ammo and durability mutations remain separate')
    for _, write in ipairs(writes) do
        H.equal(#write.path, 2, 'each mutation replaces one slot, not all items')
        H.equal(write.path[1], 'items')
        H.equal(write.path[2], 1)
        H.equal(write.value.info.ammo, ammo)
    end
    H.ok(math.abs(writes[1].value.info.durability - durability - 0.1) < 0.000001)
    H.ok(math.abs(writes[2].value.info.durability - durability) < 0.000001)
    H.equal(#changes, 2, 'observers retain both committed changes')
    H.equal(changes[1].ammo, ammo)
    H.ok(math.abs(changes[1].durability - durability - 0.1) < 0.000001)
    H.ok(math.abs(changes[2].durability - durability) < 0.000001)
    H.equal(#rounds, 1)
    H.equal(rounds[1].weaponSerial, 'SHOOTING-PISTOL')
    H.equal(#states, 2, 'the public state-change event retains both payloads')
    H.equal(states[1].ammo, ammo)
    H.ok(math.abs(states[1].durability - durability - 0.1) < 0.000001)
    H.ok(math.abs(states[2].durability - durability) < 0.000001)
    H.ok(player._dirty.inventory, 'weapon metadata remains dirty for persistence')
    local batches = events('qbcore:rep:delta')
    H.equal(#batches, 1)
    H.equal(#batches[1].args[2], 1, 'one delta op carries the changed slot')
    local op = batches[1].args[2][1]
    H.equal(#op.p, 2)
    H.equal(op.p[1], 'items')
    H.equal(op.p[2], 1)
    H.equal(op.v.info.ammo, ammo)
    H.ok(math.abs(op.v.info.durability - durability) < 0.000001)
    H.equal(player.PlayerData.items, originalItems, 'the inventory map is retained')
    for slot = 2, 20 do H.equal(player.PlayerData.items[slot], otherItems[slot], 'other slots retain their records') end
    H.equal(player.PlayerData.items[1].integrationData.owner, 'another-resource')
    H.equal(mocks.stableEncode(player.PlayerData.items[1].metadata),
        mocks.stableEncode(player.PlayerData.items[1].info), 'weapon metadata aliases remain synchronized')
    H.equal(player.PlayerData.items[20].amount, 100, 'physical cash is unchanged')
    H.equal(Core.money.getMoney(1, 'cash'), 100)
    for index = firstState, #mock.stateWrites do
        H.equal(mock.stateWrites[index].key == 'qbinventory:weaponCarry', false,
            'ammo and wear changes do not republish carried props')
    end
end

reset()
player._dirty = {}
local viewCalls = 0
debug.sethook(function()
    if debug.getinfo(2, 'f').func == internal.view then viewCalls = viewCalls + 1 end
end, 'c')
clock = clock + 100
mock.fireEvent('qbinventory:server:weaponFired', 1)
mock.drainTimeouts()
debug.sethook()
assertShot(3, 99.9)
H.equal(viewCalls, 0, 'shooting does not build a view when no inventory is open')
H.equal(#events('qbinventory:client:sessionPatched'), 0)
H.equal(#events('qb-inventory:client:updateInventory'), 0)

reset()
mock.fireEvent('qbinventory:server:weaponFired', 1)
mock.fireEvent('qbinventory:server:weaponFired', 999)
mock.drainTimeouts()
H.equal(#writes, 0, 'cooldown replays and unknown players do not mutate items')
H.equal(#rounds, 0)
H.equal(#events('qbcore:rep:delta'), 0)

H.ok(inventory.api.OpenInventory(1))
mock.drainTimeouts()
local revision = internal.getRevision('player:1')
reset()
clock = clock + 100
mock.fireEvent('qbinventory:server:weaponFired', 1)
mock.drainTimeouts()
assertShot(2, 99.8)
H.equal(internal.getRevision('player:1'), revision + 2, 'both existing commits advance the open session')
local patches = events('qbinventory:client:sessionPatched')
H.equal(#patches, 2)
H.equal(patches[1].args[2].revision, revision + 1)
H.equal(patches[2].args[2].revision, revision + 2)
H.equal(patches[2].args[2].inventory.items[1].info.ammo, 2)
H.ok(math.abs(patches[2].args[2].inventory.items[1].info.durability - 99.8) < 0.000001)
H.equal(#events('qb-inventory:client:updateInventory'), 2, 'existing open-view refresh events remain')
internal.close(1, 'test')

H.ok(inventoryExports.FireWeaponRound(1, 1, 500), 'the public round export remains supported')
H.equal(player.PlayerData.items[1].info.ammo, 1)
H.ok(math.abs(player.PlayerData.items[1].info.durability - 99.8) < 0.000001,
    'public fireRound retains its ammo-only contract, including ignored extra arguments')
mock.drainTimeouts()
reset()
Config.qbinventory.weapons.ballistics.enabled = false
mock.fireEvent('qbinventory:server:weaponAmmoConsumed', 1, 2, 0)
H.equal(#writes, 0, 'the legacy report must match the equipped slot')
mock.fireEvent('qbinventory:server:weaponAmmoConsumed', 1, 1, 0)
mock.drainTimeouts()
H.equal(player.PlayerData.items[1].info.ammo, 0, 'legacy reports can still lower ammo')
H.ok(math.abs(player.PlayerData.items[1].info.durability - 99.7) < 0.000001)
reset()
mock.fireEvent('qbinventory:server:weaponAmmoConsumed', 1, 1, 100)
clock = clock + 100
mock.fireEvent('qbinventory:server:weaponFired', 1)
mock.drainTimeouts()
H.equal(#writes, 0, 'legacy ammo increases and empty native shots cannot commit')
H.equal(#rounds, 0)
H.equal(player.PlayerData.items[20].amount, 100)
H.equal(inventoryExports.FireWeaponRound(999, 1), false, 'unknown players cannot fire a round')

local heavy = Core.util.deepClone(otherItems[3])
heavy.amount = Config.qbinventory.playerMaxWeight
H.ok(Core.player.setPath(1, { 'items', 3 }, heavy))
mock.drainTimeouts()
reset()
local ok, reason = inventory.weapons.setAmmo(1, 1, 5)
H.equal(ok, false, 'weapon metadata cannot bypass the inventory weight limit')
H.equal(reason, 'over weight')
H.equal(#writes, 0)
H.equal(player.PlayerData.items[1].info.ammo, 0)
H.ok(Core.player.setPath(1, { 'items', 3 }, otherItems[3]))
mock.drainTimeouts()
local definitions = {}
for _, registry in ipairs({ 'items', 'weapons' }) do
    definitions[registry] = Core.registry.getShared(registry, 'weapon_pistol')
    if definitions[registry] then H.ok(Core.registry.unregisterShared(registry, 'weapon_pistol')) end
end
reset()
H.equal(inventory.weapons.setAmmo(1, 1, 5), false, 'a removed weapon definition cannot be written')
H.equal(#writes, 0)
for registry, definition in pairs(definitions) do
    H.ok(Core.registry.registerShared(registry, 'weapon_pistol', definition))
end

local weapon = Core.player.getPlayerData(1, { 'items', 1 })
reset()
H.ok(Core.player.setPath(1, { 'items', 1 }, internal.buildItem('water_bottle', 1, 1, {})))
H.equal(inventory.weaponCarry.equippedWeapon(1), nil, 'same-slot replacement clears the equipped weapon')
H.ok(#mock.stateWrites >= firstState, 'same-slot replacement still refreshes carried props')
H.equal(mock.stateWrites[#mock.stateWrites].key, 'qbinventory:weaponCarry')
H.ok(Core.player.setPath(1, { 'items', 1 }, weapon))
H.ok(inventory.weaponCarry.toggle(1, weapon))
mock.fireEvent('qbinventory:server:weaponToggled', 1, 1)
reset()
H.ok(Core.player.setPath(1, { 'items', 1 }, nil))
H.equal(inventory.weaponCarry.equippedWeapon(1), nil, 'same-slot removal clears the equipped weapon')
H.ok(#mock.stateWrites >= firstState, 'same-slot removal still refreshes carried props')
H.equal(mock.stateWrites[#mock.stateWrites].key, 'qbinventory:weaponCarry')
H.finish()
