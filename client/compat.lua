-- qb-inventory client compatibility bridge.
--
-- This file deliberately translates legacy *intent* events only. It never
-- renders the legacy payload or accepts legacy item tables as a source of
-- truth: qbinventory asks its server to resolve every target and the active
-- session remains the only source of inventory views and mutations.

local selfOpening = false

local function setBusy(value)
    -- Keep the conventional qb-inventory state bag in sync with a real
    -- qbinventory session. This state is advisory to other client resources;
    -- the server still validates every action independently.
    LocalPlayer.state:set('inv_busy', value == true, true)
end

local function validIdentifier(value)
    return type(value) == 'string'
        and #value > 0
        and #value <= 96
        and value:match('^[%w_%-:]+$') ~= nil
end

local function openSelf()
    if selfOpening or LocalPlayer.state.inv_busy then return false end
    selfOpening = true
    -- qbinventory validates the local player's server ID before granting the
    -- short-lived session. We intentionally do not inspect nearby vehicles,
    -- entities, or any client inventory record here.
    openInventory('player', GetPlayerServerId(PlayerId()))
    return true
end

local function openLegacyTarget(other)
    -- The first legacy argument is the old player-items table. It is ignored
    -- by design. A second panel's name is only a requested identifier and is
    -- still resolved, access-checked and snapshotted by qbinventory's server.
    if type(other) ~= 'table' then return openSelf() end

    local name = other.name
    if not validIdentifier(name) then return false end

    local typeName, id
    if name:sub(1, 6) == 'shop-' then
        typeName, id = 'shop', name:sub(7)
    elseif name:sub(1, 12) == 'otherplayer-' then
        typeName, id = 'player', name:sub(13)
        if not tonumber(id) then return false end
    elseif name:sub(1, 5) == 'drop-' then
        typeName, id = 'drop', name:sub(6)
    elseif name:sub(1, 6) == 'trunk-' then
        typeName, id = 'trunk', name:sub(7)
    elseif name:sub(1, 9) == 'glovebox-' then
        typeName, id = 'glovebox', name:sub(10)
    else
        -- qb-inventory's generic OpenInventory identifier is a stash. Do not
        -- trust the legacy item list, slots, weights, labels or other data.
        typeName, id = 'stash', name
    end

    if not validIdentifier(id) then return false end
    openInventory(typeName, id)
    return true
end

local function refreshActiveSession()
    local active = getCurrentSession()
    local secondary = active and active.secondary
    if active and not secondary then
        openInventory('player', GetPlayerServerId(PlayerId()))
        return true
    end
    if type(secondary) ~= 'table' or not validIdentifier(secondary.type)
        or (type(secondary.id) ~= 'string' and type(secondary.id) ~= 'number') then
        return false
    end

    -- Re-open only the server-issued target. This produces a new authoritative
    -- snapshot; it does not copy data from qb-inventory:updateInventory.
    openInventory(secondary.type, secondary.id)
    return true
end

-- A qbinventory session is the single lifecycle authority for inv_busy. The
-- UI bridge owns focus; this bridge only mirrors the compatibility state bag.
AddEventHandler('qbinventory:ui:sessionOpened', function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then return end
    selfOpening = false
    setBusy(true)
end)

AddEventHandler('qbinventory:ui:sessionClosed', function()
    selfOpening = false
    setBusy(false)
end)

-- Current upstream qb-inventory event names. The item lists passed by legacy
-- servers are intentionally ignored; all UI state comes back from the
-- qbinventory server session response.
RegisterNetEvent('qb-inventory:client:openInventory', function(_, other)
    openLegacyTarget(other)
end)

RegisterNetEvent('qb-inventory:client:closeInv', function()
    closeInventory()
end)

RegisterNetEvent('qb-inventory:client:updateInventory', function()
    refreshActiveSession()
end)

-- Older qb scripts used these names before the resource prefix was
-- standardised. Keep the aliases narrow and subject to the same safe routing.
RegisterNetEvent('inventory:client:OpenInventory', function(_, other)
    openLegacyTarget(other)
end)

RegisterNetEvent('inventory:client:closeInv', function()
    closeInventory()
end)

RegisterNetEvent('inventory:client:updateInventory', function()
    refreshActiveSession()
end)

RegisterCommand('inventory', function()
    if IsPauseMenuActive() or IsNuiFocused() then return end
    openSelf()
end, false)

-- Match qb-inventory's established TAB command name while allowing scripts
-- and players to continue using the clearer `inventory` command directly.
RegisterCommand('openInv', function()
    ExecuteCommand('inventory')
end, false)

RegisterCommand('closeInv', function()
    closeInventory()
end, false)

RegisterKeyMapping('openInv', 'Open inventory (qbinventory)', 'keyboard', 'TAB')

AddEventHandler('QBCore:Client:OnPlayerLoaded', function()
    selfOpening = false
    if not getCurrentSession() then setBusy(false) end
end)

AddEventHandler('QBCore:Client:OnPlayerUnload', function()
    closeInventory()
    selfOpening = false
    -- Preserve qb-inventory's unload behaviour: callers must not treat an
    -- unloading player as ready for an inventory action.
    setBusy(true)
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        selfOpening = false
        setBusy(false)
    end
end)
