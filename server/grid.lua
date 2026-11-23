local I = KoraInventory
local grid = {}
local types = { player = true, stash = true, trunk = true, glovebox = true, container = true, evidence = true, temporary = true }

local function dimension(value)
    return type(value) == 'number' and value >= 1 and value <= 64 and value % 1 == 0 and value or nil
end

function grid.enabled()
    local settings = Config.kora_inventory.grid
    return type(settings) == 'table' and settings.enabled == true
end

function grid.columns(inv)
    if grid.enabled() and types[inv.type] and inv.slots > 0 then
        return math.min(inv.slots, dimension(Config.kora_inventory.grid.columns) or 6)
    end
end

function grid.size(def)
    def = def or {}
    local width, height = dimension(def.gridWidth), dimension(def.gridHeight)
    if width or height then return width or 1, height or 1 end
    if def.type ~= 'weapon' or def.weapontype == 'Throwable' then return 1, 1 end
    local ammoType = def.ammotype or def.ammoType
    if ammoType == 'AMMO_PISTOL' or ammoType == 'AMMO_STUNGUN' then return 2, 1 end
    if ammoType == 'AMMO_SMG' then return 3, 1 end
    if ammoType then return 4, 2 end
    return 1, 1
end

function grid.shape(item, def, rotated)
    local width, height = grid.size(def)
    item.gridWidth, item.gridHeight = width, height
    item.gridRotated = rotated == true and width ~= height or nil
    if item.gridRotated then
        item.gridWidth, item.gridHeight = height, width
    end
end

local function cells(occupied, columns, slots, slot, width, height)
    if not I.validSlot(slot, slots) or (slot - 1) % columns + width > columns
        or slot + (height - 1) * columns + width - 1 > slots then
        return false
    end
    for row = 0, height - 1 do
        for col = 0, width - 1 do
            if occupied[slot + row * columns + col] then return false end
        end
    end
    return true
end

local function mark(occupied, columns, slot, width, height)
    for row = 0, height - 1 do
        for col = 0, width - 1 do
            occupied[slot + row * columns + col] = slot
        end
    end
end

function grid.layout(items, slots, columns, ignoreSlot)
    local occupied, shapes = {}, {}
    -- Claim every anchor before evaluating stored rectangles. Existing items
    -- stay reachable when an operator changes columns or re-enables the grid.
    for slot in pairs(items) do
        if slot ~= ignoreSlot then occupied[slot] = slot end
    end
    for slot = 1, slots do
        local item = slot ~= ignoreSlot and items[slot]
        if item then
            local width, height = dimension(item.gridWidth) or 1, dimension(item.gridHeight) or 1
            occupied[slot] = nil
            if not cells(occupied, columns, slots, slot, width, height) then
                width, height = 1, 1
            end
            shapes[slot] = { width, height, item.gridRotated == true }
            mark(occupied, columns, slot, width, height)
        end
    end
    return occupied, shapes
end

function grid.reserve(items, slots, columns, item, slot, count, ignoreSlot, firstSlot)
    local occupied = grid.layout(items, slots, columns, ignoreSlot)
    local width, height = dimension(item.gridWidth) or 1, dimension(item.gridHeight) or 1
    local result = {}
    if slot then
        if not cells(occupied, columns, slots, slot, width, height) then return result end
        result[1] = slot
        mark(occupied, columns, slot, width, height)
    end
    for candidate = firstSlot or 1, slots do
        if #result == count then break end
        if cells(occupied, columns, slots, candidate, width, height) then
            result[#result + 1] = candidate
            mark(occupied, columns, candidate, width, height)
        end
    end
    return result
end

function grid.valid(items, slots, columns)
    local occupied = {}
    for slot, item in pairs(items) do
        local width, height = dimension(item.gridWidth) or 1, dimension(item.gridHeight) or 1
        if not cells(occupied, columns, slots, slot, width, height) then return false end
        mark(occupied, columns, slot, width, height)
    end
    return true
end

function grid.replacement(inv, nextItems, itemDef, restoring)
    local columns = grid.columns(inv)
    if not columns then return true end
    -- A confiscation return replays the player's own saved anchor layout.
    local _, shapes = grid.layout(restoring and nextItems or inv.items, inv.slots, columns)
    for slot, item in pairs(nextItems) do
        local def = type(item) == 'table' and itemDef(item.name)
        if type(slot) ~= 'number' or slot % 1 ~= 0 or not def then
            return false
        end
        local previous, shape = inv.items[slot], shapes[slot]
        if shape and (restoring or previous.name == item.name) then
            item.gridWidth, item.gridHeight, item.gridRotated = shape[1], shape[2], shape[3] or nil
        else
            grid.shape(item, def, item.gridRotated)
        end
    end
    return grid.valid(nextItems, inv.slots, columns)
end

I.grid = grid
