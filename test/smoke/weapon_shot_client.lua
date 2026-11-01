local H = dofile('test/harness.lua')

local events, handlers, cacheHandlers, sent = {}, {}, {}, {}
local ped, currentWeapon, now = 42, 0, 0
local pedExports, pedNatives, ammoReads = 0, 0, 0
local ammo = {}

Config = { qbinventory = {
    weaponCarry = { enabled = false },
    weapons = { ballistics = { enabled = true } },
} }
exports = { kora_core = { onPlayerDataChange = function() end, getPlayerData = function() return {} end } }
Kora = {
    cache = {
        ped = function() pedExports = pedExports + 1; return ped end,
        weapon = function() return currentWeapon end,
        onChange = function(name, callback) cacheHandlers[name] = callback end,
    },
    progressbar = { start = function() return true end },
}
RegisterNetEvent = function(name, callback) events[name] = callback end
AddEventHandler = function(name, callback) handlers[name] = callback end
TriggerServerEvent = function(name, ...)
    sent[#sent + 1] = { name = name, args = { ... } }
end
PlayerPedId = function() pedNatives = pedNatives + 1; return ped end
GetGameTimer = function() return now end
joaat = function(name) return 'hash:' .. name end
HasPedGotWeapon = function() return true end
GiveWeaponToPed = function(_, weapon, rounds) ammo[weapon] = rounds end
SetPedAmmo = function(_, weapon, rounds) ammo[weapon] = rounds end
SetPedWeaponTintIndex = function() end
SetCurrentPedWeapon = function(_, weapon) currentWeapon = weapon end
SetWeaponDamageModifier = function() end
SetPedSuffersCriticalHits = function() end
GetAmmoInPedWeapon = function(_, weapon)
    ammoReads = ammoReads + 1
    return ammo[weapon] or 0
end
GetMaxAmmo = function() return true, 300 end
RemoveWeaponFromPed = function(_, weapon) ammo[weapon] = nil end
GetCurrentResourceName = function() return 'kora_inventory' end

dofile('client/weaponcarry.lua')

local function fire(time, shooter)
    now = time
    handlers.CEventGunShot({}, shooter or ped)
end

local function draw()
    events['qbinventory:client:toggleWeapon']({
        name = 'weapon_pistol', slot = 1, action = 'draw', duration = 0, ammo = 10,
    })
    sent = {}
end

local function holster()
    events['qbinventory:client:toggleWeapon']({
        name = 'weapon_pistol', slot = 1, action = 'holster', duration = 0,
    })
    sent = {}
end

fire(0)
H.equal(#sent, 0, 'an inactive inventory does not report nearby gunfire')
H.equal(pedNatives, 0, 'inactive gunfire returns before looking up the local ped')
H.equal(pedExports, 0, 'inactive gunfire performs no cache export')

draw()
local exportsBeforeShots = pedExports
fire(1000, 43)
H.equal(#sent, 0, 'another ped cannot report a shot for the local player')
fire(1000)
fire(1000)
fire(1001)
fire(1005)
fire(1064)
H.equal(#sent, 1, 'callbacks inside the default 65 ms floor send one report')
H.equal(sent[1].name, 'qbinventory:server:weaponFired', 'native reporting keeps the original event')
H.equal(#sent[1].args, 0, 'native reporting keeps its payload-free contract')
fire(1065)
H.equal(#sent, 2, 'a shot exactly at the cadence boundary is reported')
fire(1165)
fire(1265)
fire(1365)
H.equal(#sent, 5, 'automatic fire at 100 ms intervals remains accepted')
H.equal(ammoReads, 0, 'native reports do not depend on ammunition changing before callbacks')
H.equal(pedExports, exportsBeforeShots, 'shot callbacks do not cross the cache export boundary')

Config.qbinventory.weapons.ballistics.shotCooldown = '100'
fire(1464)
H.equal(#sent, 5, 'a runtime cooldown change applies immediately')
fire(1465)
H.equal(#sent, 6, 'the configured cadence boundary is inclusive')
Config.qbinventory.weapons.ballistics.shotCooldown = 0
for _ = 1, 5 do fire(1465) end
H.equal(#sent, 11, 'zero cooldown preserves unrestricted native reporting')
Config.qbinventory.weapons.ballistics.shotCooldown = -1
fire(1465)
H.equal(#sent, 12, 'negative cooldown is clamped to zero like the server')
Config.qbinventory.weapons.ballistics.shotCooldown = nil

holster()
fire(1466)
H.equal(#sent, 0, 'holstering stops native reports')
draw()
fire(1466)
H.equal(#sent, 1, 'a new draw clears the previous client cadence')
draw()
fire(1467)
H.equal(#sent, 1, 'redrawing clears the cadence even without a holster')
cacheHandlers.weapon('hash:weapon_unarmed')
sent = {}
fire(1468)
H.equal(#sent, 0, 'a weapon switch stops inventory shot reporting')
draw()
fire(1468)
H.equal(#sent, 1, 'drawing after an external switch starts a fresh cadence')

ped = 84
fire(1469, 42)
H.equal(#sent, 1, 'gunfire from the old ped is ignored immediately after replacement')
fire(1469)
H.equal(#sent, 2, 'the replacement ped starts a fresh client cadence')
cacheHandlers.isDead(true)
sent = {}
fire(1470)
H.equal(#sent, 0, 'death clears the drawn weapon')
draw()
fire(1470)
H.equal(#sent, 1, 'drawing after death resets the client cadence')

holster()
events['qbinventory:client:startTrainingWeapon']('weapon_pistol', 10)
fire(1471)
fire(1472)
H.equal(#sent, 1, 'training uses the same cadence floor as its server handler')
H.equal(sent[1].name, 'qbinventory:server:weaponFired', 'training keeps the native shot event')
H.equal(#sent[1].args, 0, 'training reports remain payload-free')
fire(1536)
H.equal(#sent, 2, 'training forwards a shot at the boundary')
events['qbinventory:client:stopTrainingWeapon']()
fire(1537)
H.equal(#sent, 2, 'stopped training does not report subsequent callbacks')
events['qbinventory:client:startTrainingWeapon']('weapon_pistol', 10)
fire(1537)
H.equal(#sent, 3, 'a new training session resets the client cadence')
cacheHandlers.isDead(true)
fire(1538)
H.equal(#sent, 3, 'death stops training reports')
events['qbinventory:client:startTrainingWeapon']('weapon_pistol', 10)
fire(1538)
H.equal(#sent, 4, 'training after death starts a fresh cadence')
events['qbinventory:client:stopTrainingWeapon']()

Config.qbinventory.weapons.ballistics.enabled = false
draw()
exportsBeforeShots = pedExports
ammo['hash:weapon_pistol'] = 9
fire(1540)
ammo['hash:weapon_pistol'] = 8
fire(1541)
H.equal(#sent, 2, 'legacy lower-only ammo reports are not throttled inside 65 ms')
H.equal(sent[1].name, 'qbinventory:server:weaponAmmoConsumed', 'disabled ballistics keeps the legacy event')
H.equal(sent[1].args[1], 1, 'legacy reporting keeps the drawn slot')
H.equal(sent[1].args[2], 9, 'legacy reporting reads the first native ammo count')
H.equal(sent[2].args[2], 8, 'the final fast shot is persisted even when the burst stops')
H.equal(pedExports, exportsBeforeShots, 'legacy callbacks also avoid cache exports')
fire(1541)
H.equal(#sent, 3, 'unchanged legacy ammo reports preserve their existing behavior')
H.equal(ammoReads, 3, 'the legacy path reads native ammo once per callback')

events['qbinventory:client:startTrainingWeapon']('weapon_pistol', 10)
sent = {}
fire(1542)
fire(1543)
H.equal(#sent, 1, 'training remains regulated when ordinary ballistics are disabled')
H.equal(sent[1].name, 'qbinventory:server:weaponFired', 'training still reports a native round with ballistics disabled')

events['qbinventory:client:stopTrainingWeapon']()
Config.qbinventory.weapons.ballistics.enabled = true
draw()
fire(1608)
events['qbinventory:client:addAmmo']({ weapon = 'weapon_pistol', rounds = 10, ammo = 20 })
fire(1673)
H.equal(#sent, 2, 'reloading does not suppress the next shot at the accepted cadence')
H.equal(sent[2].name, 'qbinventory:server:weaponFired', 'reloading preserves payload-free native reporting')
H.equal(ammoReads, 3, 'native reports after reloading still do not inspect ammo')

H.finish()
