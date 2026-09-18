-- Ammunition use. Before this existed the ammo items were stocked, defined and
-- completely inert: every drawn weapon sat at zero rounds with no way to load
-- one, because no `createUseable` was ever registered for them.
--
-- The policy being pinned here is that WHICH weapon gets loaded is decided by
-- the server, from weaponcarry's own record of the draw it asked for -- the
-- client's use request contributes only a slot.
local H = dofile('test/harness.lua')

Config = { qbinventory = {} }
dofile('config.lua')

-- --- stubs ------------------------------------------------------------------

local ITEMS = {
    pistol_ammo = { name = 'pistol_ammo', label = 'Pistol Magazine', ammoType = 'AMMO_PISTOL', rounds = 12 },
    rifle_ammo = { name = 'rifle_ammo', label = 'Rifle Magazine', ammoType = 'AMMO_RIFLE', rounds = 30 },
    -- Malformed on purpose: an ammoType with no rounds is not usable ammunition.
    dud_ammo = { name = 'dud_ammo', label = 'Dud', ammoType = 'AMMO_PISTOL', rounds = 0 },
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', ammotype = 'AMMO_PISTOL', weapontype = 'Pistol' },
    weapon_bat = { name = 'weapon_bat', label = 'Bat', weapontype = 'Melee' },
}

local WEAPONS = { { name = 'weapon_unarmed' }, { name = 'weapon_pistol' }, { name = 'weapon_bat' } }
local useables = {}
local useableKinds = {}
local removals = {}
local removeResult = true

QbInventory = {
    internal = {
        itemDef = function(name) return ITEMS[name] end,
        setBuiltInUseable = function(name, fn, kind)
            useableKinds[name] = useableKinds[name] or {}
            useableKinds[name][kind or 'default'] = fn
            local handlers = useableKinds[name]
            useables[name] = handlers.weapon or handlers.ammo or handlers.default
            if not useables[name] then
                useableKinds[name] = nil
            end
        end,
    },
    api = {
        createUseable = function(name, fn) useables[name] = fn end,
        removeItem = function(src, name, amount, slot, reason)
            removals[#removals + 1] = { src = src, name = name, amount = amount, slot = slot, reason = reason }
            if removeResult ~= true then return false, removeResult end
            return true
        end,
    },
    weaponCarry = nil, -- set per case below
    weapons = {
        getState = function() return { ammo = 0 } end,
        setAmmo = function() return true end,
        loadRounds = function(_, _, _, count) return true, { ammo = count } end,
    },
}

local pushed = {}
local sharedChangeHandlers = {}
function TriggerClientEvent(event, src, payload)
    pushed[#pushed + 1] = { event = event, src = src, payload = payload }
end

exports = setmetatable({}, {
    __index = function(_, resource)
        return setmetatable({}, {
            __index = function(_, name)
                return function(_, registry, handler)
                    if resource == 'qbcore' and name == 'allShared' then
                        if registry == 'weapons' then return WEAPONS end
                        if registry == 'items' then
                            local out = {}
                            for _, def in pairs(ITEMS) do out[#out + 1] = def end
                            return out
                        end
                    end
                    if resource == 'qbcore' and name == 'onSharedChange' then
                        sharedChangeHandlers[registry] = handler
                        return 1
                    end
                    return {}
                end
            end,
        })
    end,
})

dofile('server/useables.lua')

-- --- registration -----------------------------------------------------------

H.ok(useables.pistol_ammo, 'a magazine with an ammoType and rounds is useable')
H.ok(useables.rifle_ammo, 'every such magazine is registered, not a hard-coded list')
H.equal(useables.dud_ammo, nil, 'an ammoType with no rounds is not registered as usable ammunition')
H.equal(useables.weapon_unarmed, nil, 'fists are still never a useable item')
H.ok(useables.weapon_pistol, 'a weapon remains useable when also registered as an item')

ITEMS.runtime_ammo = { name = 'runtime_ammo', label = 'Runtime Magazine', ammoType = 'AMMO_PISTOL', rounds = 6 }
sharedChangeHandlers.items('add', 'runtime_ammo', ITEMS.runtime_ammo)
H.ok(useables.runtime_ammo, 'an ammunition definition added at runtime becomes useable immediately')
sharedChangeHandlers.items('remove', 'runtime_ammo', nil)
H.equal(useables.runtime_ammo, nil, 'removing a runtime ammunition definition removes its built-in handler')

sharedChangeHandlers.weapons('add', 'weapon_runtime', { name = 'weapon_runtime', weapontype = 'Pistol' })
H.ok(useables.weapon_runtime, 'a weapon definition added at runtime becomes useable immediately')
sharedChangeHandlers.weapons('remove', 'weapon_runtime', nil)
H.equal(useables.weapon_runtime, nil, 'removing a runtime weapon definition removes its built-in handler')

-- --- refusals ---------------------------------------------------------------

local function reset()
    removals, pushed, removeResult = {}, {}, true
end

reset()
QbInventory.weaponCarry = { equippedWeapon = function() return nil end }
local ok, err = useables.pistol_ammo(7, { name = 'pistol_ammo', slot = 4 })
H.equal(ok, false, 'loading with no weapon drawn is refused')
H.equal(err, 'draw a weapon before loading ammunition', 'and says what to do about it')
H.equal(#removals, 0, 'a refused load consumes no magazine')
H.equal(#pushed, 0, 'and asks no client to do anything')

reset()
QbInventory.weaponCarry = { equippedWeapon = function() return { slot = 1, name = 'weapon_bat' } end }
ok, err = useables.pistol_ammo(7, { name = 'pistol_ammo', slot = 4 })
H.equal(ok, false, 'a weapon that takes no ammunition at all is refused')
H.equal(#removals, 0, 'and keeps the magazine')

reset()
QbInventory.weaponCarry = { equippedWeapon = function() return { slot = 1, name = 'weapon_pistol' } end }
ok, err = useables.rifle_ammo(7, { name = 'rifle_ammo', slot = 4 })
H.equal(ok, false, 'a mismatched ammo type is refused')
H.ok(type(err) == 'string' and err:find('Pistol'), 'naming the weapon that refused it')
H.equal(#removals, 0, 'and keeps the magazine')

reset()
QbInventory.weaponCarry = nil
ok, err = useables.pistol_ammo(7, { name = 'pistol_ammo', slot = 4 })
H.equal(ok, false, 'with weaponcarry absent there is no equipped record to trust, so it refuses')
H.equal(#removals, 0, 'rather than consuming a magazine for no effect')

-- --- the happy path ---------------------------------------------------------

reset()
QbInventory.weaponCarry = { equippedWeapon = function() return { slot = 1, name = 'weapon_pistol' } end }
ok, err = useables.pistol_ammo(7, { name = 'pistol_ammo', slot = 4 })
H.equal(ok, true, 'a matching magazine loads')
H.equal(#removals, 1, 'exactly one magazine is consumed')
H.equal(removals[1].name, 'pistol_ammo', 'the magazine that was used')
H.equal(removals[1].amount, 1, 'one at a time, whatever the stack size')
H.equal(removals[1].slot, 4, 'from the slot the client named')

H.equal(#pushed, 1, 'one client instruction')
H.equal(pushed[1].event, 'qbinventory:client:addAmmo', 'on the ammo channel')
H.equal(pushed[1].src, 7, 'to that player only')
H.equal(pushed[1].payload.weapon, 'weapon_pistol',
    'naming the weapon from the SERVER equipped record, never from the request')
H.equal(pushed[1].payload.rounds, 12, 'with the round count from the shared item definition')
H.equal(pushed[1].payload.maxAmmo,
    math.min(Config.qbinventory.weapons.maxAmmo, Config.qbinventory.weapons.ballistics.maxLoadedRounds),
    'and the configured weapon/ballistics ceiling')

-- A failed removal must not still tell the client to load rounds -- that would
-- be free ammunition every time a race or a stale slot lost the item.
reset()
removeResult = 'no such item'
ok, err = useables.pistol_ammo(7, { name = 'pistol_ammo', slot = 4 })
H.equal(ok, false, 'a failed removal fails the use')
H.equal(err, 'no such item', 'reporting the removal error unchanged')
H.equal(#pushed, 0, 'and never loads rounds it did not charge for')

H.finish()
