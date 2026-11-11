-- Exercise actual Core, inventory and jobcreator source without FiveM/SQL.
-- Fresh-coroutine references model CitizenFX's export/function-ref scheduling;
-- this is an offline transport check, not a live FXServer integration test.
local inventoryRoot = debug.getinfo(1, 'S').source:sub(2):match('^(.-)test/smoke/craft_capacity.lua$')
local root = inventoryRoot .. '../'
local H = dofile(inventoryRoot .. 'test/harness.lua')
local M = dofile(root .. 'kora_core/test/mocks.lua')
local mock = M.install()
local function core(path) return dofile(root .. 'kora_core/' .. path) end
core('config.lua')
local coreConfig = Config
coreConfig.money.default.cash = 0
for _, path in ipairs({
    'shared/items.lua', 'shared/jobs.lua', 'shared/gangs.lua', 'shared/vehicles.lua',
    'shared/weapons.lua', 'shared/locations.lua', 'modules/util/shared.lua',
    'modules/registry/shared.lua', 'modules/registry/server.lua', 'modules/player/shared.lua',
    'modules/replication/server.lua', 'modules/persistence/server.lua', 'modules/player/server.lua',
    'modules/money/server.lua', 'modules/inventory/shared.lua', 'modules/inventory/server.lua',
}) do core(path) end

local invoking, callbacks, threads, taxThreads = nil, {}, {}, {}
local logs, notifications, xp, government = {}, {}, 0, 0
local freshReferences = os.getenv('KORA_CRAFT_TRANSPORT') ~= 'direct'
local functions = { kora_core = {}, kora_inventory = {} }
for _, group in ipairs({ 'inventory', 'registry', 'player', 'money' }) do
    for name, fn in pairs(Core[group]) do
        if type(fn) == 'function' then functions.kora_core[name] = fn end
    end
end
GetInvokingResource = function() return invoking end
local function invoke(caller, fn, ...)
    local prior, result = invoking
    invoking = caller
    if freshReferences then
        local thread = coroutine.create(fn)
        result = table.pack(coroutine.resume(thread, ...))
        assert(coroutine.status(thread) == 'dead', 'the fixture does not drain yielding references')
    else
        result = table.pack(pcall(fn, ...))
    end
    invoking = prior
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end
local function exportRealm(resource)
    return setmetatable({}, {
        __call = function(_, name, fn) functions[resource][name] = fn end,
        __index = function(_, target)
            return setmetatable({}, { __index = function(_, name)
                local fn = functions[target] and functions[target][name]
                if not fn then return nil end
                return function(_, ...)
                    local args = table.pack(...)
                    for index = 1, args.n do
                        if type(args[index]) == 'function' then
                            local reference = args[index]
                            args[index] = setmetatable({}, { __call = function(_, ...)
                                return invoke(resource, reference, ...)
                            end })
                        end
                    end
                    return invoke(resource, fn, table.unpack(args, 1, args.n))
                end
            end })
        end,
    })
end
exports = exportRealm('kora_core')
core('modules/inventory/gateway.lua')
for name, fn in pairs(Core.inventory) do functions.kora_core[name] = fn end
mock.resourceStates.kora_inventory = 'started'

local inv = {}
for name, value in pairs(_G) do inv[name] = value end
inv.Config, inv.KoraInventory = {}, nil
inv.exports = exportRealm('kora_inventory')
inv.GetCurrentResourceName = function() return 'kora_inventory' end
inv.CreateThread = function(fn) threads[#threads + 1] = fn end
inv.Kora = { resources = Kora.resources, sql = {}, distance = { player = function() return true end },
    callback = { register = function(name, fn) callbacks[name] = fn end } }
local function inventory(path) return assert(loadfile(inventoryRoot .. path, 't', inv))() end
inventory('config.lua'); inventory('shared.lua'); inventory('server.lua')
assert(loadfile(os.getenv('KORA_INVENTORY_CRAFT_SOURCE') or inventoryRoot .. 'server/crafting.lua', 't', inv))()
local api, internal = inv.KoraInventory.api, inv.KoraInventory.internal
for name, definition in pairs({
    ballast = { weight = 114000 }, ingredient = { weight = 1000 },
    output_a = { weight = 4000 }, output_b = { weight = 4000 },
    wood = { weight = 1 }, board = { weight = 1 }, blocker = { weight = 1, unique = true },
    voucher = { weight = 1 }, cash = { weight = 0 },
}) do
    definition.name = name
    H.ok(Core.registry.registerShared('items', name, definition))
end
H.ok(Core.registry.registerShared('weapons', 'weapon_capacity', {
    name = 'weapon_capacity', type = 'weapon', unique = true, weight = 1, ammotype = 'AMMO_PISTOL',
}))
H.ok(Core.player.login(7, 'CID7', CoreInternal.player.freshData('CID7', 'license:test', 1, {})))

local business = { id = 'test', job = 'unemployed' }
local module = { moduleType = 'Crafting', public = true, recipes = { 'custom recipe:/with spaces' } }
local job = {}
for name, value in pairs(_G) do job[name] = value end
job.Config = { notifyTitle = 'Crafting', recipes = {}, skills = { enabled = true,
    getLevel = function() return 100 end, addXp = function(_, _, amount) xp = xp + amount end } }
job.KoraJobCreator = {
    state = { get = function(id) return id == business.id and business or nil end,
        module = function() return module end, worksFor = function() return true end },
    logs = { record = function(_, entry) logs[#logs + 1] = entry end },
}
job.exports, job.Kora = exportRealm('kora_jobcreator'), inv.Kora
job.Kora.notify = { send = function(_, payload) notifications[#notifications + 1] = payload end }
assert(loadfile(os.getenv('KORA_JOB_CRAFT_SOURCE') or root .. 'kora_jobcreator/server/crafting.lua', 't', job))()
local crafting = job.KoraJobCreator.crafting
local function item(name, amount, slot, info) return assert(internal.buildItem(name, amount, slot, info or {})) end
local function reset(items, slots)
    inv.Config.kora_inventory.playerSlots = slots or 41
    H.ok(Core.player.setPath(7, { 'items' }, items or {}))
    logs, notifications, xp = {}, {}, 0
end
local function count(name) return Core.inventory.getItemCount(7, name) end
local function snapshot() return M.stableEncode(Core.player.getPlayerData(7, { 'items' })) end
local function rewards(ingredients, give)
    return { ingredients = ingredients, give = give, xpGained = { { skill = 'crafting', xp = 5 } } }
end
local function denied(recipe, message)
    local before, revision, pending = snapshot(), internal.getRevision('player:7'), #taxThreads
    local ok, err = invoke('kora_jobcreator', crafting.craft, 7, recipe, business)
    H.equal(ok, false, message)
    H.ok(type(err) == 'string' and #err > 0, 'denial has a reason')
    H.equal(snapshot(), before, 'capacity denial leaves exact items and metadata unchanged')
    H.equal(internal.getRevision('player:7'), revision, 'denial does not bump inventory revision')
    H.equal(xp, 0, 'denial grants no XP')
    H.equal(#logs, 0, 'denial emits no craft log')
    H.equal(#taxThreads, pending, 'denial dispatches no monetary deposit')
end
local paired = rewards({ { item = 'ingredient' } }, { { item = 'output_a' }, { item = 'output_b' } })
reset({ [1] = item('ballast', 1, 1), [2] = item('ingredient', 1, 2, { batch = 'original' }) })
H.ok(Core.inventory.canCarry(7, 'output_a', 1) and Core.inventory.canCarry(7, 'output_b', 1))
denied(paired, 'two individually valid outputs exceed combined weight')
denied(rewards(paired.ingredients, { { item = 'output_a' }, { item = 'output_a' } }), 'duplicate outputs also aggregate weight')

reset({ [1] = item('blocker', 1, 1), [2] = item('blocker', 1, 2), [3] = item('ingredient', 2, 3) }, 4)
denied(rewards({ { item = 'ingredient' } }, {
    { item = 'board', info = { batch = 'A' } }, { item = 'board', info = { batch = 'B' } },
}), 'different output metadata requires two slots')
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({ { item = 'ingredient' } }, {
    { item = 'board' }, { item = 'board' },
}), business), 'identical outputs fit one stack')
H.equal(count('board'), 2)
H.equal(count('ingredient'), 1)

reset({ [1] = item('board', 1, 1, { batch = 'existing' }), [2] = item('blocker', 1, 2) }, 2)
denied(rewards({}, { { item = 'board', info = { batch = 'existing' } } }),
    'retain the original default-info canCarry rejection even when the metadata plan could stack')

reset({ [1] = item('ballast', 1, 1), [2] = item('ingredient', 1, 2) })
denied(rewards({ { item = 'ingredient' } }, {
    { item = 'board', info = { weight = 4000 } }, { item = 'board', info = { weight = 4000 } },
}), 'output metadata weight participates in combined capacity')
denied(rewards({ { item = 'ingredient' } }, {
    { item = 'weapon_capacity', info = { weight = 4000, ammo = 3, custom = 'retain' } },
    { item = 'weapon_capacity', info = { weight = 4000, ammo = 3, custom = 'retain' } },
}), 'unique weapon metadata weight must not disappear from the capacity plan')

reset({ [1] = item('wood', 1, 1) })
denied(rewards({ { item = 'wood' }, { item = 'wood' } }, { { item = 'board' } }), 'duplicate ingredient requirement is checked together')
local custom = rewards({ { item = 'WOOD', count = 1.9, info = { ignored = true } } }, {
    { name = 'BOARD', count = 2.9, metadata = { custom = 'output' } },
})
custom.completeLabel = 'Custom success'
job.Config.recipes['custom recipe:/with spaces'] = custom
local ok, message = invoke('kora_jobcreator', callbacks['kora_jobcreator:server:craft'], 7, business.id, 1, 'custom recipe:/with spaces')
H.equal(ok, true, message)
H.equal(message, 'Custom success')
H.equal(count('wood'), 0, 'ingredient metadata remains a name-only check')
H.equal(count('board'), 2, 'existing count/floor normalization remains')
H.equal(api.getItemByName(7, 'board').info.custom, 'output')
H.equal(xp, 5); H.equal(#logs, 1)

reset()
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards(nil, { { item = 'board' } }), business), 'missing ingredients means a legitimate free recipe')
H.equal(count('board'), 1); H.equal(xp, 5); H.equal(#logs, 1)
reset()
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({}, {
    { item = 'weapon_capacity', info = { weight = 4000, serial = 'CUSTOM', ammo = 3, custom = 'retained' } },
}), business), 'successful weapon grant keeps the existing addItem metadata behavior')
local weapon = api.getItemByName(7, 'weapon_capacity')
H.equal(weapon.info.weight, 4000); H.equal(weapon.info.serial, 'CUSTOM')
H.equal(weapon.info.ammo, 3); H.equal(weapon.info.custom, 'retained')

-- The new query's permissive empty-input path and planner-only metadata option
-- must not change either existing registered-recipe contract.
reset({ [1] = item('wood', 1, 1) })
local registered = inv.KoraInventory.crafting
local emptyRegistered, emptyReason = registered.register('empty_inputs', {
    ingredients = {}, output = { name = 'board' },
})
H.equal(emptyRegistered, false); H.equal(emptyReason, 'recipe ingredients are required')
local beforeQuery = snapshot()
H.ok(invoke('kora_jobcreator', functions.kora_inventory.CanCraftItems, 7, {}, { { item = 'board' } }),
    'the new trusted capacity query accepts empty inputs')
H.equal(snapshot(), beforeQuery, 'the query never applies its detached plan')
H.ok(registered.register('registered_weapon', { ingredients = { wood = 1 }, output = {
    name = 'weapon_capacity', metadata = { weight = 4000, serial = 'STATIC', ammo = 3, custom = 'unchanged' },
} }))
H.ok(invoke('kora_jobcreator', registered.craft, 7, 'registered_weapon'))
local staticWeapon = api.getItemByName(7, 'weapon_capacity')
H.equal(staticWeapon.info.weight, nil, 'registered weapon metadata retains its existing default treatment')
H.equal(staticWeapon.info.ammo, 0); H.equal(staticWeapon.info.custom, nil)
H.ok(staticWeapon.info.serial ~= 'STATIC')

reset()
inv.Config.kora_inventory.cash = false
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({}, { { item = 'cash', amount = 5, info = { custom = true } } }), business), 'invalid/off cash policy does not crash the capacity query')
H.equal(api.getItemByName(7, 'cash').info.custom, true, 'cash-off remains an ordinary item grant')
reset()
inv.Config.kora_inventory.cash = { asItem = true, item = 'CASH', account = 'CASH' }
invoke('kora_inventory', threads[1]) -- Only real cash bootstrap; never drain permanent workers.
H.ok(Core.money.isPhysicalCash('cash'))
H.ok(Core.money.addMoney(7, 'cash', 100, 'seed', true))
H.ok(Core.inventory.addItem(7, 'wood', 1))
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({ { item = 'wood' } }, { { item = 'board' } }), business),
    'physical cash mode keeps ordinary non-cash recipes working')
H.equal(Core.money.getMoney(7, 'cash'), 100)
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({ { item = 'cash', amount = 20, info = { ignored = true } } }, {
    { item = 'board' }, { item = 'cash', amount = 5, info = { weight = 999999 } },
}), business), 'physical cash keeps name-only consumption and ignores grant metadata')
H.equal(Core.money.getMoney(7, 'cash'), 85)
H.equal(Player(7).state['kora_core:money:cash'], 85)

-- Execute only monetary deposit workers against a fake bank; no SQL service.
CreateThread = function(fn) taxThreads[#taxThreads + 1] = fn end
functions['qb-banking'] = {
    GetAccount = function() return { account_balance = government } end,
    CreateJobAccount = function() return 1 end,
    AddMoney = function(_, amount) government = government + amount; return 1 end,
}
mock.resourceStates['qb-banking'] = 'started'
coreConfig.money.tax.enabled, coreConfig.money.tax.rate = true, 0.05
reset()
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({}, { { item = 'cash', amount = 100 } }), business))
H.equal(Core.money.getMoney(7, 'cash'), 95, 'gross cash grant is still taxed by Core')
for _, fn in ipairs(taxThreads) do invoke('kora_core', fn) end
taxThreads = {}
H.equal(government, 5)
H.equal(Player(7).state['kora_core:money:cash'], 95)

reset()
H.ok(Core.registry.registerShared('items', 'cash', { name = 'cash', weight = 1 }))
H.ok(Core.money.addMoney(7, 'cash', 110000, 'seed', true))
local weightedCash = rewards({}, { { item = 'cash', amount = 5200 }, { item = 'cash', amount = 5200 } })
H.ok(invoke('kora_jobcreator', crafting.craft, 7, weightedCash, business), 'net cash rewards fit where their gross total would not')
H.equal(Core.money.getMoney(7, 'cash'), 119880)
for _, fn in ipairs(taxThreads) do invoke('kora_core', fn) end
taxThreads = {}
reset()
H.ok(Core.money.addMoney(7, 'cash', 110000, 'seed', true))
mock.resourceStates['qb-banking'] = 'stopped'
H.equal(Core.money.getTransactionTax(5200, 'cash', 'add'), 0)
H.equal(Core.money.calculateTax(5200, 'cash', 'add'), 260, 'configured calculator retains its original semantics')
denied(weightedCash, 'bank outage means full cash rewards exceed combined weight')
reset()
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({}, { { item = 'cash', amount = 100 } }), business))
H.equal(Core.money.getMoney(7, 'cash'), 100, 'provider unavailable remains untaxed')
mock.resourceStates['qb-banking'] = 'started'
coreConfig.money.tax.rate = 1
reset()
H.ok(invoke('kora_jobcreator', crafting.craft, 7, rewards({}, { { item = 'cash', amount = 100 } }), business), 'fully taxed cash has no positive item insertion to plan')
H.equal(Core.money.getMoney(7, 'cash'), 0)
for _, fn in ipairs(taxThreads) do invoke('kora_core', fn) end
taxThreads = {}
coreConfig.money.tax.enabled = false

-- Both actual callers share the new check; a failed recipe still refunds a
-- consumed useable item using the existing handler, without consuming inputs.
reset({ [1] = item('ballast', 1, 1), [2] = item('ingredient', 1, 2), [3] = item('voucher', 1, 3) })
job.Config.recipes.paired = paired
invoke('kora_jobcreator', crafting.registerUseable, business, { item = 'voucher', consume = 1, useType = 'recipe', recipe = 'paired' })
H.ok(invoke('kora_jobcreator', api.useItem, 7, 'voucher'))
H.equal(count('voucher'), 1); H.equal(count('ingredient'), 1)
H.equal(count('output_a'), 0); H.equal(count('output_b'), 0)
H.equal(xp, 0); H.equal(#logs, 0); H.equal(notifications[#notifications].type, 'error')

-- A deliberately failed grant checks the success/XP boundary only. The
-- capacity query is not a rollback transaction for unexpected operation errors.
reset({ [1] = item('ingredient', 1, 1) })
local actualAdd = functions.kora_core.addItem
functions.kora_core.addItem = function(src, name, ...)
    if name == 'output_b' then return false, 'controlled unexpected failure' end
    return actualAdd(src, name, ...)
end
local failed, reason = invoke('kora_jobcreator', crafting.craft, 7, paired, business)
H.equal(failed, false); H.equal(reason, 'You do not have room for that.')
H.equal(xp, 0); H.equal(#logs, 0)
H.equal(count('ingredient'), 0); H.equal(count('output_a'), 1); H.equal(count('output_b'), 0)
functions.kora_core.addItem = actualAdd

reset({ [1] = item('wood', 1, 1), [2] = item('ingredient', 1, 2) })
local actualRemove = functions.kora_core.removeItem
functions.kora_core.removeItem = function(src, name, ...)
    if name == 'ingredient' then return false, 'controlled removal failure' end
    return actualRemove(src, name, ...)
end
local removalFailed, removalReason = invoke('kora_jobcreator', crafting.craft, 7,
    rewards({ { item = 'wood' }, { item = 'ingredient' } }, { { item = 'board' } }), business)
H.equal(removalFailed, false); H.equal(removalReason, 'You are missing ingredients.')
H.equal(count('wood'), 1, 'existing refund restores the previous removed ingredient')
H.equal(count('ingredient'), 1); H.equal(count('board'), 0)
H.equal(xp, 0); H.equal(#logs, 0)
functions.kora_core.removeItem = actualRemove

io.write(('craft capacity transport: %s\n'):format(freshReferences and 'fresh coroutine per reference' or 'direct references'))
H.finish()
