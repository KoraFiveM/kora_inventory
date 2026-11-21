-- Test helper: the Kora.util.deepClone stub that shared.lua's inventory.copy relies on.
--   Kora.util = { deepClone = dofile('test/deep_clone.lua') }   -- run from the repo root
local function clone(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for k, v in pairs(value) do copy[clone(k)] = clone(v) end
    return copy
end
return clone
