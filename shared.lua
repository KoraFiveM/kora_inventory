QbInventory = QbInventory or {}

local inventory = QbInventory

function inventory.copy(value, seen)
    if type(value) ~= 'table' then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local out = {}
    seen[value] = out
    for key, itemValue in pairs(value) do
        out[inventory.copy(key, seen)] = inventory.copy(itemValue, seen)
    end
    return out
end

---Adds the world-icon fields to a kora_target zone for a shop counter.
---`spriteCoords` is where the icon floats (the till/counter; a location can
---override it). `Config.showTargetHints` is read on every call, so it applies
---the next time zones are registered: nil follows kora_target's own sprite
---setting, true/false force the icon on/off for these zones.
function inventory.shopZoneSprite(zone, location)
    zone.spriteCoords = location.spriteCoords or { x = location.x, y = location.y, z = location.z }
    if Config.showTargetHints == true then
        zone.drawSprite = true
    elseif Config.showTargetHints == false then
        zone.drawSprite = false
    end
    return zone
end

---Z for a prop that must rest on the ground: a model's origin is usually its
---centre, so its lowest point (`minZ`, negative) has to be lifted back to the
---surface. `offset` is the configured nudge applied after placement.
function inventory.groundedZ(groundZ, minZ, offset)
    return groundZ - (minZ or 0.0) + (offset or 0.0)
end

function inventory.amount(value, fallback)
    local number = math.floor(tonumber(value) or (fallback or 1))
    return number > 0 and number or nil
end

function inventory.sameInfo(left, right)
    left, right = left or {}, right or {}
    for key, value in pairs(left) do
        if right[key] ~= value then
            return false
        end
    end
    for key, value in pairs(right) do
        if left[key] ~= value then
            return false
        end
    end
    return true
end

---Normalises one coordinate or an array of coordinates into an array.
---`nil` means no coordinate policy; a malformed non-nil value becomes an empty
---array so callers fail closed rather than accidentally disabling distance.
---@param coords any
---@return table[]|nil
function inventory.coordinateList(coords)
    if coords == nil then
        return nil
    end
    local kind = type(coords)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then
        return {}
    end
    if coords.x ~= nil and coords.y ~= nil and coords.z ~= nil then
        return { coords }
    end

    local out = {}
    for _, point in ipairs(coords) do
        local pointType = type(point)
        if
            (pointType == 'table' or pointType == 'vector3' or pointType == 'vector4')
            and point.x ~= nil
            and point.y ~= nil
            and point.z ~= nil
        then
            out[#out + 1] = point
        end
    end
    return out
end

-- FXServer's exports boundary hands a cross-resource function argument back as
-- a table with a __call metamethod, not a plain Lua function -- so a bare
-- type(x) == 'function' check rejects a perfectly callable handler registered
-- from another resource. Mirrors kora_lib/local/events/server.lua:47 and
-- kora_core/modules/registry/shared.lua:116 (RI.isCallable).
function inventory.isCallable(value)
    if type(value) == 'function' then
        return true
    end
    local metatable = getmetatable(value)
    return metatable ~= nil and type(metatable.__call) == 'function'
end

function inventory.itemMetadata(item)
    if type(item) ~= 'table' then
        return {}
    end
    if type(item.info) == 'table' then
        return item.info
    end
    return type(item.metadata) == 'table' and item.metadata or {}
end

---Resolves the metadata fields that change an item's effective properties.
---@param item table|nil
---@param definition table|nil
---@return table
function inventory.effectiveItem(item, definition)
    item = item or {}
    definition = definition or {}
    local metadata = inventory.itemMetadata(item)
    local imageUrl
    if type(metadata.imageUrl) == 'string' then
        imageUrl = metadata.imageUrl
    elseif type(metadata.image) ~= 'string' then
        imageUrl = item.imageUrl or definition.imageUrl
    end
    return {
        label = type(metadata.label) == 'string' and metadata.label or item.label or definition.label,
        image = type(metadata.image) == 'string' and metadata.image or item.image or definition.image,
        imageUrl = imageUrl,
        -- `nil` rather than truthiness is intentional: zero-weight items are valid.
        weight = type(metadata.weight) == 'number' and metadata.weight >= 0 and metadata.weight < math.huge and metadata.weight
            or (item.weight ~= nil and item.weight or definition.weight) or 0,
        description = type(metadata.description) == 'string' and metadata.description or item.description or definition.description,
    }
end

function inventory.itemWeight(item)
    return (tonumber(inventory.effectiveItem(item).weight) or 0) * (tonumber(item and item.amount) or 0)
end

function inventory.totalWeight(items)
    local weight = 0
    for _, item in pairs(items or {}) do
        weight = weight + inventory.itemWeight(item)
    end
    return weight
end

function inventory.firstFreeSlot(items, slots)
    for slot = 1, slots do
        if not items[slot] then
            return slot
        end
    end
end

function inventory.canStack(current, item)
    return current ~= nil
        and current.name == item.name
        and not current.unique
        and not item.unique
        and inventory.sameInfo(current.info, item.info)
end

function inventory.stackSlot(items, item)
    if item.unique then
        return nil
    end
    local best
    for slot, current in pairs(items or {}) do
        if
            inventory.canStack(current, item)
            and (not best or slot < best)
        then
            best = slot
        end
    end
    return best
end
