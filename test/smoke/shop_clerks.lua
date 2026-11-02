-- Shop clerk peds: lazy spawn inside the zone, scenario + kora_target option,
-- despawn on exit and on resource stop, global/per-shop/per-location opt-outs,
-- and the floating label dropped only where a clerk stands.
local H = dofile('test/harness.lua')

Config = { qbinventory = { shops = {} } }
dofile('config.lua')
dofile('config/shops/convenience.lua')
dofile('config/shops/liquorstore.lua')
dofile('config/shops/ammunation.lua')
local convenience = Config.qbinventory.shops.convenience
local liquor = Config.qbinventory.shops.liquorstore

H.equal(Config.ShopClerks.enabled, true, 'clerks default on')
H.equal(Config.ShopClerks.showLabel, false, 'label defaults off where a clerk exists')
H.equal(Config.ShopClerks.scenario, 'WORLD_HUMAN_CLIPBOARD', 'clerk plays the clipboard scenario')

local withPed, without = 0, {}
for _, shop in ipairs({ convenience, liquor }) do
    for _, location in ipairs(shop.locations) do
        if location.ped then withPed = withPed + 1 else without[#without + 1] = location end
    end
end
H.equal(withPed, 15, '14 tester spots plus the new Banham Canyon shop have a clerk')
H.equal(#without, 2, 'Senora Fwy and Grapeseed have no ped spot')

vector3 = function(x, y, z) return { x = x, y = y, z = z } end
local handlers, zones, entities, scenarios, targets, removedTargets, n = {}, {}, {}, {}, {}, {}, 0
AddEventHandler = function(name, fn) handlers[name] = fn end
CreateThread = function(fn) fn() end
GetCurrentResourceName = function() return 'kora_inventory' end
DoesEntityExist = function(e) return entities[e] ~= nil end
TaskStartScenarioInPlace = function(e, s) scenarios[e] = s end
Kora = {
    zones = { sphere = function(o) zones[#zones + 1] = o; o.remove = function() o.removed = true end; return o end },
    entities = {
        create = function(model, coords, opts)
            n = n + 1
            entities[n] = { model = model, coords = coords, opts = opts }
            return n
        end,
        remove = function(e) entities[e] = nil end,
    },
}
exports = { kora_target = {
    addEntity = function(_, e, options, dist) targets[e] = { options = options, dist = dist }; return 100 + e end,
    removeEntity = function(_, e, id) removedTargets[#removedTargets + 1] = { e, id }; targets[e] = nil end,
}, kora_inventory = { openInventory = function(_, kind, id) targets.opened = { kind, id } end } }
QbInventory = {}
dofile('client/shop_clerks.lua')

H.equal(#zones, 15, 'one lazy zone per clerk, none for Ammu-Nation or ped-less counters')
H.equal(next(entities), nil, 'no ped exists before a player is near')

local zone
for _, z in ipairs(zones) do if z.coords.x == 24.50 then zone = z end end
zone.onEnter()
local e = next(entities)
H.ok(e, 'entering the zone spawns the clerk')
H.equal(entities[e].opts.preset, 'static', 'clerk is frozen and invincible')
H.equal(entities[e].coords.z, 28.50, 'ped spawns 1.0 below the floor height')
H.equal(scenarios[e], 'WORLD_HUMAN_CLIPBOARD', 'clerk plays the scenario')
H.equal(targets[e].dist, 3.0, 'target distance from config')
targets[e].options[1].onSelect()
H.equal(targets.opened[2], convenience.id, 'the ped option opens its shop')
H.ok(QbInventory.shopClerkActive(convenience.locations[1]), 'counter zone yields while the clerk is up')
zone.onEnter()
local count = 0 for _ in pairs(entities) do count = count + 1 end
H.equal(count, 1, 'a second enter does not duplicate the clerk')

zone.onExit()
H.equal(next(entities), nil, 'leaving the zone deletes the clerk')
H.equal(#removedTargets, 1, 'the target registration is removed with it')
H.equal(QbInventory.shopClerkActive(convenience.locations[1]), false, 'counter zone is the fallback again')

-- Resource stop cleans up every live clerk and zone.
zone.onEnter(); zones[1].onEnter(); zones[2].onEnter()
handlers.onClientResourceStop('kora_inventory')
H.equal(next(entities), nil, 'resource stop deletes all clerks')
H.ok(zone.removed and zones[2].removed, 'resource stop removes the zones')

-- Opt-outs.
H.equal(QbInventory.shopHasClerk(convenience, convenience.locations[1]), true, 'clerk configured')
H.equal(QbInventory.shopHasClerk(convenience, convenience.locations[9]), false, 'no spot, no clerk')
H.equal(QbInventory.shopHasClerk(Config.qbinventory.shops.ammunation, Config.qbinventory.shops.ammunation.locations[1]), false,
    'Ammu-Nation keeps its own shopkeepers')
liquor.clerk = false
H.equal(QbInventory.shopHasClerk(liquor, liquor.locations[1]), false, 'shop.clerk = false')
liquor.clerk = nil
liquor.locations[1].clerk = false
H.equal(QbInventory.shopHasClerk(liquor, liquor.locations[1]), false, 'location.clerk = false')
liquor.locations[1].clerk = nil
Config.ShopClerks.enabled = false
H.equal(QbInventory.shopHasClerk(liquor, liquor.locations[1]), false, 'global toggle off restores the old path')

-- shop_hints: label dropped only at clerk counters.
Config.ShopClerks.enabled = true
Config.ShopHints.enabled = true
local texts = {}
Kora.lang = function(k) return k end
Kora.drawing = { text3d = function(_, text) texts[#texts + 1] = text end }
local hintZones, threads = {}, {}
Kora.zones.sphere = function(o) hintZones[#hintZones + 1] = o; return { remove = function() end } end
Config.qbinventory.shops = { c = convenience }
CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end
Wait = function() coroutine.yield() end
DrawMarker = function() end
GetGameTimer = function() return 0 end
exports.kora_theme = { getPrimaryColor = function() return '#112233' end }
dofile('client/shop_hints.lua')
local function drawAt(i)
    hintZones[i].onEnter()
    texts = {}
    for _, t in ipairs(threads) do coroutine.resume(t) end
    hintZones[i].onExit()
    for _, t in ipairs(threads) do coroutine.resume(t) end
    threads = {}
    return #texts
end
H.equal(drawAt(1), 0, 'no [ALT] Shop text at a clerk counter')
H.equal(drawAt(9), 1, 'the label stays where there is no clerk')
Config.ShopClerks.showLabel = true
hintZones = {}
dofile('client/shop_hints.lua')
H.equal(drawAt(1), 1, 'showLabel = true keeps the text')

H.finish()
