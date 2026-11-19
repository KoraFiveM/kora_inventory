KoraInventory = KoraInventory or {}
local inventory = KoraInventory

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function point(value)
    local kind = type(value)
    return (kind == 'table' or kind == 'vector3') and finite(value.x) and finite(value.y) and finite(value.z)
end

local function model(value)
    if type(value) == 'string' then
        return #value > 0 and #value <= 64 and value:match('^[%w_]+$') and value or nil
    end
    return finite(value) and value % 1 == 0 and value >= -2147483648 and value <= 4294967295 and value or nil
end

-- Resolve definitions at use time; no slot metadata may request a model.
function inventory.cargoVisual(name)
    if type(name) ~= 'string' or #name == 0 or #name > 64 or not name:match('^[%w_]+$') then return nil end
    name = name:lower()
    local definition = exports.kora_core:getShared('items', name) or exports.kora_core:getShared('weapons', name)
    if type(definition) ~= 'table' then return nil end
    local config = Config.kora_inventory.vehicles.trunkCargo or {}
    local override = model((config.models or {})[name])
    if override then return { model = override } end
    if definition.type == 'weapon' then return { weapon = name } end
    local prop = model(definition.dropProp) or model(definition.dropmodel) or model(config.fallbackModel)
    return prop and { model = prop } or nil
end

local function box(minimum, maximum)
    if not point(minimum) or not point(maximum) then return nil end
    for _, axis in ipairs({ 'x', 'y', 'z' }) do
        if maximum[axis] - minimum[axis] < 0.01 then return nil end
    end
    return { min = minimum, max = maximum }
end

local function average(a, b)
    if point(a) and point(b) then
        return { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
    end
    return point(a) and a or point(b) and b or nil
end

-- Static dimensions and wheel/seat bones keep an open lid from moving cargo.
function inventory.cargoBounds(minimum, maximum, frontBoot, override, bones)
    if not box(minimum, maximum) then return nil end
    if override ~= nil then
        if type(override) ~= 'table' or not box(override.min, override.max) then return nil end
        for _, axis in ipairs({ 'x', 'y', 'z' }) do
            if override.min[axis] < minimum[axis] or override.max[axis] > maximum[axis] then return nil end
        end
        return { min = override.min, max = override.max }
    end
    bones = bones or {}
    local width, length, height = maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z
    local left = frontBoot and bones.wheel_lf or bones.wheel_lr
    local right = frontBoot and bones.wheel_rf or bones.wheel_rr
    local axle = average(left, right)
    local centreX, halfWidth = (minimum.x + maximum.x) / 2, width * 0.34
    if point(left) and point(right) then halfWidth = math.min(halfWidth, math.abs(left.x - right.x) * 0.43) end
    local lowY, highY
    if frontBoot then
        lowY, highY = maximum.y - length * 0.25, maximum.y - length * 0.08
    else
        lowY, highY = minimum.y + length * 0.08, minimum.y + length * 0.30
        if axle then highY = math.min(highY, axle.y - 0.10) end
        local seat = average(bones.seat_dside_r, bones.seat_pside_r)
        if seat then highY = math.min(highY, seat.y - 0.30) end
    end
    local floor = minimum.z + height * 0.33
    if axle then floor = math.max(floor, axle.z + height * 0.12) end
    local ceiling = math.min(maximum.z - height * 0.20, floor + height * 0.32)
    -- shortcut: generic cavities are conservative estimates; calibrate custom models with bounds overrides.
    return box(
        { x = centreX - halfWidth, y = lowY, z = floor },
        { x = centreX + halfWidth, y = highY, z = ceiling }
    )
end

local function oriented(minimum, maximum, flat, turned)
    local low = { x = math.huge, y = math.huge, z = math.huge }
    local high = { x = -math.huge, y = -math.huge, z = -math.huge }
    for _, x in ipairs({ minimum.x, maximum.x }) do
        for _, y in ipairs({ minimum.y, maximum.y }) do
            for _, z in ipairs({ minimum.z, maximum.z }) do
                local px, py, pz = x, y, z
                if flat then py, pz = -pz, py end
                if turned then px, py = -py, px end
                low.x, low.y, low.z = math.min(low.x, px), math.min(low.y, py), math.min(low.z, pz)
                high.x, high.y, high.z = math.max(high.x, px), math.max(high.y, py), math.max(high.z, pz)
            end
        end
    end
    return low, high
end

-- Bounded shelf packing. Each upper shelf is supported by one whole prop.
-- Failing to display an oversized item never changes inventory capacity/data.
function inventory.cargoLayout(volume, entries)
    local poses = {}
    if type(volume) ~= 'table' or not box(volume.min, volume.max) or type(entries) ~= 'table' then return poses end
    local gap = 0.01
    local function shelf(minimum, maximum, z)
        return { min = minimum, max = maximum, x = minimum.x, y = minimum.y, depth = 0, z = z }
    end
    local shelves = { shelf(volume.min, volume.max, volume.min.z) }
    local ordered = {}
    for index = 1, math.min(#entries, 24) do
        local entry = entries[index]
        if type(entry) == 'table' and finite(entry.slot) and entry.slot >= 1 and entry.slot % 1 == 0
            and box(entry.min, entry.max) then ordered[#ordered + 1] = entry end
    end
    table.sort(ordered, function(a, b) return a.slot < b.slot end)
    for _, entry in ipairs(ordered) do
        if not poses[entry.slot] then
            local placed = false
            for _, surface in ipairs(shelves) do
                if placed then break end
                for _, turned in ipairs({ false, true }) do
                    local low, high = oriented(entry.min, entry.max, entry.flat == true, turned)
                    local width, depth, height = high.x - low.x, high.y - low.y, high.z - low.z
                    local x, y, rowDepth = surface.x, surface.y, surface.depth
                    if x + width > surface.max.x then
                        x, y, rowDepth = surface.min.x, surface.y + surface.depth + gap, 0
                    end
                    if x + width <= surface.max.x and y + depth <= surface.max.y
                        and surface.z + height <= volume.max.z then
                        poses[entry.slot] = {
                            pos = { x = x - low.x, y = y - low.y, z = surface.z - low.z },
                            rot = { x = entry.flat and 90.0 or 0.0, y = 0.0, z = turned and 90.0 or 0.0 },
                        }
                        surface.x, surface.y, surface.depth = x + width + gap, y, math.max(rowDepth, depth)
                        shelves[#shelves + 1] = shelf({ x = x, y = y }, { x = x + width, y = y + depth }, surface.z + height + gap)
                        placed = true
                        break
                    end
                end
            end
        end
    end
    return poses
end
