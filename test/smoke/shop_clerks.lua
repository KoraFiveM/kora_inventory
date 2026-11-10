-- Shop clerk peds: lazy spawn inside the zone, scenario + kora_target option,
-- despawn on exit and on resource stop, global/per-shop/per-location opt-outs,
-- and the floating label dropped only where a clerk stands.
local H = dofile('test/harness.lua')

Config = { kora_inventory = { shops = {} } }
dofile('config.lua')
dofile('config/shops/convenience.lua')
dofile('config/shops/liquorstore.lua')
dofile('config/shops/ammunation.lua')
local convenience = Config.kora_inventory.shops.convenience
local liquor = Config.kora_inventory.shops.liquorstore

H.equal(Config.ShopClerks.enabled, true, 'clerks default on')
H.equal(Config.ShopClerks.showLabel, false, 'label defaults off where a clerk exists')
H.equal(Config.ShopClerks.scenario, 'WORLD_HUMAN_CLIPBOARD', 'clerk plays the clipboard scenario')

local withPed, without = 0, {}
for _, shop in ipairs({ convenience, liquor }) do
    for _, location in ipairs(shop.locations) do
        if location.ped then withPed = withPed + 1 else without[#without + 1] = location end
    end
end
H.equal(withPed, 16, '14 tester spots plus the Banham Canyon and Davis LTD shops have a clerk')
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
KoraInventory = {}
dofile('client/shop_clerks.lua')

H.equal(#zones, 16, 'one lazy zone per clerk, none for Ammu-Nation or ped-less counters')
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
H.ok(KoraInventory.shopClerkActive(convenience.locations[1]), 'counter zone yields while the clerk is up')
zone.onEnter()
local count = 0 for _ in pairs(entities) do count = count + 1 end
H.equal(count, 1, 'a second enter does not duplicate the clerk')

zone.onExit()
H.equal(next(entities), nil, 'leaving the zone deletes the clerk')
H.equal(#removedTargets, 1, 'the target registration is removed with it')
H.equal(KoraInventory.shopClerkActive(convenience.locations[1]), false, 'counter zone is the fallback again')

-- Resource stop cleans up every live clerk and zone.
zone.onEnter(); zones[1].onEnter(); zones[2].onEnter()
handlers.onClientResourceStop('kora_inventory')
H.equal(next(entities), nil, 'resource stop deletes all clerks')
H.ok(zone.removed and zones[2].removed, 'resource stop removes the zones')

-- Opt-outs.
H.equal(KoraInventory.shopHasClerk(convenience, convenience.locations[1]), true, 'clerk configured')
H.equal(KoraInventory.shopHasClerk(convenience, convenience.locations[9]), false, 'no spot, no clerk')
local ammunation = Config.kora_inventory.shops.ammunation
H.equal(KoraInventory.shopHasClerk(ammunation, ammunation.locations[1]), true,
    'Ammu-Nation shopkeepers count as a ped (no label), though they are not clerks')
H.equal(KoraInventory.shopHasClerk(ammunation, ammunation.locations[5]), true,
    'Legion Square counts too: kora_mdt supplies the clerk while it runs')
ammunation.locations[1].shopkeeper = false
H.equal(KoraInventory.shopHasClerk(ammunation, ammunation.locations[1]), false, 'location.shopkeeper = false')
ammunation.locations[1].shopkeeper = nil
local savedPed = ammunation.locations[1].ped
ammunation.locations[1].ped = nil
H.equal(KoraInventory.shopHasClerk(ammunation, ammunation.locations[1]), false, 'no ped spot, no shopkeeper')
ammunation.locations[1].ped = savedPed
ammunation.shopkeeper.enabled = false
H.equal(KoraInventory.shopHasClerk(ammunation, ammunation.locations[1]), false, 'shopkeeper.enabled = false')
ammunation.shopkeeper.enabled = true
for i, location in ipairs(ammunation.locations) do
    H.equal(KoraInventory.shopHasClerk(ammunation, location), true, 'every Ammu-Nation store has a ped (' .. i .. ')')
end
liquor.clerk = false
H.equal(KoraInventory.shopHasClerk(liquor, liquor.locations[1]), false, 'shop.clerk = false')
liquor.clerk = nil
liquor.locations[1].clerk = false
H.equal(KoraInventory.shopHasClerk(liquor, liquor.locations[1]), false, 'location.clerk = false')
liquor.locations[1].clerk = nil
Config.ShopClerks.enabled = false
H.equal(KoraInventory.shopHasClerk(liquor, liquor.locations[1]), false, 'global toggle off restores the old path')

-- shop_hints: no marker and no text at counters served by a ped (clerk or
-- Ammu-Nation shopkeeper) unless Config.ShopHints.markerAtPeds /
-- Config.ShopClerks.showLabel; ped-less counters keep both.
Config.ShopClerks.enabled = true
Config.ShopHints.enabled = true
H.equal(Config.ShopHints.markerAtPeds, false, 'no marker at ped counters by default')
local texts, markers = {}, {}
Kora.lang = function(k) return k end
Kora.drawing = { text3d = function(_, text) texts[#texts + 1] = text end }
local hintZones, threads = {}, {}
Kora.zones.sphere = function(o) hintZones[#hintZones + 1] = o; return { remove = function() end } end
CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end
Wait = function() coroutine.yield() end
DrawMarker = function(_, x, y) markers[#markers + 1] = { x = x, y = y } end
GetGameTimer = function() return 0 end
exports.kora_theme = { getPrimaryColor = function() return '#112233' end }
local function loadHints(shops)
    Config.kora_inventory.shops = shops
    hintZones, threads = {}, {}
    dofile('client/shop_hints.lua')
end
-- Enters and leaves every hint zone in turn; returns markers and texts drawn.
local function drawAll()
    texts, markers = {}, {}
    for _, zone in ipairs(hintZones) do
        zone.onEnter()
        for _, t in ipairs(threads) do coroutine.resume(t) end
        zone.onExit()
        for _, t in ipairs(threads) do coroutine.resume(t) end
        threads = {}
    end
    return #markers, #texts
end
local function pedCounters(shop)
    local served, free = {}, 0
    for _, location in ipairs(shop.locations) do
        if KoraInventory.shopHasClerk(shop, location) then
            served[location.x .. ',' .. location.y] = true
        else
            free = free + 1
        end
    end
    return served, #shop.locations, free
end
local convServed, convTotal, convFree = pedCounters(convenience)
H.equal(convFree, 2, 'two 24/7 counters (Senora Fwy, Grapeseed) have no ped')

Config.ShopHints.showText = true -- text is off by default; check it is still dropped at ped counters
loadHints({ c = convenience })
H.equal(#hintZones, convFree, 'counters with a clerk get no hint zone at all')
local m, t = drawAll()
H.equal(m, convFree, 'the marker stays where there is no clerk')
H.equal(t, convFree, 'the label stays where there is no clerk')
for _, marker in ipairs(markers) do
    H.equal(convServed[marker.x .. ',' .. marker.y], nil, 'no marker at a clerk counter')
end
Config.ShopHints.markerAtPeds = true
loadHints({ c = convenience })
m, t = drawAll()
H.equal(m, convTotal, 'markerAtPeds = true draws the marker at clerk counters too')
H.equal(t, convFree, 'markerAtPeds does not bring the text back')
Config.ShopClerks.showLabel = true
loadHints({ c = convenience })
m, t = drawAll()
H.equal(t, convTotal, 'showLabel = true keeps the text')
Config.ShopHints.markerAtPeds = false
loadHints({ c = convenience })
m, t = drawAll()
H.equal(m, convFree, 'showLabel alone does not bring the marker back')
H.equal(t, convTotal, 'showLabel alone keeps the text at clerk counters')

-- Ammu-Nation: every store has a shopkeeper, so no marker and no text anywhere.
Config.ShopClerks.showLabel = false
loadHints({ a = ammunation })
H.equal(#hintZones, 0, 'no marker or text zone at any Ammu-Nation store')
Config.ShopHints.markerAtPeds = true
loadHints({ a = ammunation })
m, t = drawAll()
H.equal(m, #ammunation.locations, 'markerAtPeds = true draws the marker at every Ammu-Nation')
H.equal(t, 0, 'no [ALT] Shop text at any Ammu-Nation store')
Config.ShopClerks.showLabel = true
loadHints({ a = ammunation })
m, t = drawAll()
H.equal(t, #ammunation.locations, 'showLabel = true keeps the text at Ammu-Nation')

-- Default config: no text anywhere, markers only at the ped-less 24/7 counters.
Config.ShopClerks.showLabel = false
Config.ShopHints.markerAtPeds = false
Config.ShopHints.showText = false
loadHints({ c = convenience, a = ammunation, l = liquor })
m, t = drawAll()
H.equal(t, 0, 'default config draws no floating text')
H.equal(m, convFree, 'default config draws markers only where no ped serves the counter')
H.equal(#hintZones, convFree, 'default config registers no zone at ped counters')

H.finish()
