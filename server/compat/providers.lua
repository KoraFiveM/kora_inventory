-- Provider identity router. Cfx exposes aliases through __cfx_export events;
-- this is intentionally separate from qbinventory's native export table so
-- qb-inventory:GetInventory and ox_inventory:GetInventory can retain their
-- incompatible upstream return shapes.
local I = assert(QbInventory, 'qbinventory authority missing')
local qb = assert(I.compat and I.compat.qb, 'qb compatibility missing')
local ox = assert(I.compat and I.compat.ox, 'ox compatibility missing')

local function conflicting(name)
    if type(GetResourceState) ~= 'function' then return false end
    local state = GetResourceState(name)
    return state == 'started' or state == 'starting'
end

for _, name in ipairs({ 'qb-inventory', 'ox_inventory' }) do
    if GetCurrentResourceName() ~= name and conflicting(name) then
        error(('qbinventory provider conflict: %s is running; stop it before starting qbinventory'):format(name))
    end
end

local function register(identity, surface)
    for name, fn in pairs(surface) do
        if type(fn) == 'function' then
            AddEventHandler(('__cfx_export_%s_%s'):format(identity, name), function(setCB) setCB(fn) end)
        end
    end
end

register('qb-inventory', qb)
register('ox_inventory', ox)
