-- qb-inventory client compatibility bridge.
--
-- This file deliberately translates legacy *intent* events only. It never
-- renders the legacy payload or accepts legacy item tables as a source of
-- truth: kora_inventory asks its server to resolve every target and the active
-- session remains the only source of inventory views and mutations.

local inventoryApi = assert(QbInventory and QbInventory.clientApi, 'qbinventory client transport must load first')
local selfOpening = false

local function setBusy(value)
    -- Keep the conventional qb-inventory state bag in sync with a real
    -- kora_inventory session. This state is advisory to other client resources;
    -- the server still validates every action independently.
    LocalPlayer.state:set('inv_busy', value == true, true)
end

local function validIdentifier(value)
    return type(value) == 'string' and #value > 0 and #value <= 96 and value:match('^[%w_%-:]+$') ~= nil
end

local function openSelf()
    if inventoryApi.getCurrentSession() then
        inventoryApi.closeInventory()
        return true
    end
    if selfOpening or LocalPlayer.state.inv_busy then
        return false
    end
    selfOpening = true
    -- kora_inventory validates the local player's server ID before granting the
    -- short-lived session. We intentionally do not inspect nearby vehicles,
    -- entities, or any client inventory record here.
    inventoryApi.openInventory('player', QB.cache.serverId())
    return true
end

local function openLegacyTarget(other)
    -- The first legacy argument is the old player-items table. It is ignored
    -- by design. A second panel's name is only a requested identifier and is
    -- still resolved, access-checked and snapshotted by kora_inventory's server.
    if type(other) ~= 'table' then
        return openSelf()
    end

    local name = other.name
    if not validIdentifier(name) then
        return false
    end

    local typeName, id
    if name:sub(1, 6) == 'shop-' then
        typeName, id = 'shop', name:sub(7)
    elseif name:sub(1, 12) == 'otherplayer-' then
        typeName, id = 'player', name:sub(13)
        if not tonumber(id) then
            return false
        end
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

    if not validIdentifier(id) then
        return false
    end
    inventoryApi.openInventory(typeName, id)
    return true
end

---Respond to a legacy "your inventory changed" push.
---
---Under kora_inventory this is a deliberate no-op, and it must stay one. An open
---session is already kept current by the authoritative
---`qbinventory:client:sessionPatched` stream, and with no session open there is
---no UI to refresh -- so there is no state a re-open could recover.
---
---It matters that this does NOT re-open: the server emits the legacy
---`qb-inventory:client:updateInventory` after every committed change, so that
---third-party scripts which only know the upstream name hear about it at all.
---Re-opening in response would close and reissue the player's own session on
---every single item change.
---
---The legacy payload is ignored either way; it is never a source of truth.
local function refreshActiveSession()
    return inventoryApi.getCurrentSession() ~= nil
end

-- A kora_inventory session is the single lifecycle authority for inv_busy. The
-- UI bridge owns focus; this bridge only mirrors the compatibility state bag.
AddEventHandler('qbinventory:ui:sessionOpened', function(payload)
    if type(payload) ~= 'table' or type(payload.token) ~= 'string' then
        return
    end
    selfOpening = false
    setBusy(true)
end)

AddEventHandler('qbinventory:ui:sessionClosed', function()
    selfOpening = false
    setBusy(false)
end)

-- A normal usable closes the inventory after its server handler returns. Clear
-- the compatibility lock before that handler runs so its client-side effects
-- can add or remove items. A rejected use leaves the session open, so restore
-- the lock in that case.
AddEventHandler('qbinventory:client:useStarted', function()
    setBusy(false)
end)

AddEventHandler('qbinventory:client:useRejected', function()
    if inventoryApi.getCurrentSession() then
        setBusy(true)
    end
end)

-- Current upstream qb-inventory event names. The item lists passed by legacy
-- servers are intentionally ignored; all UI state comes back from the
-- kora_inventory server session response.
RegisterNetEvent('qb-inventory:client:openInventory', function(_, other)
    openLegacyTarget(other)
end)

RegisterNetEvent('qb-inventory:client:closeInv', function()
    inventoryApi.closeInventory()
end)

RegisterNetEvent('qb-inventory:client:updateInventory', function()
    refreshActiveSession()
end)

-- kora_inventory owns item receipt configuration and presentation. Upstream
-- resources commonly call this immediately after AddItem; accepting it as a
-- deliberate no-op avoids duplicate receipts and means resources never need
-- to carry UI data or decide whether boxes are enabled.
RegisterNetEvent('qb-inventory:client:ItemBox', function() end)

-- The rest of upstream's client event surface. kora_inventory owns its own UI, so
-- most of these are DELIBERATE no-ops rather than missing work: registering the
-- names means an unmodified qb-inventory dependant fires them harmlessly
-- instead of erroring, while presentation stays under kora_inventory's control
-- (same reasoning as the ItemBox handler above).

-- Upstream renders a "required items" hint panel. kora_inventory's NUI does not
-- take item lists from other resources -- that is the spoofing vector the
-- ItemBox policy exists to close -- so the payload is intentionally dropped.
RegisterNetEvent('qb-inventory:client:requiredItems', function() end)

-- The hotbar is part of kora_inventory's own UI and is driven from its session,
-- not from a caller-supplied item list.
RegisterNetEvent('qb-inventory:client:hotbar', function() end)

-- Purely cosmetic, and safe to honour: play the same give animation upstream
-- does. Skipped in a vehicle, exactly as upstream does.
RegisterNetEvent('qb-inventory:client:giveAnim', function()
    local ped = QB.cache.ped()
    if QB.cache.vehicle() then
        return
    end
    if not QB.stream.loadAnimDict('mp_common', nil, { timeout = 1000 }) then
        return
    end
    TaskPlayAnim(ped, 'mp_common', 'givetake1_b', 8.0, -8.0, -1, 49, 0, false, false, false)
end)

-- Drop discovery is server-resolved here: kora_inventory hands the client a
-- session for a drop it has already access-checked, so there is no client-side
-- drop entity registry to add or remove targets from. Accepting these keeps
-- upstream drop scripts from erroring.
RegisterNetEvent('qb-inventory:client:setupDropTarget', function() end)
RegisterNetEvent('qb-inventory:client:removeDropTarget', function() end)

-- Registered CLIENT-side upstream despite the :server: name (qb-policejob
-- fires it). Opening another player's inventory is gated by the server's
-- inspection policy, so this cannot be granted from a client event -- the
-- officer's own search flow goes through kora_inventory's validated open.
RegisterNetEvent('qb-inventory:server:RobPlayer', function() end)

-- Older qb scripts used these names before the resource prefix was
-- standardised. Keep the aliases narrow and subject to the same safe routing.
RegisterNetEvent('inventory:client:OpenInventory', function(_, other)
    openLegacyTarget(other)
end)

RegisterNetEvent('inventory:client:closeInv', function()
    inventoryApi.closeInventory()
end)

RegisterNetEvent('inventory:client:updateInventory', function()
    refreshActiveSession()
end)

RegisterNetEvent('inventory:client:ItemBox', function() end)

RegisterCommand('inventory', function()
    if IsPauseMenuActive() or IsNuiFocused() then
        return
    end
    -- TAB also drives kora_lib's zone and entity-placement creators;
    -- all are independent keybinds, so an active creator session
    -- must explicitly veto this one rather than relying on FiveM to pick
    -- only one handler for a shared key.
    if QB.zones.isCreatorActive() or QB.placement.isActive() then
        return
    end
    -- Seated -> glovebox, at a vehicle's boot -> trunk (client/vehicles.lua).
    if QbInventory.vehicleStorage and QbInventory.vehicleStorage.tryOpen() then
        return
    end
    openSelf()
end, false)

-- Match qb-inventory's established TAB command name while allowing scripts
-- and players to continue using the clearer `inventory` command directly.
local function openInventoryCommand()
    ExecuteCommand('inventory')
end
RegisterCommand('openInv', openInventoryCommand, false)

RegisterCommand('closeInv', function()
    inventoryApi.closeInventory()
end, false)

QB.keybind.add({
    name = 'openInv',
    description = 'Open inventory (qbinventory)',
    defaultMapper = 'keyboard',
    defaultKey = 'TAB',
    onPressed = openInventoryCommand,
})

-- RegisterNetEvent, not AddEventHandler: kora_core only ever fires these two over
-- the wire (TriggerClientEvent in kora_core's modules/player/server.lua). FiveM
-- SKIPS a net-delivered event whose handler was attached with bare
-- AddEventHandler -- printing "event ... was not safe for net" -- so these
-- resets silently never ran on login/logout.
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    selfOpening = false
    if not inventoryApi.getCurrentSession() then
        setBusy(false)
    end
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    inventoryApi.closeInventory()
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
