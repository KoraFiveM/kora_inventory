-- Test helper: gives any test's global `Kora` table a spy Kora.logging when it is
-- first assigned, so migrated code paths can run without kora_lib loaded.
--   local spy = dofile('test/logging_spy.lua')   -- run from the repo root
--   spy.calls  -> { { level=, event=, message=, fields= }, ... }
--   spy.find(level, event) -> first matching call or nil;  spy.reset()
local spy = { calls = {} }
local logging = { isEnabled = function() return true end }
for _, level in ipairs({ 'trace', 'debug', 'info', 'warn', 'error', 'fatal' }) do
    logging[level] = function(event, message, fields)
        spy.calls[#spy.calls + 1] = { level = level, event = event, message = message, fields = fields }
        return true
    end
end
function spy.find(level, event)
    for _, call in ipairs(spy.calls) do
        if call.level == level and call.event == event then return call end
    end
end
function spy.reset() spy.calls = {} end
spy.logging = logging
setmetatable(_G, { __newindex = function(t, key, value)
    if key == 'Kora' and type(value) == 'table' and value.logging == nil then value.logging = logging end
    rawset(t, key, value)
end })
return spy
