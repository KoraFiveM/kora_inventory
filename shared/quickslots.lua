-- Quick slots: SHORTCUTS, not physical slots.
--
-- Items stay wherever they are in the player's normal inventory (kora_core's
-- PlayerData.items, slots 1..playerSlots). A quick slot is only a pointer that
-- resolves to the real slot of a matching item, for display beside the
-- inventory and for hotkeys. Nothing here is stored, nothing is authority, and
-- the resolver is pure so it can be tested without FXServer: the caller passes
-- the items, the item/weapon definition lookup and any local preferences in.
--
-- Resolution order for each quick slot:
--   1. a pin (a local preference): an item that matches the slot's filter, has
--      the pinned name and, when the pin carries a serial, the same serial;
--   2. weapon-accepting slots only: the weapon that is currently drawn;
--   3. the lowest-numbered matching slot.
-- A weapon taken by one weapon quick slot is not taken again by another one
-- (for example `weapon` and `sidearm`) unless it was pinned there.
--
-- `linkedTo = '<id>'` slots resolve to the ammunition item whose
-- `def.ammoType` equals the `ammotype` of the weapon resolved for that slot.

KoraInventory = KoraInventory or {}

local quickSlots = {}
KoraInventory.quickSlots = quickSlots

local function lower(value)
    return type(value) == 'string' and value:lower() or nil
end

local function itemAmount(item)
    return math.max(1, math.floor(tonumber(item.amount or item.count) or 1))
end

---True when `accepts` has at least one usable criterion. A quick slot without
---a filter never matches anything.
---@param accepts table|nil
---@return boolean
local function hasFilter(accepts)
    if type(accepts) ~= 'table' then
        return false
    end
    return (type(accepts.names) == 'table' and #accepts.names > 0)
        or type(accepts.type) == 'string'
        or type(accepts.weapontype) == 'string'
end

---Does this item satisfy a quick slot's `accepts` filter? Every criterion that
---is present must hold (`names` is "any of").
---@param accepts table|nil
---@param item table|nil  { name = string, ... }
---@param def table|nil   item or weapon definition for item.name
---@return boolean
function quickSlots.matches(accepts, item, def)
    if not hasFilter(accepts) or type(item) ~= 'table' then
        return false
    end
    local name = lower(item.name)
    if not name then
        return false
    end
    if type(accepts.names) == 'table' and #accepts.names > 0 then
        local found = false
        for _, candidate in ipairs(accepts.names) do
            if lower(candidate) == name then
                found = true
                break
            end
        end
        if not found then
            return false
        end
    end
    if type(accepts.type) == 'string' then
        if type(def) ~= 'table' or lower(def.type) ~= lower(accepts.type) then
            return false
        end
    end
    if type(accepts.weapontype) == 'string' then
        if type(def) ~= 'table' or lower(def.weapontype) ~= lower(accepts.weapontype) then
            return false
        end
    end
    return true
end

---@param config table|nil
---@return boolean
local function acceptsWeapons(config)
    return type(config.accepts) == 'table' and lower(config.accepts.type) == 'weapon'
end

---@param items table PlayerData.items (sparse: slot -> item)
---@param slotsConfig table Config.kora_inventory.quickSlots.slots
---@param opts table|nil
---   getDef(name) -> definition|nil (item defs; weapons carry type='weapon',
---   ammotype, weapontype; ammo items carry ammoType)
---   pins = { [id] = { name = string, serial = string|nil } }
---   equippedSlot = number|nil  slot of the currently drawn weapon
---   playerSlots = number       slots above this are ignored
---   keys = { [id] = string }   currently bound key labels (default: config key)
---@return table[] resolved { id, label, slot, name, total, pinned, key } in config order
function quickSlots.resolve(items, slotsConfig, opts)
    opts = type(opts) == 'table' and opts or {}
    items = type(items) == 'table' and items or {}
    slotsConfig = type(slotsConfig) == 'table' and slotsConfig or {}
    local pins = type(opts.pins) == 'table' and opts.pins or {}
    local keys = type(opts.keys) == 'table' and opts.keys or {}
    local getDef = type(opts.getDef) == 'function' and opts.getDef or function(_) return nil end
    local equipped = math.floor(tonumber(opts.equippedSlot) or 0)

    local playerSlots = math.floor(tonumber(opts.playerSlots) or 0)
    if playerSlots <= 0 then
        for slot in pairs(items) do
            if type(slot) == 'number' and slot > playerSlots then
                playerSlots = math.floor(slot)
            end
        end
    end

    -- One definition lookup per item name per call.
    local defs = {}
    local function defOf(name)
        local key = lower(name)
        if not key then
            return nil
        end
        local def = defs[key]
        if def == nil then
            def = getDef(key) or false
            defs[key] = def
        end
        return def or nil
    end

    local function itemAt(slot)
        local item = items[slot]
        if type(item) == 'table' and type(item.name) == 'string' then
            return item
        end
        return nil
    end

    local out, byId = {}, {}
    for index, config in ipairs(slotsConfig) do
        if type(config) == 'table' and type(config.id) == 'string' then
            local entry = {
                id = config.id,
                label = config.label or config.id,
                slot = nil,
                name = nil,
                total = nil,
                pinned = false,
                key = tostring(keys[config.id] or config.key or ''),
            }
            out[#out + 1] = entry
            byId[config.id] = { entry = entry, config = config, order = index }
        end
    end

    local function assign(record, slot, item, pinned)
        record.entry.slot = slot
        record.entry.name = item.name
        record.entry.pinned = pinned == true
    end

    -- Weapon slots already taken by a weapon quick slot.
    local claimed = {}

    local function matchAt(config, slot)
        local item = itemAt(slot)
        if item and quickSlots.matches(config.accepts, item, defOf(item.name)) then
            return item
        end
        return nil
    end

    -- Pass 1: pins, for every slot, so a pinned weapon is claimed before any
    -- unpinned slot goes looking for "the first weapon".
    for _, record in pairs(byId) do
        local config = record.config
        local pin = pins[config.id]
        if not config.linkedTo and type(pin) == 'table' and type(pin.name) == 'string' then
            local pinName = pin.name:lower()
            for slot = 1, playerSlots do
                local item = matchAt(config, slot)
                if item and item.name:lower() == pinName
                    and (type(pin.serial) ~= 'string' or pin.serial == ''
                        or (type(item.info) == 'table' and item.info.serial == pin.serial))
                then
                    assign(record, slot, item, true)
                    if acceptsWeapons(config) then
                        claimed[slot] = true
                    end
                    break
                end
            end
        end
    end

    -- Pass 2: equipped weapon, then lowest matching slot, in config order.
    -- Equipped goes first for every weapon slot so the drawn weapon belongs to
    -- the earliest slot that accepts it.
    for _, entry in ipairs(out) do
        local record = byId[entry.id]
        local config = record.config
        if not config.linkedTo and not entry.slot and acceptsWeapons(config)
            and equipped >= 1 and equipped <= playerSlots and not claimed[equipped]
        then
            local item = matchAt(config, equipped)
            if item then
                assign(record, equipped, item, false)
                claimed[equipped] = true
            end
        end
    end

    for _, entry in ipairs(out) do
        local record = byId[entry.id]
        local config = record.config
        if not config.linkedTo and not entry.slot then
            local weaponSlot = acceptsWeapons(config)
            for slot = 1, playerSlots do
                if not (weaponSlot and claimed[slot]) then
                    local item = matchAt(config, slot)
                    if item then
                        assign(record, slot, item, false)
                        if weaponSlot then
                            claimed[slot] = true
                        end
                        break
                    end
                end
            end
        end
    end

    -- Pass 3: linked ammunition, from the weapon resolved for the source slot.
    for _, entry in ipairs(out) do
        local record = byId[entry.id]
        local source = record.config.linkedTo and byId[record.config.linkedTo]
        if source and source.entry.slot and not source.config.linkedTo then
            local weapon = itemAt(source.entry.slot)
            local weaponDef = weapon and defOf(weapon.name)
            local ammotype = type(weaponDef) == 'table' and weaponDef.ammotype or nil
            if type(ammotype) == 'string' and ammotype ~= '' then
                local total = 0
                for slot = 1, playerSlots do
                    local item = itemAt(slot)
                    local def = item and defOf(item.name)
                    if type(def) == 'table' and def.ammoType == ammotype then
                        if not entry.slot then
                            entry.slot = slot
                            entry.name = item.name
                        end
                        total = total + itemAmount(item)
                    end
                end
                if entry.slot then
                    entry.total = total
                end
            end
        end
    end

    return out
end
