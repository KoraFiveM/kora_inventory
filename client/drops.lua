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
-- Before this, `qbinventory:client:dropCreated` had no listener at all: a
-- dropped item became an inventory at a coordinate with nothing to walk up to.

local dropConfig = (Config.qbinventory and Config.qbinventory.drops) or {}

-- id -> { entity = number|nil, target = integer }
local drops = {}
local dropGeneration = 0

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
        SetEntityCoordsNoOffset(entity, placed.x, placed.y, QbInventory.groundedZ(placed.z, 0.0, offset), false, false, false)
        return
    end

    -- No surface found by the native: lift the model's lowest point onto the
    -- ground Z that onGround() already resolved.
    local minDimension = GetModelDimensions(GetEntityModel(entity))
    SetEntityCoordsNoOffset(entity, coords.x, coords.y, QbInventory.groundedZ(coords.z, minDimension.z, offset), false, false, false)
end

local function removeDrop(id)
    local record = drops[tostring(id)]
    if not record then
        return
    end

    drops[tostring(id)] = nil
    exports.kora_target:removeZone(record.target)
    if record.entity then
        Kora.entities.remove(record.entity)
    end
end

local function addDropTarget(id, coords)
    return exports.kora_target:addSphereZone({
        coords = coords,
        radius = dropConfig.interactionDistance or 1.5,
        options = {
            {
                label = dropConfig.label or 'Pick up',
                icon = dropConfig.icon or 'package',
                onSelect = function()
                    exports.kora_inventory:openInventory('drop', id)
                end,
            },
        },
    })
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
    local record = { coords = placed }
    drops[stringId] = record
    record.target = addDropTarget(stringId, placed)

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

RegisterNetEvent('qbinventory:client:dropsUpdated', function(list)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(list) ~= 'table' then
        return
    end
    dropGeneration = dropGeneration + 1
    syncDrops(list)
end)

RegisterNetEvent('qbinventory:client:dropCreated', function(id, coords)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    addDrop(id, coords)
end)

RegisterNetEvent('qbinventory:client:dropRemoved', function(id)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    removeDrop(id)
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'kora_target' then
        return
    end
    for id, record in pairs(drops) do
        record.target = addDropTarget(id, record.coords)
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
    local list = Kora.callback.trigger('qbinventory:server:drops')
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

    -- Kora.entities and Kora.interact both clean up their own resource's handles on
    -- stop, so this only has to drop the bookkeeping.
    drops = {}
end)
