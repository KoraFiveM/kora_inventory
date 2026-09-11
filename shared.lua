QbInventory = QbInventory or {}

local I = QbInventory

function I.copy(value, seen)
    if type(value) ~= 'table' then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[I.copy(k, seen)] = I.copy(v, seen) end
    return out
end

function I.amount(value, fallback)
    local n = math.floor(tonumber(value) or (fallback or 1))
    return n > 0 and n or nil
end

function I.sameInfo(a, b)
    a, b = a or {}, b or {}
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k, v in pairs(b) do if a[k] ~= v then return false end end
    return true
end

---Normalises one coordinate or an array of coordinates into an array.
---`nil` means no coordinate policy; a malformed non-nil value becomes an empty
---array so callers fail closed rather than accidentally disabling distance.
---@param coords any
---@return table[]|nil
function I.coordinateList(coords)
    if coords == nil then return nil end
    local kind = type(coords)
    if kind ~= 'table' and kind ~= 'vector3' and kind ~= 'vector4' then return {} end
    if coords.x ~= nil and coords.y ~= nil and coords.z ~= nil then return { coords } end

    local out = {}
    for _, point in ipairs(coords) do
        local pointType = type(point)
        if (pointType == 'table' or pointType == 'vector3' or pointType == 'vector4')
            and point.x ~= nil and point.y ~= nil and point.z ~= nil then
            out[#out + 1] = point
        end
    end
    return out
end

-- FXServer's exports boundary hands a cross-resource function argument back as
-- a table with a __call metamethod, not a plain Lua function -- so a bare
-- type(x) == 'function' check rejects a perfectly callable handler registered
-- from another resource. Mirrors qblib/local/events/server.lua:47 and
-- qbcore/modules/registry/shared.lua:116 (RI.isCallable).
function I.isCallable(x)
    if type(x) == 'function' then return true end
    local mt = getmetatable(x)
    return mt ~= nil and type(mt.__call) == 'function'
end

function I.itemWeight(item)
    return (tonumber(item and item.weight) or 0) * (tonumber(item and item.amount) or 0)
end

function I.totalWeight(items)
    local weight = 0
    for _, item in pairs(items or {}) do weight = weight + I.itemWeight(item) end
    return weight
end

function I.firstFreeSlot(items, slots)
    for slot = 1, slots do if not items[slot] then return slot end end
end

function I.stackSlot(items, item)
    if item.unique then return nil end
    local best
    for slot, current in pairs(items or {}) do
        if current.name == item.name and not current.unique and I.sameInfo(current.info, item.info)
            and (not best or slot < best) then best = slot end
    end
    return best
end
