-- Provider identity router. Cfx exposes aliases through __cfx_export events;
-- this is intentionally separate from qbinventory's native export table so
-- qb-inventory:GetInventory and ox_inventory:GetInventory can retain their
-- incompatible upstream return shapes.
local I = assert(QbInventory, 'qbinventory authority missing')
local qb = assert(I.compat and I.compat.qb, 'qb compatibility missing')
local ox = assert(I.compat and I.compat.ox, 'ox compatibility missing')

-- GetResourceState('qb-inventory') resolves `provide 'qb-inventory'` back to
-- THIS resource once qbinventory has started. Looking it up directly therefore
-- falsely reports a conflict with our own alias. Enumerate real resources by
-- their physical manifest names instead; provided identities are not entries
-- in that list, while a separately ensured qb-inventory/ox_inventory folder is.
local function conflicting(name)
    if type(GetNumResources) ~= 'function' or type(GetResourceByFindIndex) ~= 'function' or type(GetResourceState) ~= 'function' then
        return false
    end

    for index = 0, GetNumResources() - 1 do
        local resource = GetResourceByFindIndex(index)
        if resource == name then
            local state = GetResourceState(resource)
            return state == 'started' or state == 'starting'
        end
    end

    return false
end

for _, name in ipairs({ 'qb-inventory', 'ox_inventory' }) do
    if conflicting(name) then
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
