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
