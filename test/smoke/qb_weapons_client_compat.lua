-- Client half of the qb-weapons adapter: old events are only slot requests,
-- and its attachment export is derived from configured allow-lists.
local H = dofile('test/harness.lua')

local events, sent, registered = {}, {}, {}
Config = {
    qbinventory = {
        weapons = { components = { weapon_pistol = { 'flashlight_attachment', suppressor_attachment = true } } },
        weaponCarry = { components = {
            flashlight_attachment = 'COMPONENT_AT_PI_FLSH',
            suppressor_attachment = 'COMPONENT_AT_PI_SUPP',
        } },
    },
}
Kora = { cache = { ped = function() return 44 end } }
exports = function(name, fn) registered[name] = fn end
RegisterNetEvent = function(name, fn) events[name] = fn end
TriggerServerEvent = function(name, ...) sent[#sent + 1] = { name = name, args = { ... } } end
GetHashKey = function(value) return 'hash:' .. value end
SetPedWeaponTintIndex = function() end

dofile('client/compat/qb_weapons.lua')

local attachments = registered.getConfigWeaponAttachments()
H.equal(attachments.flashlight_attachment.weapon_pistol, 'COMPONENT_AT_PI_FLSH', 'attachment export is derived from configured allow-lists')
H.equal(attachments.suppressor_attachment.weapon_pistol, 'COMPONENT_AT_PI_SUPP', 'keyed component allow-list is supported')

events['qb-weapons:client:UseWeapon']({ slot = 3, name = 'weapon_rpg' })
H.equal(sent[1].name, 'qbinventory:server:legacyWeaponUse', 'legacy weapon use routes to qbinventory')
H.equal(sent[1].args[1], 3, 'legacy weapon name is discarded in favour of its slot')
events['qb-weapons:client:AddAmmo']('AMMO_RIFLE', 99, { slot = 7, name = 'forged' })
H.equal(sent[2].args[1], 7, 'legacy ammo payload is reduced to a slot')
events['qb-weapons:client:CheckWeapon']('weapon_rpg')
H.equal(sent[3].name, 'qbinventory:server:legacyWeaponHolster', 'legacy check weapon carries no client-selected weapon')

H.finish()
