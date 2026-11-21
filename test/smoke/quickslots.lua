-- Quick slots are pointers, not storage. This covers the pure resolver in
-- shared/quickslots.lua (no FXServer needed) plus source-pattern coverage of
-- the client wiring, in the style of test/smoke/hotbar.lua.
local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local text = file:read('*a')
    file:close()
    return text
end

KoraInventory = nil
dofile('shared/quickslots.lua')
local qs = KoraInventory.quickSlots
H.ok(type(qs) == 'table' and type(qs.resolve) == 'function', 'resolver is exposed on KoraInventory.quickSlots')

local defs = {
    weapon_pistol = { type = 'weapon', weapontype = 'Pistol', ammotype = 'AMMO_PISTOL' },
    weapon_combatpistol = { type = 'weapon', weapontype = 'Pistol', ammotype = 'AMMO_PISTOL' },
    weapon_carbinerifle = { type = 'weapon', weapontype = 'Rifle', ammotype = 'AMMO_RIFLE' },
    weapon_bat = { type = 'weapon', weapontype = 'Melee' },
    pistol_ammo = { type = 'item', ammoType = 'AMMO_PISTOL', rounds = 12 },
    rifle_ammo = { type = 'item', ammoType = 'AMMO_RIFLE', rounds = 30 },
    phone = { type = 'item' },
    iphone = { type = 'item' },
    radio = { type = 'item' },
    bread = { type = 'item' },
}
local function getDef(name) return defs[name] end

local slotsConfig = {
    { id = 'weapon', label = 'Weapon', accepts = { type = 'weapon' }, key = '' },
    { id = 'ammo', label = 'Ammo', linkedTo = 'weapon', key = '' },
    { id = 'phone', label = 'Phone', accepts = { names = { 'phone', 'iphone', 'samsungphone' } }, key = '' },
    { id = 'radio', label = 'Radio', accepts = { names = { 'radio' } }, key = 'F5' },
}

local function byId(list)
    local map = {}
    for _, entry in ipairs(list) do map[entry.id] = entry end
    return map
end

local function resolve(items, opts, config)
    opts = opts or {}
    opts.getDef = opts.getDef or getDef
    opts.playerSlots = opts.playerSlots or 41
    return qs.resolve(items, config or slotsConfig, opts)
end

-- Order, labels, keys and the unresolved shape.
local empty = resolve({})
H.equal(#empty, 4, 'one entry per configured quick slot')
H.equal(empty[1].id, 'weapon', 'results keep config order')
H.equal(empty[4].id, 'radio', 'results keep config order (last)')
H.equal(empty[1].label, 'Weapon', 'label comes from config')
H.equal(empty[4].key, 'F5', 'config key is returned')
H.equal(empty[1].key, '', 'unbound key is the empty string')
H.equal(empty[1].slot, nil, 'nothing owned -> unresolved')
H.equal(empty[1].pinned, false, 'unresolved is not pinned')
H.equal(resolve({}, { keys = { radio = 'G' } })[4].key, 'G', 'a currently bound key label overrides the config default')

-- Lowest matching slot, names are case-insensitive, other items ignored.
local items = {
    [2] = { name = 'bread', amount = 3, slot = 2 },
    [5] = { name = 'WEAPON_Carbinerifle', amount = 1, slot = 5, info = { serial = 'R1' } },
    [3] = { name = 'weapon_pistol', amount = 1, slot = 3, info = { serial = 'P1' } },
    [7] = { name = 'IPhone', amount = 1, slot = 7 },
    [9] = { name = 'phone', amount = 1, slot = 9 },
    [11] = { name = 'radio', amount = 1, slot = 11 },
}
local r = byId(resolve(items))
H.equal(r.weapon.slot, 3, 'weapon resolves to the lowest weapon slot')
H.equal(r.weapon.name, 'weapon_pistol', 'resolved name is the item name')
H.equal(r.weapon.pinned, false, 'unpinned resolution is not flagged pinned')
H.equal(r.phone.slot, 7, 'phone filter is case-insensitive and picks the lowest match')
H.equal(r.phone.name, 'IPhone', 'the real item name is reported unchanged')
H.equal(r.radio.slot, 11, 'radio resolves by name')

-- Slots above playerSlots are ignored.
local limited = byId(resolve(items, { playerSlots = 6 }))
H.equal(limited.weapon.slot, 3, 'slots within playerSlots still resolve')
H.equal(limited.phone.slot, nil, 'slots above playerSlots are ignored')
H.equal(limited.radio.slot, nil, 'slots above playerSlots are ignored (radio)')

-- Equipped weapon beats the lowest slot.
local equipped = byId(resolve(items, { equippedSlot = 5 }))
H.equal(equipped.weapon.slot, 5, 'the drawn weapon wins over the lowest weapon slot')
-- An equipped slot that does not match the filter is ignored.
H.equal(byId(resolve(items, { equippedSlot = 2 })).weapon.slot, 3, 'a non-matching equipped slot is ignored')
H.equal(byId(resolve(items, { equippedSlot = 40 })).weapon.slot, 3, 'an empty equipped slot is ignored')
H.equal(byId(resolve(items, { equippedSlot = 8, playerSlots = 6 })).weapon.slot, 3, 'equipped slot outside playerSlots is ignored')
-- Equipped priority does not apply to non-weapon slots.
H.equal(byId(resolve(items, { equippedSlot = 9 })).phone.slot, 7, 'equipped priority is for weapon slots only')

-- Pins: name pin, pin wins over equipped and lowest.
local pinned = byId(resolve(items, {
    equippedSlot = 5,
    pins = { weapon = { name = 'weapon_pistol' }, phone = { name = 'phone' } },
}))
H.equal(pinned.weapon.slot, 3, 'a pin wins over the equipped weapon')
H.equal(pinned.weapon.pinned, true, 'a pinned resolution is flagged')
H.equal(pinned.phone.slot, 9, 'a pin wins over the lowest matching slot')
H.equal(pinned.phone.pinned, true, 'phone pin flagged')
H.equal(pinned.radio.pinned, false, 'unpinned slot not flagged')

-- A pin whose item is gone falls back to normal resolution.
local stale = byId(resolve(items, { pins = { weapon = { name = 'weapon_smg' }, phone = { name = 'samsungphone' } } }))
H.equal(stale.weapon.slot, 3, 'a missing pinned item falls back to the lowest slot')
H.equal(stale.weapon.pinned, false, 'fallback is not flagged pinned')
H.equal(stale.phone.slot, 7, 'a pin on an item no longer owned falls back')
-- A pin that no longer matches the slot's filter is ignored.
H.equal(byId(resolve(items, { pins = { phone = { name = 'bread' } } })).phone.slot, 7, 'a pin outside the slot filter is ignored')

-- Serial pins.
local twoPistols = {
    [2] = { name = 'weapon_pistol', amount = 1, slot = 2, info = { serial = 'AAA' } },
    [6] = { name = 'weapon_pistol', amount = 1, slot = 6, info = { serial = 'BBB' } },
}
local serial = byId(resolve(twoPistols, { pins = { weapon = { name = 'weapon_pistol', serial = 'BBB' } } }))
H.equal(serial.weapon.slot, 6, 'a serial pin picks the matching serial, not the lowest slot')
H.equal(serial.weapon.pinned, true, 'serial pin flagged')
local gone = byId(resolve(twoPistols, { pins = { weapon = { name = 'weapon_pistol', serial = 'ZZZ' } } }))
H.equal(gone.weapon.slot, 2, 'a serial pin with no match falls back to the lowest slot')
H.equal(gone.weapon.pinned, false, 'serial-pin fallback is not flagged')
local moved = {
    [30] = { name = 'weapon_pistol', amount = 1, slot = 30, info = { serial = 'BBB' } },
    [1] = { name = 'weapon_pistol', amount = 1, slot = 1, info = { serial = 'AAA' } },
}
H.equal(byId(resolve(moved, { pins = { weapon = { name = 'weapon_pistol', serial = 'BBB' } } })).weapon.slot, 30,
    'a serial pin follows the item when it moves to another slot')

-- Two weapon quick slots never share a weapon unless pinned.
local weaponConfig = {
    { id = 'weapon', label = 'Weapon', accepts = { type = 'weapon' } },
    { id = 'sidearm', label = 'Sidearm', accepts = { type = 'weapon', weapontype = 'Pistol' } },
}
local arsenal = {
    [1] = { name = 'weapon_pistol', amount = 1, slot = 1, info = { serial = 'P1' } },
    [2] = { name = 'weapon_combatpistol', amount = 1, slot = 2, info = { serial = 'P2' } },
    [4] = { name = 'weapon_carbinerifle', amount = 1, slot = 4, info = { serial = 'R1' } },
}
local pair = byId(resolve(arsenal, nil, weaponConfig))
H.equal(pair.weapon.slot, 1, 'first weapon slot takes the lowest weapon')
H.equal(pair.sidearm.slot, 2, 'the sidearm slot does not duplicate the weapon slot')
local solo = byId(resolve({ [1] = arsenal[1] }, nil, weaponConfig))
H.equal(solo.weapon.slot, 1, 'a single pistol is taken by the weapon slot')
H.equal(solo.sidearm.slot, nil, 'the sidearm slot stays empty rather than duplicating the weapon')
local drawnRifle = byId(resolve(arsenal, { equippedSlot = 4 }, weaponConfig))
H.equal(drawnRifle.weapon.slot, 4, 'the drawn rifle is shown in the weapon slot')
H.equal(drawnRifle.sidearm.slot, 1, 'the sidearm filter then takes the lowest pistol')
local drawnPistol = byId(resolve(arsenal, { equippedSlot = 2 }, weaponConfig))
H.equal(drawnPistol.weapon.slot, 2, 'the drawn pistol goes to the first weapon slot that accepts it')
H.equal(drawnPistol.sidearm.slot, 1, 'the sidearm slot takes another pistol, not the drawn one')
local dup = byId(resolve(arsenal, { pins = {
    weapon = { name = 'weapon_pistol' }, sidearm = { name = 'weapon_pistol' },
} }, weaponConfig))
H.equal(dup.weapon.slot, 1, 'weapon pin resolves')
H.equal(dup.sidearm.slot, 1, 'the same weapon may be pinned into two quick slots explicitly')
-- A pin is honoured even if an earlier unpinned slot would have taken that weapon.
local sidePin = byId(resolve(arsenal, { pins = { sidearm = { name = 'weapon_pistol', serial = 'P1' } } }, weaponConfig))
H.equal(sidePin.sidearm.slot, 1, 'a sidearm pin claims its weapon')
H.equal(sidePin.weapon.slot, 2, 'the unpinned weapon slot avoids a weapon pinned elsewhere')
-- weapontype filter.
H.equal(byId(resolve({ [4] = arsenal[4] }, nil, weaponConfig)).sidearm.slot, nil, 'weapontype filter rejects other weapon types')

-- Linked ammo: totals across slots, resolved from the weapon's ammotype.
local loaded = {
    [3] = { name = 'weapon_pistol', amount = 1, slot = 3, info = { serial = 'P1' } },
    [4] = { name = 'rifle_ammo', amount = 5, slot = 4 },
    [8] = { name = 'pistol_ammo', amount = 2, slot = 8 },
    [6] = { name = 'pistol_ammo', amount = 4, slot = 6 },
    [12] = { name = 'weapon_carbinerifle', amount = 1, slot = 12 },
}
local ammo = byId(resolve(loaded))
H.equal(ammo.weapon.slot, 3, 'pistol is the lowest weapon')
H.equal(ammo.ammo.slot, 6, 'linked ammo resolves to the lowest matching ammo slot')
H.equal(ammo.ammo.name, 'pistol_ammo', 'linked ammo reports the ammo item name')
H.equal(ammo.ammo.total, 6, 'linked ammo total sums every slot of that ammo')
H.equal(ammo.ammo.pinned, false, 'linked ammo is never pinned')
H.equal(ammo.weapon.total, nil, 'plain slots carry no total')
-- The ammo follows the drawn weapon.
local rifle = byId(resolve(loaded, { equippedSlot = 12 }))
H.equal(rifle.weapon.slot, 12, 'drawn rifle selected')
H.equal(rifle.ammo.slot, 4, 'ammo follows the drawn weapon (rifle ammo)')
H.equal(rifle.ammo.total, 5, 'rifle ammo total')
-- Pins on a linked slot are ignored.
H.equal(byId(resolve(loaded, { pins = { ammo = { name = 'rifle_ammo' } } })).ammo.name, 'pistol_ammo', 'a linked slot cannot be pinned')
-- Stacks count their amount; missing amount counts as one.
local stacks = byId(resolve({
    [1] = { name = 'weapon_pistol', slot = 1 },
    [2] = { name = 'pistol_ammo', slot = 2 },
    [3] = { name = 'pistol_ammo', count = 3, slot = 3 },
}))
H.equal(stacks.ammo.total, 4, 'a missing amount counts as one and count is accepted')

-- Missing ammo, weapon with no ammotype, no weapon, ammo of another type.
local noAmmo = byId(resolve({ [1] = { name = 'weapon_pistol', amount = 1, slot = 1 } }))
H.equal(noAmmo.weapon.slot, 1, 'weapon resolved without ammo')
H.equal(noAmmo.ammo.slot, nil, 'no matching ammo -> linked slot unresolved')
H.equal(noAmmo.ammo.total, nil, 'no matching ammo -> no total')
local wrongAmmo = byId(resolve({
    [1] = { name = 'weapon_pistol', amount = 1, slot = 1 },
    [2] = { name = 'rifle_ammo', amount = 9, slot = 2 },
}))
H.equal(wrongAmmo.ammo.slot, nil, 'ammo of a different type is not linked')
local melee = byId(resolve({
    [1] = { name = 'weapon_bat', amount = 1, slot = 1 },
    [2] = { name = 'pistol_ammo', amount = 9, slot = 2 },
}))
H.equal(melee.weapon.slot, 1, 'melee weapon resolves')
H.equal(melee.ammo.slot, nil, 'a weapon with no ammotype has no linked ammo')
local unarmed = byId(resolve({ [2] = { name = 'pistol_ammo', amount = 9, slot = 2 } }))
H.equal(unarmed.weapon.slot, nil, 'no weapon owned')
H.equal(unarmed.ammo.slot, nil, 'no weapon -> linked ammo unresolved')
local brokenLink = byId(resolve(loaded, nil, { { id = 'ammo', label = 'Ammo', linkedTo = 'nope' } }))
H.equal(brokenLink.ammo.slot, nil, 'a link to an unknown slot id resolves nothing')

-- Robustness: nil or malformed input never errors, filterless slots match nothing.
H.equal(#qs.resolve(nil, nil, nil), 0, 'nil input yields an empty list')
local odd = byId(qs.resolve({ [1] = 'nope', [2] = { name = 5 }, [3] = { name = 'bread' } }, {
    { id = 'x', accepts = {} },
    { id = 'y' },
    { label = 'no id', accepts = { names = { 'bread' } } },
    { id = 'z', accepts = { names = { 'bread' } } },
}, { getDef = getDef, playerSlots = 10 }))
H.equal(odd.x.slot, nil, 'an empty filter matches nothing')
H.equal(odd.y.slot, nil, 'a missing filter matches nothing')
H.equal(odd.z.slot, 3, 'malformed items are skipped')
H.equal(odd.x.label, 'x', 'label falls back to the id')
H.equal(byId(qs.resolve({ [4] = { name = 'phone', amount = 1 } }, slotsConfig, { getDef = getDef })).phone.slot, 4,
    'playerSlots defaults to the highest occupied slot')
-- Items without a definition never match a type filter but can match names.
H.equal(byId(resolve({ [1] = { name = 'weapon_unknown', amount = 1 } }, { getDef = function() return nil end })).weapon.slot,
    nil, 'a missing definition cannot satisfy a type filter')
H.ok(qs.matches({ names = { 'Radio' } }, { name = 'radio' }, nil), 'names do not need a definition')
H.ok(not qs.matches(nil, { name = 'radio' }, nil), 'no filter never matches')

-- The resolver never mutates its input.
local before = items[3].name
resolve(items, { equippedSlot = 3 })
H.equal(items[3].name, before, 'resolving does not touch the items')

-- Config defaults.
Config = {}
dofile('config.lua')
local cfg = Config.kora_inventory.quickSlots
H.ok(type(cfg) == 'table', 'config exposes quickSlots')
H.equal(cfg.enabled, true, 'quick slots default on')
H.equal(cfg.hideWhenMissing, true, 'hideWhenMissing defaults on')
H.equal(cfg.showKeyHints, true, 'showKeyHints defaults on')
H.equal(cfg.inHotbarHud, true, 'inHotbarHud defaults on')
H.equal(cfg.reloadFromPockets, true, 'reloadFromPockets defaults on')
local ids = {}
for _, slot in ipairs(cfg.slots) do
    ids[slot.id] = slot
    H.equal(slot.key, '', 'default keys are unbound: ' .. slot.id)
end
H.equal(ids.weapon.accepts.type, 'weapon', 'default weapon slot accepts weapons')
H.equal(ids.ammo.linkedTo, 'weapon', 'default ammo slot is linked to the weapon slot')
H.equal(ids.phone.accepts.names[1], 'phone', 'default phone slot accepts phone items')
H.equal(ids.radio.accepts.names[1], 'radio', 'default radio slot accepts the radio')
-- The shipped defaults resolve with the pure function.
H.equal(#qs.resolve({}, cfg.slots, { playerSlots = Config.kora_inventory.playerSlots }), #cfg.slots, 'default config resolves')

-- --- run the client module against stubs --------------------------------------
local function runClient(quickConfig, playerData, drawnSlot)
    local env = { handlers = {}, sent = {}, kvp = {}, keybinds = {}, objects = {}, used = {}, threads = 0 }
    Config = { kora_inventory = { playerSlots = 41, quickSlots = quickConfig } }
    local dataChange
    exports = { kora_core = {
        getPlayerData = function() return playerData end,
        getShared = function(_, kind, name)
            return defs[name]
        end,
        onPlayerDataChange = function(_, _, fn) dataChange = fn end,
    } }
    env.dataChange = function() dataChange() end
    KoraInventory = {
        quickSlots = qs,
        ui = { send = function(action, data) env.sent[#env.sent + 1] = { action = action, data = data } end },
        getDrawnWeaponSlot = function() return env.drawn end,
        useSlot = function(slot) env.used[#env.used + 1] = slot end,
    }
    env.drawn = drawnSlot
    Kora = { keybind = { add = function(options)
        env.keybinds[options.name] = options
        return { getCurrentBinding = function() return env.binding end }
    end } }
    json = {
        encode = function(value) env.objects[#env.objects + 1] = value; return 'obj:' .. #env.objects end,
        decode = function(text) return env.objects[tonumber(text:match('^obj:(%d+)$'))] end,
    }
    GetResourceKvpString = function(key) return env.kvp[key] end
    SetResourceKvp = function(key, value) env.kvp[key] = value end
    DeleteResourceKvp = function(key) env.kvp[key] = nil end
    AddEventHandler = function(name, fn) env.handlers[name] = fn end
    RegisterNetEvent = AddEventHandler
    CreateThread = function(fn) env.thread = fn end
    Wait = function() end
    dofile('client/quickslots.lua')
    return env
end

local function fresh(slots)
    return {
        enabled = true, hideWhenMissing = true, showKeyHints = true, inHotbarHud = true,
        slots = slots or slotsConfig,
    }
end
local function sentOf(env, index)
    return env.sent[index or #env.sent]
end

local player = {
    citizenid = 'ABC123',
    items = {
        [2] = { name = 'weapon_pistol', amount = 1, slot = 2, label = 'Pistol', info = { serial = 'S-2' } },
        [5] = { name = 'weapon_combatpistol', amount = 1, slot = 5, label = 'Combat Pistol', info = { serial = 'S-5' } },
        [6] = { name = 'pistol_ammo', amount = 3, slot = 6, label = 'Pistol Ammo' },
        [9] = { name = 'pistol_ammo', amount = 4, slot = 9, label = 'Pistol Ammo' },
        [10] = { name = 'bread', amount = 2, slot = 10, label = 'Bread' },
    },
}

local env = runClient(fresh(), player, nil)
H.ok(env.keybinds['kora_inventory:quick_weapon'] and env.keybinds['kora_inventory:quick_ammo']
    and env.keybinds['kora_inventory:quick_phone'] and env.keybinds['kora_inventory:quick_radio'],
    'one rebindable keybind per quick slot: kora_inventory:quick_<id>')
H.equal(env.keybinds['kora_inventory:quick_weapon'].defaultKey, '', 'keys are unbound by default')
H.equal(env.keybinds['kora_inventory:quick_weapon'].description, 'Quick slot: Weapon', 'binding description names the slot')
H.equal(env.keybinds['kora_inventory:quick_weapon'].defaultMapper, 'keyboard', 'keyboard mapper')

local api = KoraInventory.quickSlotsClient
api.push(true)
local message = sentOf(env)
H.equal(message.action, 'kora_inventory:nui:quickSlots', 'push sends the NUI quickSlots message')
H.equal(message.data.enabled, true, 'enabled flag')
H.equal(message.data.hideWhenMissing, true, 'hideWhenMissing flag')
H.equal(message.data.showKeyHints, true, 'showKeyHints flag')
H.equal(message.data.drawer.startCollapsed, false, 'drawer starts expanded by default')
H.equal(#message.data.slots, 4, 'one entry per quick slot')
H.equal(message.data.slots[1].slot, 2, 'weapon resolved to the lowest weapon slot')
H.equal(message.data.slots[2].slot, 6, 'ammo resolved')
H.equal(message.data.slots[2].total, 7, 'ammo total across stacks')
H.equal(message.data.slots[2].linked, true, 'linked flag marks the ammo slot')
H.equal(message.data.slots[1].linked, false, 'plain slot is not linked')
H.equal(message.data.slots[1].key, '', 'unbound key is an empty string')
env.binding = 'F7'
api.push()
H.equal(sentOf(env).data.slots[1].key, 'F7', 'the bound key label comes from the live key mapping')

-- Unchanged results are not re-sent; a change is.
local count = #env.sent
api.push()
H.equal(#env.sent, count, 'an unchanged resolution is not re-sent')
env.drawn = 5
env.handlers['kora_inventory:client:weaponDrawnChanged']()
H.equal(sentOf(env).data.slots[1].slot, 5, 'a drawn-weapon change re-resolves and re-sends')
env.dataChange()
H.equal(#env.sent, count + 1, 'an items change with the same resolution is not re-sent')
player.items[11] = { name = 'radio', amount = 1, slot = 11, label = 'Radio' }
env.dataChange()
H.equal(sentOf(env).data.slots[4].slot, 11, 'an items change re-resolves and re-sends')
env.drawn = nil

-- Pinning.
local ok, err = api.pin({ id = 'weapon', slot = 5 })
H.ok(ok and err == nil, 'pinning a matching item succeeds')
H.equal(sentOf(env).data.slots[1].slot, 5, 'a pin change re-sends the quick slots')
H.equal(sentOf(env).data.slots[1].pinned, true, 'the pin is reflected')
local saved = env.kvp['kora_inventory:quickslots:ABC123']
H.ok(saved, 'the pin is stored in client KVP under the character id')
H.equal(env.objects[tonumber(saved:match('%d+'))].weapon.serial, 'S-5', 'the serial is stored with the pin')
-- A moved item keeps its pin (serial follows the item).
player.items[20] = player.items[5]; player.items[5] = nil; player.items[20].slot = 20
env.dataChange()
H.equal(sentOf(env).data.slots[1].slot, 20, 'the pin follows the item to its new slot')
-- Refusals.
local function refused(body, why)
    local good, reason = api.pin(body)
    H.equal(good, false, why)
    return reason
end
H.equal(refused({ id = 'nope', slot = 2 }, 'unknown id refused'), 'unknown quick slot', 'unknown id reason')
H.equal(refused({ id = 'ammo', slot = 6 }, 'linked slot refused'), 'quick slot cannot be pinned', 'linked slots cannot be pinned')
refused({ id = 'weapon', slot = 10 }, 'item not matching the filter refused')
refused({ id = 'weapon', slot = 30 }, 'empty slot refused')
refused({ id = 'weapon', slot = 42 }, 'slot above playerSlots refused')
refused({ id = 'weapon', slot = -1 }, 'negative slot refused')
refused({ id = 'weapon', slot = 2.5 }, 'fractional slot refused')
refused({ id = 'weapon', slot = '2' }, 'string slot refused')
refused({ id = 7, slot = 2 }, 'non-string id refused')
refused('weapon', 'non-table body refused')
H.equal(sentOf(env).data.slots[1].slot, 20, 'refused pins change nothing')
-- Unpin with nil and with 0.
H.ok(api.pin({ id = 'weapon' }), 'nil slot unpins')
H.equal(sentOf(env).data.slots[1].pinned, false, 'unpinned')
H.equal(env.kvp['kora_inventory:quickslots:ABC123'], nil, 'an empty pin set deletes the KVP entry')
api.pin({ id = 'weapon', slot = 20 })
H.ok(api.pin({ id = 'weapon', slot = 0 }), 'slot 0 unpins')
-- No character -> no pinning.
local noChar = runClient(fresh(), { items = player.items }, nil)
local good, why = KoraInventory.quickSlotsClient.pin({ id = 'weapon', slot = 2 })
H.ok(not good and why == 'no character', 'pins need a character id')
-- Pins from KVP are sanitised.
local seeded = runClient(fresh(), player, nil)
seeded.kvp['kora_inventory:quickslots:ABC123'] = 'obj:1'
seeded.objects[1] = { weapon = { name = 'weapon_combatpistol', serial = 20 }, ammo = { name = 'rifle_ammo' }, bogus = { name = 'x' } }
KoraInventory.quickSlotsClient.push(true)
local seededSlots = sentOf(seeded).data.slots
H.equal(seededSlots[1].slot, 20, 'a stored pin with a bad serial type still resolves by name')
H.equal(seededSlots[2].pinned, false, 'a stored pin on a linked slot is ignored')

-- Hotkeys use the hotbar path with the resolved real slot, and nothing else.
local keys = runClient(fresh(), player, nil)
keys.keybinds['kora_inventory:quick_weapon'].onPressed()
keys.keybinds['kora_inventory:quick_ammo'].onPressed()
H.equal(keys.used[1], 2, 'the weapon key uses the resolved weapon slot via the hotbar path')
H.equal(keys.used[2], 6, 'the ammo key uses the resolved ammo slot via the hotbar path')
keys.keybinds['kora_inventory:quick_phone'].onPressed()
H.equal(#keys.used, 2, 'an unresolved quick slot does nothing')

-- Hotbar HUD payload.
local hud = KoraInventory.quickSlotsClient.hud()
H.equal(#hud, 3, 'only resolved quick slots (weapon, ammo, radio) reach the hotbar HUD')
H.equal(hud[1].id, 'weapon', 'hud entry id')
H.equal(hud[1].slot, 2, 'hud entry slot')
H.equal(hud[1].name, 'weapon_pistol', 'hud entry item name')
H.equal(hud[1].label, 'Pistol', 'hud entry item label')
H.equal(hud[1].slotLabel, 'Weapon', 'hud entry quick slot label')
H.equal(hud[2].amount, 7, 'hud ammo amount is the total')
local noHud = runClient({ enabled = true, inHotbarHud = false, slots = slotsConfig }, player, nil)
H.equal(KoraInventory.quickSlotsClient.hud(), nil, 'inHotbarHud = false omits the quick list')

-- Disabled: nothing registered, one { enabled = false }.
local off = runClient({ enabled = false, slots = slotsConfig }, player, nil)
H.equal(next(off.keybinds), nil, 'disabled registers no keybinds')
H.equal(off.handlers['kora_inventory:client:weaponDrawnChanged'], nil, 'disabled registers no handlers')
off.thread()
H.equal(#off.sent, 1, 'disabled sends exactly one message')
H.equal(off.sent[1].action, 'kora_inventory:nui:quickSlots', 'disabled message action')
H.equal(off.sent[1].data.enabled, false, 'disabled message carries enabled = false')
H.equal(next(off.sent[1].data, 'enabled'), nil, 'disabled message carries nothing else')
H.equal(KoraInventory.quickSlotsClient.pin, nil, 'disabled exposes no pin function')

-- Bad ids are dropped rather than becoming command names.
local badIds = runClient(fresh({ { id = 'a b', label = 'x', accepts = { names = { 'bread' } } },
    { id = 'ok_1', label = 'ok', accepts = { names = { 'bread' } } }, { id = 'ok_1', label = 'dup', accepts = { names = { 'bread' } } } }), player, nil)
H.ok(badIds.keybinds['kora_inventory:quick_ok_1'] and not badIds.keybinds['kora_inventory:quick_a b'], 'only well-formed ids get a keybind')

-- --- wiring (source patterns) ------------------------------------------------
local manifest = read('fxmanifest.lua')
local client = read('client/quickslots.lua')
local hotbar = read('client/hotbar.lua')
local ui = read('client/ui.lua')
local weaponcarry = read('client/weaponcarry.lua')

local sharedAt = manifest:find("'shared.lua'", 1, true)
local qsShared = manifest:find("'shared/quickslots.lua'", 1, true)
H.ok(sharedAt and qsShared and qsShared > sharedAt, 'the resolver is a shared script loaded after shared.lua')
local hotbarAt = manifest:find("'client/hotbar.lua'", 1, true)
local qsClient = manifest:find("'client/quickslots.lua'", 1, true)
H.ok(hotbarAt and qsClient and qsClient > hotbarAt, 'client/quickslots.lua loads after client/hotbar.lua')

-- Hotkeys share the hotbar use path and add no server event.
H.ok(hotbar:find('function KoraInventory.useSlot(slot)', 1, true), 'hotbar exposes its use path for reuse')
H.ok(client:find('KoraInventory.useSlot(', 1, true), 'quick slot hotkeys use the hotbar use path')
H.ok(not client:find('TriggerServerEvent', 1, true), 'quick slots never talk to the server directly')
H.ok(not client:find('TriggerEvent%(%s*[\'"]kora_inventory:server'), 'quick slots forward nothing server-bound')
H.ok(client:find("'kora_inventory:quick_' .. ", 1, true) or client:find("kora_inventory:quick_%s", 1, true),
    'hotkey commands are named kora_inventory:quick_<id>')
H.ok(client:find('Kora.keybind.add({', 1, true), 'hotkeys use Kora.keybind like the hotbar keys')
H.ok(ui:find("RegisterNUICallback('kora_inventory:pinQuickSlot'", 1, true), 'the pin callback lives with the other NUI callbacks in ui.lua')
H.ok(not client:find('RegisterNUICallback', 1, true), 'quickslots.lua registers no NUI callback of its own')
H.ok(client:find('SetResourceKvp', 1, true) and client:find('GetResourceKvpString', 1, true), 'pins persist in client KVP')
H.ok(client:find('citizenid', 1, true), 'pins are keyed per character')
H.ok(client:find("'kora_inventory:nui:quickSlots'", 1, true), 'the NUI quickSlots message is sent')
H.ok(client:find('KoraInventory.ui', 1, true) and client:find('ui.send(action, data)', 1, true),
    'messages go through the ui bridge helper rather than SendNUIMessage')
H.ok(not client:find('SendNUIMessage', 1, true), 'quickslots.lua never calls SendNUIMessage directly')
H.ok(ui:find('KoraInventory.ui', 1, true), 'ui.lua exposes the bridge helper')
H.ok(ui:find('quick = ', 1, true) and ui:find('inHotbarHud', 1, true), 'the hotbar HUD payload carries resolved quick slots')
H.ok(weaponcarry:find('function KoraInventory.getDrawnWeaponSlot()', 1, true), 'weaponcarry exposes a read-only drawn slot getter')
H.ok(not weaponcarry:find('setDrawnWeapon', 1, true), 'no setter for the drawn weapon was added')

do
    local collapsedConfig = fresh()
    collapsedConfig.drawer = { startCollapsed = true }
    local collapsedEnv = runClient(collapsedConfig, player, nil)
    KoraInventory.quickSlotsClient.push(true)
    H.equal(sentOf(collapsedEnv).data.drawer.startCollapsed, true, 'drawer.startCollapsed is forwarded to the NUI')
end

H.finish()
