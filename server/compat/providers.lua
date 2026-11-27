-- Provider identity router. Cfx exposes aliases through __cfx_export events;
-- this is intentionally separate from kora_inventory's native export table so
-- qb-inventory:GetInventory and ox_inventory:GetInventory can retain their
-- incompatible upstream return shapes.
local inventory = assert(KoraInventory, 'kora_inventory authority missing')
local qb = assert(inventory.compat and inventory.compat.qb, 'qb compatibility missing')
local ox = assert(inventory.compat and inventory.compat.ox, 'ox compatibility missing')

local function isImageOnlyStub(name)
    if name ~= 'qb-inventory' and name ~= 'ox_inventory' then return false end
    if type(GetResourceMetadata) ~= 'function' then return false end
    return GetResourceMetadata(name, 'kora_inventory_image_stub', 0) == 'yes'
end

-- GetResourceState('qb-inventory') resolves `provide 'qb-inventory'` back to
-- THIS resource once kora_inventory has started. Enumerate real resources by
-- their physical manifest names instead. Explicitly marked image-only resources
-- may use those names alongside our provider; real inventory resources may not.
local function conflicting(name)
    if
        type(GetNumResources) ~= 'function'
        or type(GetResourceByFindIndex) ~= 'function'
        or type(GetResourceState) ~= 'function'
    then
        return false
    end

    for index = 0, GetNumResources() - 1 do
        local resource = GetResourceByFindIndex(index)
        if resource == name then
            local state = GetResourceState(resource)
            if (state == 'started' or state == 'starting') and not isImageOnlyStub(resource) then
                return true
            end
        end
    end

    return false
end

for _, name in ipairs({ 'qb-inventory', 'ox_inventory', 'qb-weapons' }) do
    if conflicting(name) then
        error(('kora_inventory provider conflict: %s is running; stop it before starting kora_inventory'):format(name))
    end
end

-- Item-creating exports record WHO called them for the audit log: the invoking
-- resource is captured here, at the export boundary (server/audit_log.lua).
local auditLog = inventory.auditLog
local audited = { AddItem = true, RemoveItem = true, SetInventory = true }

local function register(identity, surface)
    for name, fn in pairs(surface) do
        if type(fn) == 'function' then
            if audited[name] and auditLog and auditLog.wrapExport then
                fn = auditLog.wrapExport(fn)
            end
            Kora.compat.provideExport(identity, name, fn)
        end
    end
end

register('qb-inventory', qb)
register('ox_inventory', ox)
