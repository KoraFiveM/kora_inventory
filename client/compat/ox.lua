-- ox_inventory client provider surface. All state is read from kora_core's
-- replicated mirror or kora_inventory's server-issued session; no browser state
-- is ever treated as inventory authority.
--
-- Behaviour is matched against ox_inventory's own src/modules/inventory/
-- client.lua, src/modules/interface/client.lua, src/modules/items/client.lua
-- and src/modules/utils/client.lua at the pinned upstream commit. Where a call
-- has no backing subsystem here it stays a no-op and SAYS SO in a comment -- a
-- stub that swallows its arguments while looking implemented is exactly how
-- the inverted Search mode and the missing `strict` argument below survived.
local inventoryApi = assert(QbInventory and QbInventory.clientApi, 'qbinventory client transport must load first')

local function playerData()
    return exports.kora_core:getPlayerData() or {}
end
local function items()
    return playerData().items or {}
end
-- kora_core's registry is named 'items' (lower-case, see kora_core
-- modules/registry/server.lua:12) and `getShared(name, key)` requires BOTH
-- arguments -- it returns registries[name].materialised[key]. So the previous
-- `getShared('Items')` resolved no registry AND supplied no key: it returned
-- nil unconditionally, and every lookup gated on it silently reported "no such
-- item". `allShared('items')` is the dense ARRAY of records, so the name-keyed
-- map upstream's Items() hands back has to be rebuilt from it.
local function itemDefByName(name)
    return exports.kora_core:getShared('items', name)
end
local function sharedItems()
    local out = {}
    for _, def in ipairs(exports.kora_core:allShared('items') or {}) do
        if type(def) == 'table' and type(def.name) == 'string' then
            out[def.name] = def
        end
    end
    return out
end

-- Upstream's Items(name) lookup. It matters because GetSlotWithItem /
-- GetSlotsWithItem / GetItemCount are gated on it and report "no such item"
-- (nil / nil / 0) differently from "item exists, you have none" (nil / {} / 0).
local function itemName(name)
    if type(name) == 'table' then
        name = name.name
    end
    return type(name) == 'string' and name:lower() or nil
end
local function itemDef(name)
    local key = itemName(name)
    -- Single-key lookup, never a full-map rebuild: this runs on every
    -- GetItemCount / GetSlotWithItem call.
    return key and itemDefByName(key) or nil
end

-- Upstream assertMetadata: a non-table metadata argument is shorthand for
-- { type = <value> }. Search applies the same rule to a string metadata.
local function normaliseMetadata(metadata)
    if metadata == nil then
        return nil
    end
    if type(metadata) == 'table' then
        return metadata
    end
    return { type = metadata }
end

-- Upstream matches metadata with table.contains (PARTIAL: every key of the
-- QUERY must be equal on the item, extra item keys are ignored) and only
-- switches to table.matches (exact, both directions) when `strict` is passed.
-- QbInventory.sameInfo is the exact form, so partial needs its own walk here.
-- This file had no `strict` parameter at all and always compared exactly, so
-- every ox caller filtering on a single metadata key silently found nothing.
local function metadataMatches(info, metadata, strict)
    if metadata == nil then
        return true
    end
    info = info or {}
    if strict then
        return QbInventory.sameInfo(info, metadata)
    end
    for key, value in pairs(metadata) do
        if info[key] ~= value then
            return false
        end
    end
    return true
end

local function slotsOf(name, metadata, strict)
    local key = itemName(name)
    local out = {}
    if not key then
        return out
    end
    for _, item in pairs(items()) do
        if itemName(item.name) == key and metadataMatches(item.info or item.metadata, metadata, strict) then
            out[#out + 1] = item
        end
    end
    -- Upstream does NOT sort: its inventory is a dense slot array, so pairs()
    -- already yields ascending slots. kora_core's items table is SPARSE, so
    -- pairs() order over it is genuinely arbitrary and GetSlotWithItem would
    -- return a different slot from one call to the next. Sorting restores the
    -- "lowest slot first" behaviour upstream gets for free.
    table.sort(out, function(a, b)
        return (a.slot or 0) < (b.slot or 0)
    end)
    return out
end

local function countOf(name, metadata, strict)
    local total = 0
    for _, item in ipairs(slotsOf(name, metadata, strict)) do
        total = total + (item.amount or item.count or 0)
    end
    return total
end

local function weight()
    return QbInventory.totalWeight(items())
end

local function maxWeight()
    local active = exports.kora_inventory:getCurrentSession()
    if active and active.primary and tonumber(active.primary.maxWeight) then
        return tonumber(active.primary.maxWeight)
    end
    -- With no session open the server has not issued a capacity yet. config.lua
    -- is a shared_script, so the authority's own default is readable here
    -- rather than guessed; the literal only covers a config.lua that failed to
    -- load, which would otherwise make this return nil to an ox caller.
    local config = Config and Config.qbinventory or {}
    return tonumber(config.playerMaxWeight) or 120000
end

-- Upstream normalises 'slots'->1 / 'count'->2 and then branches on the NUMBER,
-- so the documented numeric form is part of the contract. This file branched on
-- `kind == 'slots'` alone, which made a caller passing the documented 1 receive
-- COUNTS instead of slots -- a silent, hard break. Same normalisation as
-- server/compat/ox.lua's ox.Search.
local function search(kind, requested, metadata)
    if requested == nil then
        return false
    end
    if kind == 'slots' then
        kind = 1
    elseif kind == 'count' then
        kind = 2
    end
    if kind ~= 1 and kind ~= 2 then
        return false
    end
    local list = type(requested) == 'string' and { requested } or requested
    if type(list) ~= 'table' then
        return false
    end
    metadata = normaliseMetadata(metadata)
    -- Upstream measures `#item` AFTER wrapping a bare string, so a ONE-ELEMENT
    -- ARRAY is "single" too and returns the bare value rather than a
    -- name-keyed table. This file only treated a bare string as single.
    local requestedCount = #list
    local out = {}
    for index = 1, requestedCount do
        local key = itemName(list[index])
        -- Search deliberately does not consult the item registry upstream: an
        -- unknown name still gets an empty list / 0 rather than being dropped.
        if key then
            out[key] = kind == 1 and slotsOf(key, metadata, false) or countOf(key, metadata, false)
        end
    end
    if not next(out) then
        return false
    end
    if requestedCount == 1 then
        return out[itemName(list[1])]
    end
    return out
end

-- ox_lib's neutral notify variant is 'inform'; kora_lib's is 'info'. An
-- unrecognised type fails QB.notify.assert, which drops the whole toast
-- silently, so the vocabulary is translated rather than passed through.
local NOTIFY_TYPES = { info = true, success = true, warning = true, error = true }
local NOTIFY_POSITIONS = {
    top = 'top-center',
    bottom = 'bottom-center',
    ['top-left'] = 'top-left',
    ['top-right'] = 'top-right',
    ['bottom-left'] = 'bottom-left',
    ['bottom-right'] = 'bottom-right',
    ['center-left'] = 'top-left',
    ['center-right'] = 'top-right',
}

-- ox_lib inputDialog row types mapped onto QB.nui.openInputDialog field types.
-- Anything outside this set degrades to a text field rather than erroring,
-- matching how the qb-input compat shim in kora_lib handles unknown types.
local KEYBOARD_TYPES = {
    input = 'text',
    text = 'text',
    password = 'password',
    textarea = 'textarea',
    number = 'number',
    checkbox = 'checkbox',
    select = 'select',
    ['multi-select'] = 'multiselect',
}

local function progressProps(prop)
    if type(prop) ~= 'table' then
        return nil
    end
    local source = prop.model and { prop } or prop
    local mapped = {}
    for _, entry in ipairs(source) do
        if type(entry) == 'table' and entry.model ~= nil then
            mapped[#mapped + 1] = {
                model = entry.model,
                bone = entry.bone,
                offset = entry.pos or entry.offset,
                rotation = entry.rot or entry.rotation,
                rotationOrder = entry.rotOrder or entry.rotationOrder,
            }
        end
    end
    return #mapped > 0 and mapped or nil
end

-- Upstream keeps this in a plain local (src/client.lua:22); see setStashTarget.
local stashTarget

local ox = {
    -- Call client.lua's globals directly, NOT exports.kora_inventory:openInventory.
    -- This file used to re-enter the export while also registering itself into
    -- the same flat table below, so after load the export resolved back to this
    -- wrapper -- unbounded recursion on every stash/shop/evidence-locker open.
    openInventory = function(invType, data)
        -- Read back setStashTarget's stored target. Upstream does the same
        -- substitution from its secondary-inventory keybind (src/client.lua:819).
        if invType == 'stash' and data == nil and stashTarget then
            data = stashTarget
        end
        return inventoryApi.openInventory(invType, data)
    end,
    closeInventory = function()
        return inventoryApi.closeInventory()
    end,
    useSlot = function(slot)
        return exports.kora_inventory:submitIntent({ action = 'use', slot = slot })
    end,
    useItem = function(data, cb)
        local slot = type(data) == 'table' and data.slot or data
        local ok = exports.kora_inventory:submitIntent({ action = 'use', slot = slot })
        if cb then
            cb(ok)
        end
        return ok
    end,
    openNearbyInventory = function()
        return exports.kora_inventory:requestGiveTarget()
    end,
    giveItemToTarget = function(serverId, slot, count)
        return exports.kora_inventory:submitIntent({
            action = 'give',
            target = serverId,
            slot = slot,
            amount = count,
        })
    end,
    GetPlayerItems = function()
        return QbInventory.copy(items())
    end,
    GetPlayerWeight = weight,
    GetPlayerMaxWeight = maxWeight,
    -- (itemName, metadata, strict); strict defaults to PARTIAL metadata
    -- matching, which is upstream's default -- see metadataMatches above.
    GetItemCount = function(name, metadata, strict)
        if not itemDef(name) then
            return 0
        end
        return countOf(name, normaliseMetadata(metadata), strict)
    end,
    GetSlotWithItem = function(name, metadata, strict)
        if not itemDef(name) then
            return nil
        end
        return slotsOf(name, normaliseMetadata(metadata), strict)[1]
    end,
    GetSlotIdWithItem = function(name, metadata, strict)
        if not itemDef(name) then
            return nil
        end
        local item = slotsOf(name, normaliseMetadata(metadata), strict)[1]
        return item and item.slot
    end,
    -- Upstream returns nil for an item that does not exist at all and an empty
    -- table for a known item you happen to hold none of. Returning {} for both
    -- made `if not exports.ox_inventory:GetSlotsWithItem(bad) then` -- the
    -- documented unknown-item guard -- never fire.
    GetSlotsWithItem = function(name, metadata, strict)
        if not itemDef(name) then
            return nil
        end
        return slotsOf(name, normaliseMetadata(metadata), strict)
    end,
    Search = search,
    -- Lower-cased like every other lookup in this file: kora_core's shared items
    -- table is keyed lower-case, so `Items('WEAPON_PISTOL')` would otherwise
    -- miss while GetItemCount('WEAPON_PISTOL') resolves it fine.
    Items = function(name)
        return name and itemDef(name) or sharedItems()
    end,
    ItemList = function(name)
        return name and itemDef(name) or sharedItems()
    end,
    setStashTarget = function(id, owner)
        -- Upstream stores this in a local and its SECONDARY-inventory keybind
        -- opens it (src/client.lua:819). kora_inventory owns no secondary keybind
        -- -- client/compat.lua maps only the primary TAB open -- so the stored
        -- target is read back by openInventory('stash') with no id above,
        -- preserving the same "open the stash this resource pointed me at"
        -- contract for a caller. The previous LocalPlayer.state
        -- 'ox:stashTarget' write was read by NOTHING in this resource (grep
        -- confirms) and is not an upstream convention, so it is gone.
        stashTarget = id and { id = id, owner = owner } or nil
    end,
    -- No backing subsystem. Upstream pushes a metadata-key -> display-label map
    -- into its own NUI (src/modules/items/client.lua:51). kora_inventory's NUI
    -- wire contract (web/src/lib/types.ts) has no such message and renders raw
    -- metadata keys, so there is nothing to forward this to. Deliberate no-op.
    displayMetadata = function() end,
    -- No backing subsystem. kora_inventory's item receipts are SERVER-authored and
    -- gated server-side by Config.qbinventory.itemBoxes; the client only relays
    -- 'qbinventory:client:itemBox' (client/ui.lua). There is no client-side
    -- suppression switch to flip, and a local flag here would not stop the
    -- server deciding to emit. Deliberate no-op.
    suppressItemNotifications = function() end,
    notify = function(data)
        if type(data) ~= 'table' then
            return
        end
        -- Upstream (src/modules/utils/client.lua:Utils.Notify) moves `text`
        -- onto `description` before notifying; this file passed `data` straight
        -- to QB.notify.send, whose body field is `message`, so the notification
        -- rendered title-only and the text was silently lost. Both ox spellings
        -- are folded onto `message`. The caller's table is never mutated
        -- (upstream mutates it, which is its own small bug).
        local payload = QbInventory.copy(data)
        payload.message = payload.message or payload.description or payload.text
        payload.description, payload.text = nil, nil
        if payload.type == 'inform' then
            payload.type = 'info'
        end
        if payload.type ~= nil and not NOTIFY_TYPES[payload.type] then
            payload.type = nil
        end
        if payload.position ~= nil then
            payload.position = NOTIFY_POSITIONS[payload.position]
        end
        return QB.notify.send(payload)
    end,
    -- Upstream: `local success = lib.progressBar(options); if completed then
    -- completed(not success) end`. The callback argument is CANCELLED, not
    -- completed. Dropping it left every ox caller that does its work inside the
    -- callback doing nothing at all.
    Progress = function(options, completed)
        if type(options) ~= 'table' then
            return false
        end
        local disable = options.disable or {}
        local anim = options.anim
        local scenario = anim and anim.scenario
        local success = QB.progressbar.start({
            label = options.label,
            duration = options.duration,
            canCancel = options.canCancel,
            disable = { move = disable.move, combat = disable.combat, car = disable.car },
            -- ox names the clip `clip`; qb-progressbar callers say `anim`.
            anim = anim and not scenario and {
                dict = anim.dict,
                clip = anim.clip or anim.anim,
                flag = anim.flag,
                blendIn = anim.blendIn,
                blendOut = anim.blendOut,
            } or nil,
            scenario = scenario and { name = scenario } or nil,
            props = progressProps(options.prop or options.props),
        })
        success = success == true
        if completed then
            completed(not success)
        end
        return success
    end,
    ProgressActive = function()
        return QB.progressbar.isActive()
    end,
    CancelProgress = function()
        return QB.progressbar.cancel()
    end,
    -- Upstream is `exports('Keyboard', lib.inputDialog)`: (heading, rows) in,
    -- an array of values POSITIONALLY aligned with `rows` out, or nil on
    -- cancel. kora_lib's dialog is id-keyed, so the row index is used as the id
    -- and the result is re-flattened back into upstream's array shape.
    Keyboard = function(heading, rows)
        if type(rows) ~= 'table' then
            return nil
        end
        local fields = {}
        for index, row in ipairs(rows) do
            local spec = type(row) == 'table' and row or { label = tostring(row) }
            fields[index] = {
                id = tostring(index),
                label = spec.label or spec.placeholder or ('Field %d'):format(index),
                type = KEYBOARD_TYPES[spec.type or 'input'] or 'text',
                default = spec.default,
                placeholder = spec.placeholder,
                required = spec.required,
                min = spec.min,
                max = spec.max,
                options = spec.options,
            }
        end
        local result = QB.nui.openInputDialog(fields, heading)
        if type(result) ~= 'table' or result.cancelled or type(result.values) ~= 'table' then
            return nil
        end
        local out = {}
        for index = 1, #fields do
            out[index] = result.values[tostring(index)]
        end
        return out
    end,
    -- No backing subsystem. Upstream blocks the weapon wheel and pickup rewards
    -- through per-frame natives inside its own control loop
    -- (src/modules/utils/client.lua:144). kora_inventory runs no per-frame control
    -- loop and kora_lib has no weapon-wheel module, so there is nothing to route
    -- this to. Deliberate no-op.
    weaponWheel = function() end,
    -- No backing subsystem, BY DESIGN. Upstream uses this hook to format the
    -- player names shown in its give/trade UI. kora_inventory deliberately never
    -- sends a player name, ped or server id across the NUI boundary -- see
    -- client/give_target.lua's header -- so there is no name to format.
    -- Deliberate no-op.
    setGetPlayerNameMethod = function() end,
}

-- Upstream tracks the weapon ITS OWN equip flow armed (src/client.lua:10).
-- kora_inventory records no equip state -- client/useables.lua just toggles the
-- ped's weapon -- so the ped's selected weapon is the only client-side truth
-- available, matched back to an owned item. CAVEAT, and why this is not a
-- drop-in equivalent: it also reports a weapon armed by another resource, and
-- when the player holds two of the same weapon it reports the lowest-numbered
-- slot rather than the equipped one. It is still closer than the hardcoded nil
-- it replaces, which made every ox durability/ammo caller a silent no-op.
-- Defined outside the table literal so it can walk the raw item list.
function ox.getCurrentWeapon()
    local selected = QB.cache.weapon()
    if not selected or selected == joaat('weapon_unarmed') then
        return nil
    end
    local best
    for _, item in pairs(items()) do
        local name = itemName(item.name)
        if
            name
            and name:sub(1, 7) == 'weapon_'
            and joaat(name) == selected
            and (not best or (item.slot or 0) < (best.slot or 0))
        then
            best = item
        end
    end
    return best
end

-- Register under the ox_inventory identity ONLY, never into kora_inventory's own
-- flat export table. This mirrors the server-side rule in
-- server/compat/providers.lua: a compat module builds a table and the provider
-- identity publishes it; compat never calls exports(). Calling exports() here
-- silently overwrote client.lua's own openInventory/closeInventory for every
-- resource in the server -- client_scripts load client.lua first, so the later
-- registration won -- and kora_police, kora_ambulance, kora_clothing and
-- kora_lib-playground all call exports.kora_inventory:openInventory(...).
for name, fn in pairs(ox) do
    QB.compat.provideExport('ox_inventory', name, fn)
end
