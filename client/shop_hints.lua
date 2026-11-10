-- Optional world marker (and short "[ALT] Shop" text) at fixed shop interaction
-- points, so players can see where to point kora_target. Presentation only: it
-- never opens a shop and the server still validates every open.
-- Counters served by a ped get no marker by default: the clerk or Ammu-Nation
-- shopkeeper is the cue there (Config.ShopHints.markerAtPeds). A point with
-- neither marker nor text gets no zone at all.
-- This file is the only place that draws the "[ALT] Shop" text. It is off by
-- default (Config.ShopHints.showText) and, when enabled, is still dropped at any
-- counter served by a ped - 24/7, liquor or Ammu-Nation - unless
-- Config.ShopClerks.showLabel (see KoraInventory.shopHasClerk).
--
-- Points come from each shop's `locations` in Config.kora_inventory.shops, so any
-- shop type with a fixed location list is covered without code changes. A shop
-- opts out with `hint = false` (or `enabled = false`). Vending machines are model
-- targets with no fixed points, so they get no marker.
--
-- Cost: one Kora.zones sphere (radius Config.ShopHints.drawDistance) per point.
-- Nothing runs while the player is far from every point; a per-frame draw thread
-- starts when the first sphere is entered and ends when the last one is left.
-- Coordinates and the theme colour are cached; no export is called per frame.

local FALLBACK_COLOR = { r = 149, g = 255, b = 0 } -- only if kora_theme is not started
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
    local clerkLabel = Config.ShopClerks and Config.ShopClerks.showLabel == true
    local config = Config.ShopHints
    if type(config) ~= 'table' or config.enabled ~= true then return end
    local markerAtPeds = config.markerAtPeds == true
    local showText = config.showText == true
    local zOffset = tonumber(config.marker and config.marker.zOffset) or 0.0
    for _, shop in pairs((Config.kora_inventory and Config.kora_inventory.shops) or {}) do
        if type(shop) == 'table' and shop.enabled ~= false and shop.hint ~= false then
            for _, location in ipairs(shop.locations or {}) do
                local hasPed = KoraInventory and KoraInventory.shopHasClerk and KoraInventory.shopHasClerk(shop, location)
                local noMarker = hasPed and not markerAtPeds
                local noText = not showText or (hasPed and not clerkLabel)
                if not (noMarker and noText) then
                    points[#points + 1] = {
                        x = location.x, y = location.y, z = location.z + zOffset,
                        noMarker = noMarker or nil,
                        noText = noText or nil,
                    }
                end
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
    if drawDistance <= 0 then return end
    local bob, spin = marker.bob == true, marker.rotate == true
    local text -- resolved on first approach so locale loading order never matters

    local near = {} -- points whose sphere the player is inside
    local drawing = false

    local function draw()
        refreshColor()
        if config.showText == true then text = Kora.lang('shop_hints.text') end
        local textColor = { r = color.r, g = color.g, b = color.b, a = 255 }
        while #near > 0 do
            local bobOffset = bob and math.sin(GetGameTimer() / 400.0) * 0.05 or 0.0
            for i = 1, #near do
                local point = near[i]
                if not point.noMarker then
                    DrawMarker(markerType, point.x, point.y, point.z + bobOffset, 0.0, 0.0, 0.0, rotation, 0.0, 0.0,
                        scale.x, scale.y, scale.z, color.r, color.g, color.b, alpha, false, true, 2,
                        spin, nil, nil, false)
                end
                if text and not point.noText then
                    Kora.drawing.text3d({ x = point.x, y = point.y, z = point.z + 0.45 }, text, {
                        maxDistance = drawDistance,
                        color = textColor,
                    })
                end
            end
            Wait(0)
        end
        drawing = false
    end

    for i = 1, #points do
        local point = points[i]
        Kora.zones.sphere({
            coords = vector3(point.x, point.y, point.z),
            radius = drawDistance,
            onEnter = function()
                near[#near + 1] = point
                if not drawing then
                    drawing = true
                    CreateThread(draw)
                end
            end,
            onExit = function()
                for j = 1, #near do
                    if near[j] == point then
                        table.remove(near, j)
                        break
                    end
                end
            end,
        })
    end
end

run()

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_theme' then refreshColor() end
end)
