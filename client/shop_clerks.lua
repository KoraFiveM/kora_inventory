-- Shop clerk peds for the general shops (24/7, liquor, ...): a frozen,
-- invincible clerk behind each counter that plays a scenario (clipboard by
-- default) and opens the shop through kora_target. Presentation only: the
-- server still validates the counter position and bucket before every open.
--
-- A location gets a clerk when it has a `ped` spot ({ x, y, z, heading }, z =
-- floor height) and Config.ShopClerks.enabled is on. Ammu-Nation has its own
-- shopkeeper system (shop.shopkeeper) and is skipped here.
--
-- Cost: one Kora.zones sphere per clerk (Config.ShopClerks.radius). The ped
-- exists only while the player is inside that sphere and is deleted when they
-- leave; there is no polling thread. Everything is cleaned up when the
-- resource stops (Kora.entities tracks the peds, the kora_target entity
-- registrations are removed here).

QbInventory = QbInventory or {}

local active = {} -- location table -> { entity, targetId }
local clerks = {} -- one record per clerk { zone, spot, shop, location, inside, spawning }

local function clerkConfig()
    local config = Config.ShopClerks
    if type(config) ~= 'table' or config.enabled ~= true then return nil end
    return config
end

-- Returns the resolved clerk settings for a location, or nil when it has none.
local function resolveClerk(shop, location)
    local config = clerkConfig()
    if not config then return nil end
    if type(shop) ~= 'table' or shop.enabled == false or shop.shopkeeper ~= nil then return nil end
    local shopOptions = shop.clerk
    if shopOptions == false or (type(shopOptions) == 'table' and shopOptions.enabled == false) then return nil end
    if location.clerk == false or type(location.ped) ~= 'table' then return nil end
    local ped = location.ped
    if type(ped.x) ~= 'number' or type(ped.y) ~= 'number' or type(ped.z) ~= 'number' then return nil end
    shopOptions = type(shopOptions) == 'table' and shopOptions or {}
    return {
        x = ped.x,
        y = ped.y,
        z = ped.z,
        heading = tonumber(ped.heading) or 0.0,
        model = ped.model or shopOptions.model or config.model,
        scenario = ped.scenario or shopOptions.scenario or config.scenario,
        radius = tonumber(ped.radius or shopOptions.radius or config.radius) or 40.0,
    }
end

-- True when this location has a clerk configured. shop_hints uses it to drop
-- the floating label (Config.ShopClerks.showLabel) at clerk-served counters.
function QbInventory.shopHasClerk(shop, location)
    return resolveClerk(shop, location) ~= nil
end

-- True while the clerk ped for this location is actually spawned. The counter
-- zone uses it so the 'Open shop' option is not offered twice.
function QbInventory.shopClerkActive(location)
    local state = active[location]
    return state ~= nil and state.targetId ~= nil
end

local function removeClerk(location)
    local state = active[location]
    if not state then return end
    active[location] = nil
    if state.targetId then
        pcall(function() exports.kora_target:removeEntity(state.entity, state.targetId) end)
    end
    if state.entity and DoesEntityExist(state.entity) then
        Kora.entities.remove(state.entity)
    end
end

local function spawnClerk(record)
    local settings, shop, location = record.settings, record.shop, record.location
    local entity = Kora.entities.create(settings.model, {
        x = settings.x,
        y = settings.y,
        -- Config z is floor height; a ped is positioned by its root.
        z = settings.z - 1.0,
        heading = settings.heading,
    }, { preset = 'static' })
    -- The player may have left (or the resource be stopping) while the model streamed.
    if not entity then return end
    if not record.inside or record.removed then
        Kora.entities.remove(entity)
        return
    end

    if settings.scenario and settings.scenario ~= '' then
        TaskStartScenarioInPlace(entity, settings.scenario, 0, true)
    end

    local config = clerkConfig() or {}
    local ok, targetId = pcall(function()
        return exports.kora_target:addEntity(entity, {
            {
                label = ('Open shop (%s)'):format(location.name or shop.label or 'Shop'),
                icon = 'basket-shopping',
                onSelect = function()
                    exports.kora_inventory:openInventory('shop', shop.id)
                end,
            },
        }, tonumber(config.interactionDistance) or 3.0)
    end)
    active[location] = { entity = entity, targetId = ok and targetId or nil }
end

local function registerClerks()
    for _, shop in pairs((Config.qbinventory and Config.qbinventory.shops) or {}) do
        for _, location in ipairs(type(shop) == 'table' and shop.locations or {}) do
            local settings = resolveClerk(shop, location)
            if settings then
                local record = { settings = settings, shop = shop, location = location, inside = false, spawning = false }
                record.zone = Kora.zones.sphere({
                    coords = vector3(settings.x, settings.y, settings.z),
                    radius = settings.radius,
                    onEnter = function()
                        record.inside = true
                        if record.spawning or active[location] then return end
                        record.spawning = true
                        -- Model streaming yields; zone callbacks must not.
                        CreateThread(function()
                            local ok, err = pcall(spawnClerk, record)
                            record.spawning = false
                            if not ok then
                                print(('^3[kora_inventory]^7 shop clerk could not be spawned: %s'):format(tostring(err)))
                            end
                        end)
                    end,
                    onExit = function()
                        record.inside = false
                        removeClerk(location)
                    end,
                })
                clerks[#clerks + 1] = record
            end
        end
    end
end

registerClerks()

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for _, record in ipairs(clerks) do
            record.removed = true
            if record.zone then record.zone.remove() end
            removeClerk(record.location)
        end
        clerks = {}
    elseif resource == 'kora_target' then
        -- kora_target drops its registrations on stop; forget the stale IDs.
        for _, state in pairs(active) do state.targetId = nil end
    end
end)
