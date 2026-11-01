-- client/compat/ox.lua is the CLIENT half of the ox_inventory provider
-- identity. test/smoke/ox_adapter.lua covers the server half and
-- test/smoke/export_collisions.lua guards how this file registers itself; this
-- one covers what it actually RETURNS.
--
-- Every divergence asserted below was live: the numeric Search mode was
-- inverted, a one-element array was not treated as single, `strict` did not
-- exist so metadata matching was always exact, GetSlotsWithItem returned {}
-- for an unknown item, and notify dropped `text` on the floor. Each is the
-- kind of break a stock ox dependant hits silently rather than loudly.
--
-- shared.lua is loaded for real rather than hand-mocked: QbInventory.sameInfo
-- and .totalWeight are load-bearing for the metadata and weight assertions,
-- and a mock of those primitives drifting from the real ones is exactly how
-- these bugs survived this long.
local H = dofile('test/harness.lua')

-- --- environment -----------------------------------------------------------

Config = { qbinventory = {} }
dofile('config.lua')
dofile('shared.lua')

local session = nil

local playerItems = {
    [1] = { slot = 1, name = 'water', amount = 2, weight = 10, info = { quality = 100 } },
    -- Sparse and out of ascending order on purpose: kora_core's items table is a
    -- slot-keyed map, so pairs() order over it is arbitrary.
    [4] = { slot = 4, name = 'water', amount = 3, weight = 10, info = { quality = 50, brand = 'ecola' } },
    [2] = { slot = 2, name = 'bread', amount = 1, weight = 20, info = { type = 'toast' } },
}

local sharedItemList = {
    water = { name = 'water', label = 'Water', weight = 10 },
    bread = { name = 'bread', label = 'Bread', weight = 20 },
    weapon_pistol = { name = 'weapon_pistol', label = 'Pistol', weight = 1000 },
}

local calls = { open = {}, intents = {}, notify = {}, progress = {} }

exports = setmetatable({}, {
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, exportName)
            return function(_, ...)
                if resource == 'kora_core' and exportName == 'getPlayerData' then
                    return { items = playerItems }
                elseif resource == 'kora_core' and exportName == 'getShared' then
                    -- Mirror the REAL contract: getShared(name, key) needs BOTH
                    -- arguments and returns registries[name].materialised[key].
                    -- A mock that returned the whole list for any call is how
                    -- `getShared('Items')` -- wrong registry name AND no key,
                    -- so nil unconditionally -- went unnoticed here.
                    local registry, key = ...
                    if registry ~= 'items' or key == nil then return nil end
                    return sharedItemList[key]
                elseif resource == 'kora_core' and exportName == 'allShared' then
                    -- The real allShared returns the DENSE ARRAY of records,
                    -- not a name-keyed map.
                    local registry = ...
                    if registry ~= 'items' then return {} end
                    local list = {}
                    for _, def in pairs(sharedItemList) do list[#list + 1] = def end
                    table.sort(list, function(a, b) return a.name < b.name end)
                    return list
                elseif resource == 'kora_inventory' and exportName == 'getCurrentSession' then
                    return session
                elseif resource == 'kora_inventory' and exportName == 'submitIntent' then
                    calls.intents[#calls.intents + 1] = ...
                    return true
                end
                return nil
            end
        end })
    end,
})

-- client.lua's explicit in-resource API. The compat table must call this,
-- never re-enter exports.kora_inventory:openInventory.
QbInventory.clientApi = {
    openInventory = function(invType, data) calls.open[#calls.open + 1] = { invType = invType, data = data } end,
    closeInventory = function() calls.closed = true end,
}

local progressResult, keyboardResult, progressActive = true, nil, false
local pedWeapon = 0
Kora = {
    compat = { provideExport = function(identity, name, fn)
        AddEventHandler(('__cfx_export_%s_%s'):format(identity, name), function(setCallback) setCallback(fn) end)
    end },
    cache = {
        weapon = function() return pedWeapon end,
    },
    notify = { send = function(payload) calls.notify[#calls.notify + 1] = payload end },
    progressbar = {
        start = function(payload) calls.progress[#calls.progress + 1] = payload; return progressResult end,
        cancel = function() calls.cancelled = true; return true end,
        isActive = function() return progressActive end,
    },
    nui = {
        openInputDialog = function(fields, title)
            calls.dialog = { fields = fields, title = title }
            return keyboardResult
        end,
    },
}

-- Natives getCurrentWeapon reaches for. GetHashKey only needs to be injective
-- over the names used here.
function PlayerPedId() return 1 end
function GetSelectedPedWeapon() return pedWeapon end
function GetHashKey(name) local h = 0; for i = 1, #name do h = (h * 31 + name:byte(i)) % 2 ^ 31 end return h end
joaat = GetHashKey

-- The compat file publishes ONLY through the ox_inventory export identity.
-- Capturing it this way asserts the registration path itself, and leaving
-- `exports` non-callable means an accidental exports(name, fn) would error
-- rather than pass quietly.
local Ox = {}
function AddEventHandler(eventName, handler)
    local exportName = eventName:match('^__cfx_export_ox_inventory_(.+)$')
    H.ok(exportName ~= nil, 'compat registers only under the ox_inventory identity')
    handler(function(fn) Ox[exportName] = fn end)
end

dofile('client/compat/ox.lua')

H.ok(Ox.Search ~= nil, 'the ox_inventory client surface was published')

-- --- Search ----------------------------------------------------------------
--
-- Upstream normalises 'slots'->1 / 'count'->2 then branches on the NUMBER, so
-- the numeric form is documented contract. This file branched on the string
-- alone, so a caller passing 1 (slots) received counts instead.

local slots = Ox.Search(1, 'water')
H.equal(type(slots), 'table', 'numeric Search mode 1 returns slots, not a count')
H.equal(#slots, 2, 'numeric slots mode returns every matching slot')
H.equal(slots[1].slot, 1, 'slots are ordered lowest-first despite sparse pairs() order')
H.equal(slots[2].slot, 4, 'second slot follows in ascending order')
H.equal(Ox.Search('slots', 'water')[1].slot, 1, 'the slots alias still resolves to mode 1')
H.equal(Ox.Search(2, 'water'), 5, 'numeric Search mode 2 sums counts across slots')
H.equal(Ox.Search('count', 'water'), 5, 'the count alias still resolves to mode 2')

-- Upstream measures #item AFTER wrapping a bare string, so a one-element ARRAY
-- is single too and returns the bare value rather than a name-keyed table.
H.equal(Ox.Search(2, { 'water' }), 5, 'a one-element array returns a bare value')
H.equal(#Ox.Search(1, { 'water' }), 2, 'a one-element array in slots mode returns a bare slot list')

local multi = Ox.Search('count', { 'water', 'bread' })
H.equal(multi.water, 5, 'a multi-item search returns a name-keyed table')
H.equal(multi.bread, 1, 'every requested name is keyed in a multi-item search')

-- An unknown name is NOT dropped by Search: upstream never consults the item
-- registry here, so it reports an empty list / 0 for it.
H.equal(Ox.Search('count', 'nonexistent'), 0, 'Search reports 0 for an unknown item')
H.equal(#Ox.Search('slots', 'nonexistent'), 0, 'Search reports an empty list for an unknown item')

H.equal(Ox.Search('nope', 'water'), false, 'an unrecognised search mode is false')
H.equal(Ox.Search(3, 'water'), false, 'an out-of-range numeric mode is false')
H.equal(Ox.Search(1, nil), false, 'a nil item list is false')

-- A string metadata is upstream shorthand for { type = <value> }.
H.equal(Ox.Search('count', 'bread', 'toast'), 1, 'a string metadata means { type = ... }')
H.equal(Ox.Search('count', 'bread', 'rye'), 0, 'a non-matching string metadata matches nothing')

-- --- strict / metadata matching --------------------------------------------
--
-- Upstream defaults to table.contains (partial) and only uses table.matches
-- (exact) when strict is passed. This file had no strict parameter at all and
-- always compared exactly, so a caller filtering on one key found nothing.

H.equal(Ox.GetItemCount('water', { quality = 50 }), 3,
    'strict defaults to partial metadata matching')
H.equal(Ox.GetItemCount('water', { quality = 50 }, true), 0,
    'strict = true requires an exact metadata match')
H.equal(Ox.GetItemCount('water', { quality = 50, brand = 'ecola' }, true), 3,
    'strict = true matches when every key is present and equal')
H.equal(#Ox.GetSlotsWithItem('water', { quality = 50 }), 1,
    'GetSlotsWithItem takes strict and defaults to partial')
H.equal(#Ox.GetSlotsWithItem('water', { quality = 50 }, true), 0,
    'GetSlotsWithItem honours strict = true')
H.equal(Ox.GetSlotWithItem('water', { brand = 'ecola' }).slot, 4,
    'GetSlotWithItem takes strict and defaults to partial')
H.equal(Ox.GetSlotIdWithItem('water', { brand = 'ecola' }), 4,
    'GetSlotIdWithItem takes strict and defaults to partial')
H.equal(Ox.GetItemCount('water'), 5, 'no metadata counts every slot')

-- --- unknown item name ------------------------------------------------------
--
-- Upstream gates these on Items(itemName) and distinguishes "no such item"
-- from "known item, none held". Returning {} for both made the documented
-- `if not GetSlotsWithItem(x) then` guard never fire.

H.equal(Ox.GetSlotsWithItem('nonexistent'), nil, 'GetSlotsWithItem is nil for an unknown item')
H.equal(type(Ox.GetSlotsWithItem('weapon_pistol')), 'table',
    'GetSlotsWithItem is an empty table for a known item the player has none of')
H.equal(#Ox.GetSlotsWithItem('weapon_pistol'), 0, 'the empty list really is empty')
H.equal(Ox.GetSlotWithItem('nonexistent'), nil, 'GetSlotWithItem is nil for an unknown item')
H.equal(Ox.GetSlotIdWithItem('nonexistent'), nil, 'GetSlotIdWithItem is nil for an unknown item')
H.equal(Ox.GetItemCount('nonexistent'), 0, 'GetItemCount is 0 for an unknown item')
H.equal(Ox.GetSlotIdWithItem('WATER'), 1, 'item names are matched case-insensitively')

-- --- weight -----------------------------------------------------------------

H.equal(Ox.GetPlayerWeight(), 70, 'weight delegates to the shared totalWeight primitive')
-- The hardcoded 120000 was a guess that happened to match config; read the
-- real value so it cannot drift.
H.equal(Ox.GetPlayerMaxWeight(), Config.qbinventory.playerMaxWeight,
    'max weight falls back to the configured player capacity, not a literal')
session = { primary = { maxWeight = 42000 } }
H.equal(Ox.GetPlayerMaxWeight(), 42000, 'an open session supplies the authoritative capacity')
session = nil

-- --- notify -----------------------------------------------------------------
--
-- Upstream moves data.text onto data.description before notifying. kora_lib's
-- toast body field is `message`, so passing the ox payload through untouched
-- rendered a title-only notification and silently lost the text.

local original = { title = 'Inventory', text = 'Item added.', type = 'inform' }
Ox.notify(original)
local sent = calls.notify[#calls.notify]
H.equal(sent.message, 'Item added.', 'notify remaps text onto the notification body')
H.equal(sent.text, nil, 'the ox-only text field is not forwarded')
H.equal(sent.description, nil, 'the ox_lib description field is not forwarded either')
H.equal(sent.title, 'Inventory', 'the title survives the remap')
-- ox_lib's neutral variant is 'inform'; kora_lib validates against 'info' and
-- silently drops a payload whose type it does not recognise.
H.equal(sent.type, 'info', 'the inform notification type is translated to info')
H.equal(original.text, 'Item added.', 'the caller table is never mutated')

Ox.notify({ title = 'Hi', description = 'From ox_lib.' })
H.equal(calls.notify[#calls.notify].message, 'From ox_lib.', 'an ox_lib description also lands in the body')
Ox.notify({ title = 'Hi', text = 'Body', type = 'nonsense' })
H.equal(calls.notify[#calls.notify].type, nil, 'an unknown type is dropped rather than failing validation')
Ox.notify({ title = 'Hi', position = 'bottom' })
H.equal(calls.notify[#calls.notify].position, 'bottom-center', 'the ox bottom position maps to kora_lib bottom-center')
Ox.notify({ title = 'Hi', position = 'center-right' })
H.equal(calls.notify[#calls.notify].position, 'top-right', 'unsupported center-right retains its side without failing validation')

-- --- Progress ---------------------------------------------------------------
--
-- Upstream: `local success = lib.progressBar(options); if completed then
-- completed(not success) end`. The callback argument is CANCELLED, not
-- completed, and this file dropped the callback entirely.

local cancelledArg, calledBack = nil, false
progressResult = true
H.equal(Ox.Progress({ label = 'Doing', duration = 1000, disable = { move = true, mouse = true },
    anim = { dict = 'd', clip = 'c' } }, function(cancelled)
    calledBack, cancelledArg = true, cancelled
end), true, 'Progress reports completion')
H.ok(calledBack, 'the completion callback is invoked')
H.equal(cancelledArg, false, 'a completed bar calls back with cancelled = false')
local payload = calls.progress[#calls.progress]
H.equal(payload.label, 'Doing', 'the progress label is forwarded')
H.equal(payload.anim.clip, 'c', 'the ox anim clip is forwarded')
H.equal(payload.disable.move, true, 'supported disable flags are forwarded')
H.equal(payload.disable.mouse, nil, 'the unsupported mouse-disable flag is dropped')

progressResult = true
Ox.Progress({ label = 'Searching', duration = 1000,
    anim = { scenario = 'WORLD_HUMAN_WELDING' },
    prop = {
        { model = 'prop_tool', bone = 60309, pos = { x = 1, y = 2, z = 3 }, rot = { x = 4, y = 5, z = 6 }, rotOrder = 2 },
        { model = 'prop_light' },
    },
})
payload = calls.progress[#calls.progress]
H.equal(payload.anim, nil, 'an ox scenario is not also sent as an animation')
H.equal(payload.scenario.name, 'WORLD_HUMAN_WELDING', 'an ox scenario maps onto kora_lib scenario playback')
H.equal(#payload.props, 2, 'an ox prop array remains an array')
H.equal(payload.props[1].offset.x, 1, 'ox prop pos maps to kora_lib offset')
H.equal(payload.props[1].rotation.z, 6, 'ox prop rot maps to kora_lib rotation')
H.equal(payload.props[1].rotationOrder, 2, 'ox prop rotOrder maps to kora_lib rotationOrder')

Ox.Progress({ label = 'Holding', duration = 1000, prop = { model = 'prop_single' } })
payload = calls.progress[#calls.progress]
H.equal(#payload.props, 1, 'a single ox prop is wrapped for kora_lib')
H.equal(payload.props[1].model, 'prop_single')

progressResult = false
H.equal(Ox.Progress({ label = 'Doing', duration = 1000 }, function(cancelled) cancelledArg = cancelled end),
    false, 'Progress reports cancellation')
H.equal(cancelledArg, true, 'a cancelled bar calls back with cancelled = true')
H.equal(Ox.Progress({ label = 'Doing', duration = 1000 }), false, 'the callback stays optional')

progressActive = true
H.equal(Ox.ProgressActive(), true, 'ProgressActive reads kora_lib progressbar state, not a hardcoded false')
progressActive = false
H.equal(Ox.ProgressActive(), false, 'ProgressActive follows the live state back down')
Ox.CancelProgress()
H.ok(calls.cancelled, 'CancelProgress delegates to kora_lib')

-- --- Keyboard ---------------------------------------------------------------
--
-- Upstream is exports('Keyboard', lib.inputDialog): rows in, an array of
-- values positionally aligned with those rows out, nil on cancel.

keyboardResult = { values = { ['1'] = 'Bob', ['2'] = 7 } }
local answers = Ox.Keyboard('Give', { 'Name', { type = 'number', label = 'Amount', min = 1 } })
H.equal(answers[1], 'Bob', 'Keyboard returns values positionally, matching lib.inputDialog')
H.equal(answers[2], 7, 'every row keeps its position in the result')
H.equal(calls.dialog.title, 'Give', 'the heading becomes the dialog title')
H.equal(calls.dialog.fields[1].label, 'Name', 'a bare string row becomes a labelled text field')
H.equal(calls.dialog.fields[1].type, 'text', "ox_lib's input type maps onto a text field")
H.equal(calls.dialog.fields[2].type, 'number', 'a number row keeps its type')
keyboardResult = { cancelled = true }
H.equal(Ox.Keyboard('Give', { 'Name' }), nil, 'a cancelled dialog returns nil')
keyboardResult = nil
H.equal(Ox.Keyboard('Give', { 'Name' }), nil, 'a timed-out dialog returns nil')
keyboardResult = { values = { ['1'] = { 'medic', 'pilot' } } }
answers = Ox.Keyboard('Roles', { { type = 'multi-select', label = 'Roles', options = {
    { value = 'medic', label = 'Medic' }, { value = 'pilot', label = 'Pilot' },
} } })
H.equal(calls.dialog.fields[1].type, 'multiselect', 'ox multi-select remains multi-select')
H.equal(#answers[1], 2, 'the positional result preserves every selected value')

-- --- setStashTarget ---------------------------------------------------------
--
-- The old implementation wrote LocalPlayer.state 'ox:stashTarget', which
-- nothing in this resource ever read. `LocalPlayer` is deliberately NOT mocked
-- in this file so that a reintroduced state write errors here instead of
-- passing silently.

Ox.setStashTarget('policelocker', 'CID1')
Ox.openInventory('stash')
local opened = calls.open[#calls.open]
H.equal(opened.invType, 'stash', 'the stored stash target opens a stash')
H.equal(opened.data.id, 'policelocker', 'the stored stash id is read back, not dropped')
H.equal(opened.data.owner, 'CID1', 'the stored stash owner is read back too')
Ox.openInventory('stash', 'other')
H.equal(calls.open[#calls.open].data, 'other', 'an explicit id always wins over the stored target')
Ox.setStashTarget(nil)
Ox.openInventory('stash')
H.equal(calls.open[#calls.open].data, nil, 'a nil id clears the stored target')
Ox.openInventory('shop', 'ammunation')
H.equal(calls.open[#calls.open].invType, 'shop', 'other inventory types are passed straight through')
Ox.closeInventory()
H.ok(calls.closed, 'closeInventory calls the client.lua global')

-- --- getCurrentWeapon -------------------------------------------------------

pedWeapon = GetHashKey('weapon_unarmed')
H.equal(Ox.getCurrentWeapon(), nil, 'an unarmed ped has no current weapon')
pedWeapon = GetHashKey('weapon_pistol')
H.equal(Ox.getCurrentWeapon(), nil, 'a weapon the player does not own is not reported')
playerItems[6] = { slot = 6, name = 'weapon_pistol', amount = 1, weight = 1000,
    info = { serial = 'ABC', durability = 80 } }
local weapon = Ox.getCurrentWeapon()
H.equal(weapon and weapon.slot, 6, 'the equipped weapon resolves to the owned slot')
H.equal(weapon.info.durability, 80, 'the reported weapon carries its slot metadata')
playerItems[6] = nil
pedWeapon = 0

-- --- documented no-ops ------------------------------------------------------
--
-- These four have no backing subsystem in kora_inventory/kora_lib and each carries a
-- comment in client/compat/ox.lua saying which upstream feature it stands in
-- for and why nothing can back it. They must stay CALLABLE (an ox dependant
-- calling one must not error) and must stay COMMENTED, so a future reader
-- cannot mistake a stub for an implementation.
for _, name in ipairs({ 'displayMetadata', 'suppressItemNotifications', 'weaponWheel',
    'setGetPlayerNameMethod' }) do
    H.equal(type(Ox[name]), 'function', name .. ' is published and callable')
    H.equal(Ox[name]('anything'), nil, name .. ' is a no-op that tolerates its arguments')
end

local file = assert(io.open('client/compat/ox.lua', 'r'))
local source = file:read('*a')
file:close()
for _, name in ipairs({ 'displayMetadata', 'suppressItemNotifications', 'weaponWheel',
    'setGetPlayerNameMethod' }) do
    local before = source:sub(1, assert(source:find(name .. ' = function', 1, true)))
    H.ok(before:sub(-400):find('No backing subsystem', 1, true) ~= nil,
        name .. ' declares itself a deliberate no-op')
end
-- Comment lines are stripped first: setStashTarget's comment names the removed
-- state key on purpose, and matching that would defeat the check.
local code = source:gsub('%-%-[^\n]*', '')
H.ok(not code:find('LocalPlayer', 1, true), 'the dead ox:stashTarget state write is gone')

-- Items() returns ox-format definitions translated from kora's records.
local waterDef = Ox.Items('WATER')
H.equal(waterDef.name, 'water', 'client Items(name) resolves case-insensitively')
H.equal(waterDef.stack, true, 'client Items(name) carries ox stack flag')
H.equal(waterDef.client.image, 'water.png', 'client Items(name) has client.image')
H.equal(type(waterDef.server), 'table', 'client Items(name) has server table')
H.equal(Ox.Items('nope'), nil, 'client Items(unknown) is nil')
H.equal(Ox.Items().bread.client.image, 'bread.png', 'client Items() entries are ox-shaped')
H.equal(Ox.ItemList('bread').close, true, 'client ItemList(name) is ox-shaped')
H.equal(sharedItemList.water.client, nil, 'kora record untouched by translation')

H.finish()
