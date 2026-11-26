-- Ground-drop props.
--
-- Presentation only, and deliberately so. The bag is a LOCAL, non-networked
-- object created per client; it holds no inventory identity, and selecting it
-- calls the ordinary open path with the drop id the server itself broadcast.
-- The server then re-resolves that drop and repeats its access, distance and
-- routing-bucket checks, exactly as it does for a stash or a shop. Deleting the
-- prop, moving it, or inventing one client-side therefore gains nothing: a
-- player who never sees a bag can still open the drop, and a player who sees a
-- fabricated one opens nothing.
--
-- Interact mode (Config.kora_inventory.drops.interact):
--   'target'    — classic kora_target sphere (hold Alt, select Pick up). Default.
--   'proximity' — target-style Pick up card while inside interactionDistance;
--                 Alt opens the bag immediately (no kora_target eye).

local dropConfig = (Config.kora_inventory and Config.kora_inventory.drops) or {}

-- INPUT_CHARACTER_WHEEL — same Alt binding kora_target uses.
local ALT_CONTROL = 19

-- id -> { coords = table, entity = number|nil, target = integer|nil, zone = table|nil }
local drops = {}
local dropGeneration = 0

-- Proximity mode only: bags whose interaction sphere the player is inside.
local near = {}
local proximityActive = false

local function useTarget()
    return dropConfig.interact == 'target'
end

local function interactionRadius()
    return tonumber(dropConfig.interactionDistance) or 1.5
end

---Drop coordinates are the dropping player's ped position, which sits about a
---metre above the floor. A downward trace puts the bag on the surface; a failed
---trace keeps the original Z rather than dropping the prop through the map.
---@param coords table
---@return table
local function onGround(coords)
    if dropConfig.placeOnGround == false then
        return coords
    end

    local found, z = GetGroundZFor_3dCoord(coords.x + 0.0, coords.y + 0.0, coords.z + 1.0, false)
    if not found then
        return coords
    end

    return { x = coords.x, y = coords.y, z = z }
end

---A prop is created at its model origin, so on its own it sits part-way into
---the floor. Needs collision streamed in, or both placement paths hit nothing.
---@param entity number
---@param coords table Ground position from onGround().
local function settleOnGround(entity, coords)
    if dropConfig.placeOnGround == false then
        return
    end

    RequestCollisionAtCoord(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
    local attempts = 0
    while not HasCollisionLoadedAroundEntity(entity) and attempts < 20 do
        Wait(50)
        attempts = attempts + 1
    end
    if not DoesEntityExist(entity) then
        return
    end

    local offset = tonumber(dropConfig.groundOffset) or 0.0
    if PlaceObjectOnGroundProperly(entity) then
        if offset == 0.0 then
            return
        end
        local placed = GetEntityCoords(entity)
        SetEntityCoordsNoOffset(entity, placed.x, placed.y, KoraInventory.groundedZ(placed.z, 0.0, offset), false, false, false)
        return
    end

    -- No surface found by the native: lift the model's lowest point onto the
    -- ground Z that onGround() already resolved.
    local minDimension = GetModelDimensions(GetEntityModel(entity))
    SetEntityCoordsNoOffset(entity, coords.x, coords.y, KoraInventory.groundedZ(coords.z, minDimension.z, offset), false, false, false)
end

local function openDrop(id)
    exports.kora_inventory:openInventory('drop', id)
end

local function leaveNear(record)
    for i = 1, #near do
        if near[i] == record then
            table.remove(near, i)
            return
        end
    end
end

local function nearestNear()
    local pedCoords = GetEntityCoords(PlayerPedId())
    local best, bestDist
    for i = 1, #near do
        local record = near[i]
        local c = record.coords
        local dx = pedCoords.x - c.x
        local dy = pedCoords.y - c.y
        local dz = pedCoords.z - c.z
        local dist = dx * dx + dy * dy + dz * dz
        if not bestDist or dist < bestDist then
            bestDist = dist
            best = record
        end
    end
    return best
end

-- Screen-space card that mirrors kora_target's option chip (dark panel, bold
-- label, muted "Press Alt…" line) so proximity mode does not fall back to
-- outlined world text.
local function drawPrompt(coords, title, hint)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(coords.x + 0.0, coords.y + 0.0, coords.z + 0.35)
    if not onScreen then
        return
    end

    local width, height = 0.09, 0.042
    DrawRect(sx + 0.055, sy, width, height, 18, 18, 20, 210)

    SetTextFont(4)
    SetTextScale(0.0, 0.33)
    SetTextColour(255, 255, 255, 255)
    SetTextCentre(false)
    SetTextDropshadow(0, 0, 0, 0, 0)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(title)
    EndTextCommandDisplayText(sx + 0.018, sy - 0.016)

    SetTextFont(4)
    SetTextScale(0.0, 0.24)
    SetTextColour(170, 170, 175, 255)
    SetTextCentre(false)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(hint)
    EndTextCommandDisplayText(sx + 0.018, sy + 0.002)
end

local function proximityLoop()
    local title = dropConfig.label or 'Pick up'
    local hint
    while #near > 0 do
        if not hint then
            hint = Kora.lang('drop_hints.hint')
        end
        -- Stop kora_target from claiming Alt while a bag is in range so the
        -- press opens the drop instead of showing the eye first.
        DisableControlAction(0, ALT_CONTROL, true)
        local focus = nearestNear()
        if focus then
            drawPrompt(focus.coords, title, hint)
            if not IsPauseMenuActive() and not IsNuiFocused()
                and IsDisabledControlJustPressed(0, ALT_CONTROL) then
                openDrop(focus.id)
            end
        end
        Wait(0)
    end
    proximityActive = false
end

local function addProximityZone(record)
    record.zone = Kora.zones.sphere({
        coords = vector3(record.coords.x, record.coords.y, record.coords.z),
        radius = interactionRadius(),
        onEnter = function()
            near[#near + 1] = record
            if not proximityActive then
                proximityActive = true
                CreateThread(proximityLoop)
            end
        end,
        onExit = function()
            leaveNear(record)
        end,
    })
end

local function addDropTarget(id, coords)
    return exports.kora_target:addSphereZone({
        coords = coords,
        radius = interactionRadius(),
        options = {
            {
                label = dropConfig.label or 'Pick up',
                icon = dropConfig.icon or 'package',
                onSelect = function()
                    openDrop(id)
                end,
            },
        },
    })
end

local function clearInteract(record)
    if record.target then
        pcall(function() exports.kora_target:removeZone(record.target) end)
        record.target = nil
    end
    if record.zone then
        leaveNear(record)
        pcall(function() record.zone.remove() end)
        record.zone = nil
    end
end

local function removeDrop(id)
    local record = drops[tostring(id)]
    if not record then
        return
    end

    drops[tostring(id)] = nil
    clearInteract(record)
    if record.entity then
        Kora.entities.remove(record.entity)
    end
end

local function addDrop(id, coords)
    if dropConfig.enabled == false then
        return
    end
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' then
        return
    end

    local stringId = tostring(id)
    -- A re-broadcast, or a hydrate racing a live create, must not stack a second
    -- prop and zone on the same drop.
    if drops[stringId] then
        return
    end

    local placed = onGround(coords)

    -- Registered BEFORE the model finishes streaming. Kora.entities.create waits
    -- on the model, and a drop emptied during that wait would otherwise land its
    -- removal before this record existed and leave the prop orphaned.
    local record = { id = stringId, coords = placed }
    drops[stringId] = record
    if useTarget() then
        record.target = addDropTarget(stringId, placed)
    else
        addProximityZone(record)
    end

    -- Keep snapshot reconciliation synchronous while the model streams.
    CreateThread(function()
        local entity = Kora.entities.create(dropConfig.model or 'prop_med_bag_01b', placed, { freeze = true })
        if drops[stringId] ~= record then
            -- Removed or replaced while the model was streaming.
            if entity then
                Kora.entities.remove(entity)
            end
            return
        end
        record.entity = entity or nil
        if entity then
            settleOnGround(entity, placed)
        end
    end)
end

local function syncDrops(list)
    local visible = {}
    for _, entry in ipairs(list) do
        if entry and entry.id ~= nil then
            visible[tostring(entry.id)] = entry.coords
        end
    end
    for id in pairs(drops) do
        if not visible[id] then
            removeDrop(id)
        end
    end
    for id, coords in pairs(visible) do
        addDrop(id, coords)
    end
end

RegisterNetEvent('kora_inventory:client:dropsUpdated', function(list)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(list) ~= 'table' then
        return
    end
    dropGeneration = dropGeneration + 1
    syncDrops(list)
end)

RegisterNetEvent('kora_inventory:client:dropCreated', function(id, coords)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    addDrop(id, coords)
end)

RegisterNetEvent('kora_inventory:client:dropRemoved', function(id)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    removeDrop(id)
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'kora_target' or not useTarget() then
        return
    end
    for id, record in pairs(drops) do
        if not record.target then
            record.target = addDropTarget(id, record.coords)
        end
    end
end)

-- Hydration. `dropCreated` is a one-shot broadcast, so a player connecting (or
-- a client resource restarting) after a bag landed would never render it. The
-- callback returns ids and coordinates in this player's bucket, never contents.
local function hydrate()
    if dropConfig.enabled == false then
        return
    end

    local generation = dropGeneration
    local list = Kora.callback.trigger('kora_inventory:server:drops')
    if type(list) ~= 'table' or generation ~= dropGeneration then
        return
    end
    for _, entry in ipairs(list) do
        if entry and entry.id ~= nil then
            addDrop(entry.id, entry.coords)
        end
    end
end

CreateThread(function()
    -- The callback handshake is not up at the first frame of a resource start,
    -- and on a fresh connect the player is not in the world yet either.
    while not NetworkIsSessionStarted() do
        Wait(250)
    end
    Wait(1000)
    hydrate()
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    -- Kora.entities removes this resource's bag props on stop, so this only has to
    -- drop the bookkeeping; interact zones are torn down with the resource.
    near = {}
    drops = {}
end)
