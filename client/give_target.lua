-- Privacy-preserving client resolver for an inventory "give" action.
--
-- This file deliberately has no NUI calls and no server event calls.  The NUI
-- bridge can ask whether a recipient is available and start selection, but it
-- must never receive a player list, a player name, a ped handle, or a server
-- id.  A trusted client transport receives the resolved server id over the
-- local `qbinventory:client:giveTargetResolved` event and submits the bounded
-- intent to qbinventory's server authority, which still validates range,
-- bucket, session, source slot and amount immediately before transfer.
--
-- Integration contract (implemented by client.lua/client/ui.lua):
--   TriggerEvent('qbinventory:client:requestGiveAvailability')
--     -> qbinventory:ui:giveAvailability { available = boolean }
--   TriggerEvent('qbinventory:client:requestGiveTarget', requestId)
--     -> qbinventory:client:giveTargetResolved {
--          requestId = requestId, target = serverId
--        }
--        or { requestId = requestId, cancelled = true, reason = string }
--   TriggerEvent('qbinventory:client:cancelGiveTarget', reason?)
--
-- `qbinventory:ui:giveTargeting` contains only `{ active = boolean }`.  The
-- UI bridge uses it to relinquish NUI focus while qbtarget is selecting an
-- in-world ped, then restores focus on resolve/cancel.  Keeping focus control
-- in client/ui.lua preserves qbinventory's NUI ownership boundary.

local GiveTarget = {}
QbInventory = QbInventory or {}
QbInventory.giveTarget = GiveTarget

local active
local availabilityGeneration, lastAvailability = 0, nil

local function giveDistance()
    local config = Config and Config.qbinventory or {}
    return tonumber(config.giveDistance) or tonumber(config.interactionDistance) or 3.0
end

local function serverIdForPed(ped)
    if not ped or ped == 0 or ped == QB.cache.ped() then return nil end

    for _, playerId in ipairs(GetActivePlayers()) do
        if playerId ~= QB.cache.playerId() and GetPlayerPed(playerId) == ped then
            local serverId = GetPlayerServerId(playerId)
            if type(serverId) == 'number' and serverId > 0 then return serverId end
        end
    end
end

-- Query closest first.  `QB.closest.player` is qblib's established mapping
-- from a nearby player ped to a FiveM player id; the full world query is only
-- used after that to distinguish a single unambiguous recipient from several
-- targetable peds.  Neither result crosses the Lua/NUI boundary.
local function nearbyPlayers()
    local coords = QB.cache.coords()
    local radius = giveDistance()
    local closest = QB.closest.player(coords, radius)
    if not closest or not closest.id then return {} end

    local matches = QB.world.getNearbyEntities('player', coords, radius)
    local recipients, seen = {}, {}
    for _, match in ipairs(matches) do
        local serverId = serverIdForPed(match.entity)
        if serverId and not seen[serverId] then
            seen[serverId] = true
            recipients[#recipients + 1] = {
                ped = match.entity,
                serverId = serverId,
                distance = match.distance,
            }
        end
    end

    table.sort(recipients, function(a, b) return a.distance < b.distance end)
    return recipients
end

local function availability()
    return #nearbyPlayers() > 0
end

local function emitAvailability()
    local available = availability()
    lastAvailability = available
    TriggerEvent('qbinventory:ui:giveAvailability', { available = available })
end

local function clearTargetRegistration()
    if not active or not active.registrationId then return end
    if GetResourceState('qbtarget') == 'started' then
        -- qbtarget tears down the whole multi-ped registration when passed its
        -- registration id, but its public remover still takes one numeric ped
        -- as the first argument.
        pcall(function() exports.qbtarget:removeEntity(active.peds[1], active.registrationId) end)
    end
end

local function finish(result)
    local current = active
    if not current then return end

    clearTargetRegistration()
    active = nil
    TriggerEvent('qbinventory:ui:giveTargeting', { active = false })
    TriggerEvent('qbinventory:client:giveTargetResolved', result)
end

---Cancel an outstanding multi-player target selection.  This produces no
---browser payload; consumers use the local resolved event above.
---@param reason? string
function GiveTarget.cancel(reason)
    if not active then return false end
    finish({ requestId = active.requestId, cancelled = true, reason = reason or 'cancelled' })
    return true
end

---Whether there is at least one streamed-in remote player in validated
---candidate range.  This only answers presentation availability; the server
---is the authority for final range and routing-bucket validation.
---@return boolean
function GiveTarget.available()
    return availability()
end

---Resolve one recipient without exposing player identity to the browser.
---With exactly one nearby player it resolves immediately.  With multiple
---nearby players it starts qbtarget on exactly those peds, requiring the
---player to point at and select their intended recipient in the game world.
---@param requestId string|number A browser-local opaque correlation id.
---@return boolean started
---@return string? reason
function GiveTarget.request(requestId)
    if requestId == nil then return false, 'missing give request id' end
    GiveTarget.cancel('replaced')

    local recipients = nearbyPlayers()
    if #recipients == 0 then
        TriggerEvent('qbinventory:client:giveTargetResolved', {
            requestId = requestId,
            cancelled = true,
            reason = 'no nearby player',
        })
        emitAvailability()
        return false, 'no nearby player'
    end

    if #recipients == 1 then
        TriggerEvent('qbinventory:client:giveTargetResolved', {
            requestId = requestId,
            target = recipients[1].serverId,
        })
        emitAvailability()
        return true
    end

    if GetResourceState('qbtarget') ~= 'started' then
        TriggerEvent('qbinventory:client:giveTargetResolved', {
            requestId = requestId,
            cancelled = true,
            reason = 'targeting unavailable',
        })
        return false, 'targeting unavailable'
    end

    local peds, allowed = {}, {}
    for _, recipient in ipairs(recipients) do
        peds[#peds + 1] = recipient.ped
        allowed[recipient.ped] = recipient.serverId
    end

    active = { requestId = requestId, peds = peds, allowed = allowed }
    local ok, registrationId = pcall(function()
        return exports.qbtarget:addEntity(peds, {
            {
                label = 'Give selected item',
                icon = 'HandHeart',
                distance = giveDistance(),
                canInteract = function(entity)
                    -- Target's entity list is a snapshot, so validate the ped
                    -- and its server-id mapping again immediately before it is
                    -- selectable.  No name/list is ever produced.
                    return active and active.allowed[entity] == serverIdForPed(entity)
                end,
                onSelect = function(entity)
                    if not active then return end
                    local target = active.allowed[entity]
                    if not target or target ~= serverIdForPed(entity) then return end
                    finish({ requestId = active.requestId, target = target })
                    emitAvailability()
                end,
            },
        }, giveDistance())
    end)

    if not ok or type(registrationId) ~= 'number' then
        active = nil
        TriggerEvent('qbinventory:client:giveTargetResolved', {
            requestId = requestId,
            cancelled = true,
            reason = 'targeting unavailable',
        })
        return false, 'targeting unavailable'
    end

    active.registrationId = registrationId
    TriggerEvent('qbinventory:ui:giveTargeting', { active = true })

    -- A temporary registration must not leak if the player changes their mind
    -- or the target key is never used.  This is a UI selection timeout only;
    -- it never authorises or mutates inventory state.
    local expected = active
    CreateThread(function()
        Wait(15000)
        if active == expected then GiveTarget.cancel('target selection timed out') end
    end)
    return true
end

AddEventHandler('qbinventory:client:requestGiveAvailability', emitAvailability)
AddEventHandler('qbinventory:client:requestGiveTarget', GiveTarget.request)
AddEventHandler('qbinventory:client:cancelGiveTarget', GiveTarget.cancel)
AddEventHandler('qbinventory:ui:sessionOpened', function()
    availabilityGeneration = availabilityGeneration + 1
    local generation = availabilityGeneration
    lastAvailability = nil
    CreateThread(function()
        while generation == availabilityGeneration do
            local available = availability()
            if available ~= lastAvailability then
                lastAvailability = available
                TriggerEvent('qbinventory:ui:giveAvailability', { available = available })
            end
            Wait(750)
        end
    end)
end)
AddEventHandler('qbinventory:ui:sessionClosed', function()
    GiveTarget.cancel('inventory closed')
    availabilityGeneration = availabilityGeneration + 1
    lastAvailability = nil
end)

exports('giveTargetAvailable', GiveTarget.available)
exports('requestGiveTarget', GiveTarget.request)
exports('cancelGiveTarget', GiveTarget.cancel)
