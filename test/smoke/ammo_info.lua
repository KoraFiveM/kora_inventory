-- "Which ammo does this gun take?" view fields. Computed server-side from
-- kora_core definitions and the item's own metadata, never from client input.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')
Kora = {
    util = { deepClone = function(value)
        local function clone(v)
            if type(v) ~= 'table' then return v end
            local copy = {}
            for k, vv in pairs(v) do copy[clone(k)] = clone(vv) end
            return copy
        end
        return clone(value)
    end },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function() end },
}
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
GetGameTimer = function() return 100 end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function() end
RegisterNetEvent = function() end
TriggerEvent = function() end
TriggerClientEvent = function() end

local ITEMS = {
    pistol_ammo = { name = 'pistol_ammo', label = 'Pistol Magazine', ammoType = 'AMMO_PISTOL', rounds = 12, weight = 1 },
    dud_ammo = { name = 'dud_ammo', label = 'Dud', ammoType = 'AMMO_PISTOL', rounds = 0, weight = 1 },
    rifle_ammo = { name = 'rifle_ammo', label = 'Rifle Magazine', ammoType = 'AMMO_RIFLE', rounds = 30, weight = 1 },
    card = { name = 'card', label = 'Card', weight = 1 },
}
local WEAPONS = {
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL', ammoItem = 'pistol_ammo', unique = true, weight = 1 },
    weapon_combatpistol = { name = 'weapon_combatpistol', label = 'Combat Pistol', ammotype = 'AMMO_PISTOL', ammoItem = 'pistol_ammo', unique = true, weight = 1 },
    weapon_nomag = { name = 'weapon_nomag', label = 'No Mag', ammotype = 'AMMO_PISTOL', ammoItem = 'missing_ammo', unique = true, weight = 1 },
    weapon_bat = { name = 'weapon_bat', label = 'Bat', unique = true, weight = 1 },
}
local weaponOrder = { 'weapon_pistol', 'weapon_combatpistol', 'weapon_nomag', 'weapon_bat' }
local handlers = {}
local player = { name = 'Test', items = {} }
exports = setmetatable({ kora_core = {
    allShared = function(_, registry)
        local out = {}
        if registry == 'weapons' then
            for _, name in ipairs(weaponOrder) do out[#out + 1] = WEAPONS[name] end
        end
        return out
    end,
    getShared = function(_, registry, name)
        return (registry == 'items' and ITEMS[name]) or (registry == 'weapons' and WEAPONS[name]) or nil
    end,
    onSharedChange = function(_, registry, fn) handlers[registry] = fn end,
    getPlayerData = function(_, _, path) return path and player.items or player end,
    setPath = function(_, _, path, value) player.items[path[2]] = value; return true end,
} }, { __call = function() end })
dofile('server.lua')
local api, internal = KoraInventory.api, KoraInventory.internal

local function rows(item)
    local out = {}
    for _, entry in ipairs(item.displayMeta) do out[entry.key] = entry end
    return out
end
local function viewSlot(slot)
    return internal.view('player:1').items[slot]
end
local function reset(cfg)
    player.items = {}
    local base = Config.kora_inventory.weapons
    base.ammoInfo = cfg
end

-- weapon
reset({ enabled = true, where = 'both', showLoaded = true, showCompatible = true })
H.ok(api.AddItem(1, 'weapon_pistol', 1, 1, { ammo = 7 }), 'weapon added')
local gun = viewSlot(1)
H.equal(gun.ammo.type, 'AMMO_PISTOL', 'weapon ammo type')
H.equal(gun.ammo.item, 'pistol_ammo', 'weapon ammo item')
H.equal(gun.ammo.label, 'Pistol Magazine', 'label comes from the ammo item def')
H.equal(gun.ammo.loaded, 7, 'loaded rounds from info.ammo')
H.equal(gun.ammoType, nil, 'weapon has no ammo-item fields')
H.equal(rows(gun).ammoTakes.value, 'Pistol Magazine', 'Takes row')
H.equal(rows(gun).ammoTakes.label, 'Takes', 'Takes row label falls back to English')
H.equal(rows(gun).ammoLoaded.value, '7 rounds', 'Loaded row')

-- loadedBullets wins over the scalar
player.items = {}
api.AddItem(1, 'weapon_pistol', 1, 1, { ammo = 99, loadedBullets = { { id = 'a' }, { id = 'b' }, { id = 'c' } } })
H.equal(viewSlot(1).ammo.loaded, 3, 'discrete loaded rounds are counted')

-- missing ammo item def falls back to the item name
player.items = {}
api.AddItem(1, 'weapon_nomag', 1, 1, {})
H.equal(viewSlot(1).ammo.label, 'missing_ammo', 'label falls back to the ammo item name')
H.equal(viewSlot(1).ammo.loaded, 0, 'no metadata means zero loaded')

-- weapon without an ammotype
player.items = {}
api.AddItem(1, 'weapon_bat', 1, 1, {})
local bat = viewSlot(1)
H.equal(bat.ammo, nil, 'melee weapon gets no ammo field')
H.equal(rows(bat).ammoTakes, nil, 'and no Takes row')

-- ammo item
player.items = {}
api.AddItem(1, 'pistol_ammo', 3, 1, {})
local mag = viewSlot(1)
H.equal(mag.ammoType, 'AMMO_PISTOL', 'ammo type')
H.equal(mag.rounds, 12, 'rounds per item')
H.equal(#mag.fits, 3, 'fits lists matching weapons')
H.equal(mag.fits[1], 'Combat Pistol', 'fits sorted')
H.equal(mag.fits[2], 'No Mag', 'fits sorted (2)')
H.equal(mag.fits[3], 'Pistol', 'fits sorted (3)')
H.equal(mag.ammo, nil, 'ammo item has no weapon field')
H.equal(rows(mag).ammoRounds.value, 12, 'Rounds row')
H.equal(rows(mag).ammoFits.value, 'Combat Pistol, No Mag, Pistol', 'Fits row')

-- ammo with no matching weapons, malformed ammo, plain items
player.items = {}
api.AddItem(1, 'rifle_ammo', 1, 1, {})
api.AddItem(1, 'dud_ammo', 1, 2, {})
api.AddItem(1, 'card', 1, 3, {})
H.equal(viewSlot(1).fits, nil, 'no weapon fits: no list')
H.equal(viewSlot(1).rounds, 30, 'but rounds still shown')
H.equal(rows(viewSlot(1)).ammoFits, nil, 'and no Fits row')
H.equal(viewSlot(2).ammoType, nil, 'zero-round ammo is not ammunition')
H.equal(viewSlot(3).ammoType, nil, 'plain items get nothing')
H.equal(#viewSlot(3).displayMeta, 0, 'plain items get no rows')

-- cap + runtime invalidation
for i = 1, 14 do
    local name = 'weapon_extra' .. ('%02d'):format(i)
    WEAPONS[name] = { name = name, label = 'Extra ' .. ('%02d'):format(i), ammotype = 'AMMO_PISTOL', ammoItem = 'pistol_ammo' }
    weaponOrder[#weaponOrder + 1] = name
end
player.items = {}
api.AddItem(1, 'pistol_ammo', 1, 1, {})
H.equal(#viewSlot(1).fits, 3, 'index is cached until kora_core reports a change')
H.ok(handlers.weapons, 'index subscribes to weapons changes')
H.ok(handlers.items, 'index subscribes to items changes')
handlers.weapons('add', 'weapon_extra01', WEAPONS.weapon_extra01)
local capped = viewSlot(1).fits
H.equal(#capped, 13, 'capped at 12 plus a trailing note')
H.equal(capped[13], '+5 more', 'overflow note counts the remainder')

-- showLoaded / showCompatible off
reset({ enabled = true, where = 'both', showLoaded = false, showCompatible = false })
api.AddItem(1, 'weapon_pistol', 1, 1, { ammo = 5 })
api.AddItem(1, 'pistol_ammo', 1, 2, {})
local g2, m2 = viewSlot(1), viewSlot(2)
H.equal(g2.ammo.loaded, nil, 'showLoaded=false omits loaded')
H.equal(rows(g2).ammoLoaded, nil, 'and the Loaded row')
H.ok(rows(g2).ammoTakes, 'Takes row remains')
H.equal(m2.fits, nil, 'showCompatible=false omits fits')
H.equal(rows(m2).ammoFits, nil, 'and the Fits row')
H.equal(m2.rounds, 12, 'rounds remain')

-- disabled
reset({ enabled = false })
api.AddItem(1, 'weapon_pistol', 1, 1, { ammo = 5 })
api.AddItem(1, 'pistol_ammo', 1, 2, {})
g2, m2 = viewSlot(1), viewSlot(2)
H.equal(g2.ammo, nil, 'disabled: no weapon fields')
H.equal(m2.ammoType, nil, 'disabled: no ammo fields')
H.equal(m2.rounds, nil, 'disabled: no rounds')
H.equal(#g2.displayMeta, 1, 'disabled: only real metadata rows remain (ammo)')
H.equal(g2.displayMeta[1].key, 'ammo', 'disabled: the raw metadata row is untouched')

-- where
reset({ enabled = true, where = 'menu' })
api.AddItem(1, 'weapon_pistol', 1, 1, {})
api.AddItem(1, 'pistol_ammo', 1, 2, {})
g2, m2 = viewSlot(1), viewSlot(2)
H.ok(g2.ammo and m2.fits, 'menu: fields still present for the menu entry')
H.equal(rows(g2).ammoTakes, nil, 'menu: no inspector weapon rows')
H.equal(rows(m2).ammoRounds, nil, 'menu: no inspector ammo rows')
for _, where in ipairs({ 'inspector', 'both' }) do
    reset({ enabled = true, where = where })
    api.AddItem(1, 'weapon_pistol', 1, 1, {})
    api.AddItem(1, 'pistol_ammo', 1, 2, {})
    H.ok(rows(viewSlot(1)).ammoTakes, where .. ': weapon rows')
    H.ok(rows(viewSlot(2)).ammoFits, where .. ': ammo rows')
end

-- never persisted / never trusted from the record
reset({ enabled = true, where = 'both' })
api.AddItem(1, 'weapon_pistol', 1, 1, {})
local stored = player.items[1]
H.equal(stored.ammo, nil, 'stored record carries no view field')
H.equal(stored.ammoType, nil, 'stored record carries no ammoType')
player.items[1].ammo = { type = 'SPOOF' }
H.equal(viewSlot(1).ammo.type, 'AMMO_PISTOL', 'a spoofed top-level ammo field is replaced from the definition')
player.items[1].ammo = nil

-- shops show what ammo a gun takes
local shop = internal.createSecondary('shop', 'ammoinfo-shop', {
    slots = 4, maxWeight = 1000,
    stock = { [1] = internal.buildItem('weapon_pistol', 1, 1, {}), [2] = internal.buildItem('pistol_ammo', 5, 2, {}) },
})
local shopView = internal.view(shop.key)
H.equal(shopView.stock[1].ammo.item, 'pistol_ammo', 'shop weapon stock shows its ammo')
H.equal(shopView.stock[2].rounds, 12, 'shop ammo stock shows rounds')

H.finish()
