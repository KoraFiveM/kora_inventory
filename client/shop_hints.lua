-- Optional world marker (and short "[ALT] Shop" text) at every fixed shop
-- interaction point, so players can see where to point kora_target. Presentation
-- only: it never opens a shop and the server still validates every open.
--
-- Points come from each shop's `locations` in Config.qbinventory.shops, so any
-- shop type with a fixed location list is covered without code changes. A shop
-- opts out with `hint = false` (or `enabled = false`). Vending machines are model
-- targets with no fixed points, so they get no marker.
--
-- Cost: one thread that sleeps 1000 ms while no point is within
-- Config.ShopHints.drawDistance and only runs per frame when one is. Coordinates
-- and the theme colour are cached; no export is called per frame.

local FALLBACK_COLOR = { r = 149, g = 255, b = 0 } -- only if kora_theme is not started
local IDLE_WAIT = 1000
local NEAR_REFRESH = 500
local FLIPPED_TYPES = { [20] = true, [21] = true, [22] = true } -- chevrons point up by default

local points = {}
local color = FALLBACK_COLOR

local function hexToColor(hex)
    if type(hex) ~= 'string' then return nil end
    local r, g, b = hex:match('^#?(%x%x)(%x%x)(%x%x)')
    if not r then return nil end
    return { r = tonumber(r, 16), g = tonumber(g, 16), b = tonumber(b, 16) }
end

-- kora_theme's theme.json is the single source of the primary colour.
local function refreshColor()
    local ok, hex = pcall(function()
        return exports.kora_theme:getPrimaryColor()
    end)
    color = ok and hexToColor(hex) or FALLBACK_COLOR
end

local function collectPoints()
    points = {}
    local config = Config.ShopHints
    if type(config) ~= 'table' or config.enabled ~= true then return end
    local zOffset = tonumber(config.marker and config.marker.zOffset) or 0.0
    for _, shop in pairs((Config.qbinventory and Config.qbinventory.shops) or {}) do
        if type(shop) == 'table' and shop.enabled ~= false and shop.hint ~= false then
            for _, location in ipairs(shop.locations or {}) do
                points[#points + 1] = { x = location.x, y = location.y, z = location.z + zOffset }
            end
        end
    end
end

local function run()
    collectPoints()
    if #points == 0 then return end
    refreshColor()

    local config = Config.ShopHints
    local marker = config.marker or {}
    local markerType = math.floor(tonumber(marker.type) or 20)
    local scale = marker.scale or { x = 0.3, y = 0.3, z = 0.3 }
    local rotation = FLIPPED_TYPES[markerType] and 180.0 or 0.0
    local alpha = math.max(0, math.min(255, math.floor(tonumber(config.alpha) or 160)))
    local drawDistance = tonumber(config.drawDistance) or 10.0
    local limit = drawDistance * drawDistance
    local bob, spin = marker.bob == true, marker.rotate == true
    local text -- resolved on first approach so locale loading order never matters

    CreateThread(function()
        local near = {}
        while true do
            local here = GetEntityCoords(PlayerPedId())
            local hadNear = #near > 0
            near = {}
            for i = 1, #points do
                local point = points[i]
                local dx, dy, dz = here.x - point.x, here.y - point.y, here.z - point.z
                if dx * dx + dy * dy + dz * dz <= limit then
                    near[#near + 1] = point
                end
            end

            if #near == 0 then
                Wait(IDLE_WAIT)
            else
                if not hadNear then
                    refreshColor()
                    if config.showText == true then text = Kora.lang('shop_hints.text') end
                end
                local textColor = { r = color.r, g = color.g, b = color.b, a = 255 }
                local untilRefresh = GetGameTimer() + NEAR_REFRESH
                while GetGameTimer() < untilRefresh do
                    local bobOffset = bob and math.sin(GetGameTimer() / 400.0) * 0.05 or 0.0
                    for i = 1, #near do
                        local point = near[i]
                        DrawMarker(markerType, point.x, point.y, point.z + bobOffset, 0.0, 0.0, 0.0, rotation, 0.0, 0.0,
                            scale.x, scale.y, scale.z, color.r, color.g, color.b, alpha, false, true, 2,
                            spin, nil, nil, false)
                        if text then
                            Kora.drawing.text3d({ x = point.x, y = point.y, z = point.z + 0.45 }, text, {
                                maxDistance = drawDistance,
                                color = textColor,
                            })
                        end
                    end
                    Wait(0)
                end
            end
        end
    end)
end

run()

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_theme' then refreshColor() end
end)
