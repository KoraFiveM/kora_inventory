-- Behavioural coverage for server/weaponcarry.lua -- the server-owned carried
-- weapon list and the draw/holster pacing -- plus source-pattern coverage
-- (the style of test/smoke/hotbar.lua) for the client half, which is all
-- FiveM natives this plain-Lua harness cannot execute.
--
-- What matters here is that a client never gets to decide what a player is
-- seen carrying, and that "concealed" costs extra ONLY when concealment is a
-- real thing (visibility = 'hotbar').
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')
dofile('config/shops/ammunation.lua')
dofile('shared.lua')

local netEvents, localEvents, clientEvents, bags = {}, {}, {}, {}

QB = {
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function() end },
    sql = {},
}
GetCurrentResourceName = function() return 'qbinventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function(name, fn) localEvents[name] = fn end
RegisterNetEvent = function(name, fn) if fn then netEvents[name] = fn end end
TriggerEvent = function() end
TriggerClientEvent = function(name, src, payload)
    clientEvents[#clientEvents + 1] = { name = name, source = src, payload = payload }
end
local gameTimer = 1000
GetGameTimer = function() return gameTimer end

-- A player state bag that records exactly what was written, so the test can
-- assert the "clear with false, never nil" convention this server relies on.
Player = function(src)
    return {
        state = {
            set = function(_, key, value, replicated)
                bags[src] = bags[src] or {}
                bags[src][key] = { value = value, replicated = replicated, writes = (bags[src][key] and bags[src][key].writes or 0) + 1 }
            end,
        },
    }
end

local WEAPONS = {
    weapon_carbinerifle = { name = 'weapon_carbinerifle', label = 'Carbine Rifle', type = 'weapon', weapontype = 'Rifle', weight = 3000, unique = true, useable = true },
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', type = 'weapon', weapontype = 'Pistol', weight = 1000, unique = true, useable = true },
    weapon_bat = { name = 'weapon_bat', label = 'Bat', type = 'weapon', weapontype = 'Melee', weight = 1200, unique = true, useable = true },
    weapon_grenade = { name = 'weapon_grenade', label = 'Grenade', type = 'weapon', weapontype = 'Throwable', weight = 400, unique = true, useable = true },
    weapon_petrolcan = { name = 'weapon_petrolcan', label = 'Petrol Can', type = 'weapon', weapontype = 'Equipment', weight = 3000, unique = true, useable = true },
}
local ITEMS = { water_bottle = { name = 'water_bottle', label = 'Water', weight = 100, useable = true } }

local playersData = { [7] = { citizenid = 'CID-7' } }
local playersItems = { [7] = {} }

local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resourceName)
        return setmetatable({}, {
            __index = function(_, exportName)
                return function(_, ...)
                    if resourceName == 'qbcore' then
                        if exportName == 'allShared' then
                            local registry = ...
                            if registry ~= 'weapons' then return {} end
                            local out = {}
                            for _, def in pairs(WEAPONS) do out[#out + 1] = def end
                            return out
                        end
                        if exportName == 'getShared' then
                            local registry, name = ...
                            if registry == 'weapons' then return WEAPONS[name] end
                            return ITEMS[name]
                        end
                        if exportName == 'getPlayerData' then
                            local src, fields = ...
                            if fields and fields[1] == 'items' then return playersItems[src] end
                            return playersData[src]
                        end
                        if exportName == 'setPath' then
                            local src, path, value = ...
                            if path[1] ~= 'items' then return false, 'unsupported path' end
                            playersItems[src] = playersItems[src] or {}
                            if path[2] then playersItems[src][path[2]] = value else playersItems[src] = value end
                            return true
                        end
                        if exportName == 'incrementMetaData' then return true end
                    end
                    local fn = registered[exportName]
                    if fn then return fn(...) end
                    return nil
                end
            end,
        })
    end,
})

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/useables.lua')
dofile('server/crafting.lua')
dofile('server/weaponcarry.lua')

local carry = QbInventory.weaponCarry
local cfg = Config.qbinventory.weaponCarry
local buildItem = QbInventory.internal.buildItem

local function give(slot, name)
    playersItems[7][slot] = buildItem(name, 1, slot, {})
end

-- classification ------------------------------------------------------------

H.equal(carry.carryRule('weapon_carbinerifle').tier, 'back', 'a rifle is carried on the back')
H.equal(carry.carryRule('weapon_pistol').tier, 'hip', 'a pistol is carried on the hip')
H.equal(carry.carryRule('weapon_bat').tier, 'sling', 'a melee weapon is slung')
H.equal(carry.carryRule('weapon_grenade'), nil, 'a throwable has no configured tier and is not carried')
H.equal(carry.carryRule('weapon_petrolcan'), nil, 'an explicit tier = false override excludes a weapon')
H.equal(carry.carryRule('water_bottle'), nil, 'a non-weapon item is not carried without an explicit entry')

-- visibility ----------------------------------------------------------------

give(1, 'weapon_carbinerifle')
give(3, 'weapon_pistol')
give(4, 'water_bottle')
give(9, 'weapon_bat')
playersItems[7][9].info.ammo = 7

cfg.visibility = 'hotbar'
local hotbarList = carry.buildCarryList(7)
H.equal(#hotbarList, 2, "'hotbar' visibility carries only the weapons inside the hotbar range")
H.equal(hotbarList[1].name, 'weapon_carbinerifle', 'the carried list is ordered by slot')
H.equal(hotbarList[2].name, 'weapon_pistol', 'a non-weapon hotbar item is skipped')

cfg.visibility = 'all'
local allList = carry.buildCarryList(7)
H.equal(#allList, 3, "'all' visibility also carries a weapon stowed past the hotbar")
H.equal(allList[3].name, 'weapon_bat', 'the stowed weapon keeps its slot order')

cfg.enabled = false
H.equal(#carry.buildCarryList(7), 0, 'a disabled carry system carries nothing at all')
cfg.enabled = true

-- draw pacing ---------------------------------------------------------------

cfg.visibility = 'hotbar'
H.equal(carry.drawDuration(1), cfg.drawTime, 'drawing an openly carried weapon costs the base draw time')
H.equal(carry.drawDuration(9), cfg.drawTime + cfg.concealedDrawTime,
    'drawing from outside the hotbar costs the concealment surcharge on top')

cfg.visibility = 'all'
H.equal(carry.drawDuration(9), cfg.drawTime,
    "'all' visibility never charges the surcharge -- every weapon was already visible")
cfg.enabled = false
H.equal(carry.drawDuration(9), cfg.drawTime, 'a disabled carry system never charges the surcharge either')
cfg.enabled = true
cfg.visibility = 'hotbar'

-- toggle round trip ---------------------------------------------------------

local function lastClientEvent()
    return clientEvents[#clientEvents]
end

clientEvents = {}
H.ok(carry.toggle(7, playersItems[7][9]), 'using a weapon item is accepted')
local request = lastClientEvent()
H.equal(request.name, 'qbinventory:client:toggleWeapon', 'the draw is handed to that one client to play out')
H.equal(request.payload.action, 'draw', 'an empty-handed player draws')
H.equal(request.payload.slot, 9, 'the client is told which slot it is drawing')
H.equal(request.payload.duration, cfg.drawTime + cfg.concealedDrawTime,
    'the concealed draw duration reaches the client')
H.equal(request.payload.ammo, 7, 'a draw receives the server-persisted ammunition amount')
H.equal(carry.equippedWeapon(7), nil, 'nothing is equipped until the client confirms the animation finished')

-- A confirmation for a slot the server did not ask about is ignored: the
-- client may only finish the draw it was actually given.
source = 7
netEvents['qbinventory:server:weaponToggled'](1)
H.equal(carry.equippedWeapon(7), nil, 'a confirmation for a different slot is rejected')

netEvents['qbinventory:server:weaponToggled'](9)
H.equal(carry.equippedWeapon(7).name, 'weapon_bat', 'the confirmed draw equips that weapon')
H.equal(carry.equippedWeapon(7).slot, 9, 'the confirmed slot is recorded')

netEvents['qbinventory:server:weaponAmmoConsumed'](9, 3)
H.equal(QbInventory.weapons.getState(7, 9).ammo, 3, 'a shot report lowers durable ammo for the equipped weapon')
H.equal(QbInventory.weapons.getState(7, 9).durability, 99.6,
    'durability loses the configured amount for every consumed round')
netEvents['qbinventory:server:weaponAmmoConsumed'](9, 99)
H.equal(QbInventory.weapons.getState(7, 9).ammo, 3, 'a shot report cannot increase durable ammunition')

local weaponDurability = Config.qbinventory.weapons.durability
weaponDurability.multipliers.weapon_bat = 2
H.ok(math.abs(carry.shotWear('weapon_bat', 3) - 0.6) < 0.000001,
    'a per-weapon multiplier scales wear by accepted shots')
weaponDurability.excluded.weapon_bat = true
H.equal(carry.shotWear('weapon_bat', 3), 0, 'excluded weapons do not wear from shooting')
weaponDurability.excluded.weapon_bat = nil
weaponDurability.multipliers.weapon_bat = nil

netEvents['qbinventory:server:weaponFired']()
H.equal(QbInventory.weapons.getState(7, 9).ammo, 2, 'the native shot path consumes one server-owned round')
H.equal(QbInventory.weapons.getState(7, 9).durability, 99.5,
    'the native shot path applies one configured durability loss')

netEvents['qbinventory:server:weaponToggled'](9)
H.equal(carry.equippedWeapon(7).slot, 9, 'a replayed confirmation changes nothing -- the request is consumed')

cfg.visibility = 'all'
local holding = carry.buildCarryList(7)
H.equal(#holding, 2, 'a weapon in hand is not also rendered on the body')
for _, entry in ipairs(holding) do
    H.ok(entry.name ~= 'weapon_bat', 'the equipped weapon is the one missing from the carried list')
end

clientEvents = {}
carry.toggle(7, playersItems[7][9])
H.equal(lastClientEvent().payload.action, 'holster', 'using the held weapon again holsters it')
H.equal(lastClientEvent().payload.duration, cfg.holsterTime, 'a holster costs the holster time, never the surcharge')
netEvents['qbinventory:server:weaponToggled'](9)
H.equal(carry.equippedWeapon(7), nil, 'a confirmed holster empties the hands')

-- Losing the weapon by any other route (weapon wheel, disarm, death) is
-- reported with no payload -- there is nothing there worth trusting.
carry.toggle(7, playersItems[7][9])
netEvents['qbinventory:server:weaponToggled'](9)
H.equal(carry.equippedWeapon(7).slot, 9, 'the weapon is drawn again')
netEvents['qbinventory:server:weaponUnequipped']()
H.equal(carry.equippedWeapon(7), nil, 'an unequip report puts the weapon back on the body')

-- Giving the held weapon away must not leave the server believing it is still
-- in the player's hands, hiding a weapon they no longer own.
carry.toggle(7, playersItems[7][9])
netEvents['qbinventory:server:weaponToggled'](9)
playersItems[7][9] = nil
localEvents['qbcore:server:inventoryChanged'](7)
H.equal(carry.equippedWeapon(7), nil, 'losing the held item clears the equipped record')

-- state bag -----------------------------------------------------------------

local stateKey = carry.stateKey
carry.refresh(7)
H.ok(type(bags[7][stateKey].value) == 'table', 'the carried list is published on the player state bag')
H.equal(bags[7][stateKey].replicated, true, 'the carried list is replicated to other clients')

playersItems[7] = {}
carry.refresh(7)
H.equal(bags[7][stateKey].value, false,
    'an empty carried list clears the bag with an explicit false, never a nil deletion')

-- source patterns -----------------------------------------------------------

local function read(path)
    local file = assert(io.open(path, 'r'))
    local text = file:read('*a')
    file:close()
    return text
end

local server = read('server/weaponcarry.lua')
local client = read('client/weaponcarry.lua')
local manifest = read('fxmanifest.lua')
local hotbar = read('client/hotbar.lua')
local useables = read('server/useables.lua')

H.ok(not client:find('LocalPlayer.state:set', 1, true),
    'the client never writes its own carried list -- the bag is server-owned')
H.ok(server:find("player.state:set(STATE_KEY", 1, true),
    'the server is what publishes the carried list')
H.ok(client:find("QB.state.onChange(STATE_KEY, nil,", 1, true),
    'the client subscribes with no bag filter, so it is not bound to player:-1 at load')
H.ok(client:find('canCancel = false', 1, true),
    'a draw cannot be cancelled -- otherwise the surcharge is free to skip')
H.ok(client:find('QB.stream.loadWeaponAsset', 1, true) and client:find('QB.stream.loadModel', 1, true),
    'streaming goes through qblib rather than raw request/poll loops')
H.ok(client:find('IsWeaponValid(', 1, true),
    'a configured entry that is not a real weapon cannot assert inside the renderer')
H.ok(useables:find('QbInventory.weaponCarry', 1, true),
    'the weapon useable delegates the draw to the weapon carry module')
H.ok(server:find("'qbinventory:server:weaponFired'", 1, true)
    and client:find("'qbinventory:server:weaponFired'", 1, true),
    'native shots reach the server without a client-selected weapon or ammo count')
H.ok(manifest:find("'server/weaponcarry.lua'", 1, true) and manifest:find("'client/weaponcarry.lua'", 1, true),
    'both halves are loaded by the manifest')
H.ok(hotbar:find('Config.qbinventory.hotbarSlots', 1, true),
    'the hotbar keybinds and the carry visibility read one shared slot range')

H.finish()
