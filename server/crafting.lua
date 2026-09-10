-- Server-only crafting and weapon-state foundation.
--
-- There is intentionally no net event in this module. A gameplay resource may
-- call these exports after it has performed its own server-side station / job
-- checks, but a browser or client must never submit a recipe result, item
-- metadata, serial, durability or component list directly.

QbInventory = QbInventory or {}
local I = QbInventory
local internal = assert(I.internal, 'qbinventory authority must load before crafting')
local C, W = {}, {}
I.crafting, I.weapons = C, W

local cfg = (Config.qbinventory and Config.qbinventory.crafting) or {}
local weaponCfg = (Config.qbinventory and Config.qbinventory.weapons) or {}
local ballisticsCfg = weaponCfg.ballistics or {}
local recipes, recipeOwners, hooks, nextHookId = {}, {}, {}, 1

local function copy(value) return internal.copy(value) end
local function integer(value, fallback)
    local number = math.floor(tonumber(value) or (fallback or 0))
    return number > 0 and number or nil
end
local function itemName(value)
    return type(value) == 'string' and value:lower() or nil
end
local function owner()
    return type(GetInvokingResource) == 'function' and GetInvokingResource() or GetCurrentResourceName and GetCurrentResourceName() or 'qbinventory'
end
local function shallowlyMatches(actual, required)
    if type(required) ~= 'table' then return actual == required end
    if type(actual) ~= 'table' then return false end
    for key, value in pairs(required) do
        if not shallowlyMatches(actual[key], value) then return false end
    end
    return true
end
local function sortedSlots(items)
    local slots = {}
    for slot in pairs(items or {}) do slots[#slots + 1] = tonumber(slot) end
    table.sort(slots)
    return slots
end
local function invoke(callback, ...)
    local result = table.pack(pcall(callback, ...))
    if not result[1] then
        print(('^3[qbinventory:crafting]^7 callback failed: %s'):format(tostring(result[2])))
        return false, 'crafting policy failed'
    end
    if result[2] == false then return false, result[3] or 'crafting denied' end
    return true
end

local function normaliseIngredients(raw)
    local out = {}
    if type(raw) ~= 'table' then return nil, 'recipe ingredients are required' end
    local array = #raw > 0
    for key, value in pairs(raw) do
        local row
        if array then row = value
        elseif type(value) == 'table' then
            row = copy(value)
            row.name = row.name or key
        else row = { name = key, amount = value } end
        if type(row) ~= 'table' then return nil, 'invalid recipe ingredient' end
        local name = itemName(row.name or row.item)
        local amount = integer(row.amount or row.count, 1)
        if not name or not amount or not internal.itemDef(name) then return nil, 'unknown recipe ingredient' end
        out[#out + 1] = { name = name, amount = amount, metadata = copy(row.metadata or row.info or {}) }
    end
    if #out == 0 then return nil, 'recipe ingredients are required' end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function normaliseOutput(raw)
    if type(raw) ~= 'table' then return nil, 'recipe output is required' end
    local name = itemName(raw.name or raw.item)
    local amount = integer(raw.amount or raw.count, 1)
    if not name or not amount or not internal.itemDef(name) then return nil, 'unknown recipe output' end
    return { name = name, amount = amount, metadata = copy(raw.metadata or raw.info or {}) }
end

local function normaliseOutputs(recipe)
    local raw = recipe.outputs or recipe.give
    if raw == nil then
        local output, err = normaliseOutput(recipe.output or recipe.result)
        return output and { output } or nil, err
    end
    if type(raw) ~= 'table' or #raw == 0 then return nil, 'recipe outputs are required' end
    local outputs = {}
    for _, value in ipairs(raw) do
        local output, err = normaliseOutput(value)
        if not output then return nil, err end
        outputs[#outputs + 1] = output
    end
    return outputs
end

local function normaliseRecipe(id, recipe)
    if type(id) ~= 'string' or id == '' or #id > 96 or not id:match('^[%w_.%-]+$') then return nil, 'invalid recipe id' end
    if type(recipe) ~= 'table' then return nil, 'recipe must be a table' end
    local ingredients, ingredientErr = normaliseIngredients(recipe.ingredients or recipe.items)
    if not ingredients then return nil, ingredientErr end
    local outputs, outputErr = normaliseOutputs(recipe)
    if not outputs then return nil, outputErr end
    return {
        id = id,
        label = type(recipe.label) == 'string' and recipe.label or id,
        ingredients = ingredients,
        -- Keep `output` for existing single-output consumers while `outputs`
        -- is the canonical form used by the transaction planner.
        output = outputs[1],
        outputs = outputs,
        -- This callback is registered by a server resource. It can inspect
        -- server-owned station/context data, but cannot alter planned items.
        access = I.isCallable(recipe.access) and recipe.access or nil,
        station = type(recipe.station) == 'string' and recipe.station or nil,
    }
end

---Register a static, server-owned recipe. Re-registering another resource's
---recipe is refused so stop/cleanup cannot leave a hostile replacement.
function C.register(id, recipe)
    local parsed, err = normaliseRecipe(id, recipe)
    if not parsed then return false, err end
    local resource = owner()
    if recipes[id] and recipeOwners[id] ~= resource then return false, 'recipe is owned by another resource' end
    recipes[id], recipeOwners[id] = parsed, resource
    return true
end

function C.remove(id)
    if not recipes[id] then return false end
    local resource = owner()
    if recipeOwners[id] ~= resource then return false, 'not recipe owner' end
    recipes[id], recipeOwners[id] = nil, nil
    return true
end

function C.get(id)
    return recipes[id] and copy(recipes[id]) or nil
end

function C.registerHook(callback)
    assert(I.isCallable(callback), 'craft hook is required')
    local id = nextHookId
    nextHookId = nextHookId + 1
    hooks[id] = { callback = callback, owner = owner() }
    return id
end

function C.removeHook(id)
    local hook = hooks[tonumber(id)]
    if not hook then return false end
    if hook.owner ~= owner() then return false, 'not hook owner' end
    hooks[tonumber(id)] = nil
    return true
end

local function consume(items, ingredient)
    local remaining = ingredient.amount
    for _, slot in ipairs(sortedSlots(items)) do
        local item = items[slot]
        if item and itemName(item.name) == ingredient.name and shallowlyMatches(item.info or item.metadata or {}, ingredient.metadata) then
            local taking = math.min(remaining, tonumber(item.amount) or 0)
            if taking > 0 then
                if taking == item.amount then items[slot] = nil else item.amount = item.amount - taking end
                remaining = remaining - taking
                if remaining == 0 then return true end
            end
        end
    end
    return false, 'missing crafting ingredient: ' .. ingredient.name
end

local function componentAllowList(name)
    local components = weaponCfg.components or {}
    return components[name] or components.default
end

function W.isWeapon(item)
    local name = itemName(type(item) == 'table' and item.name or item)
    local definition = name and internal.itemDef(name) or nil
    return definition ~= nil and (definition.type == 'weapon' or name:sub(1, 7) == 'weapon_')
end

local function normaliseComponents(name, raw)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return nil, 'invalid weapon components' end
    if next(raw) == nil then return {} end
    local allowed = componentAllowList(name)
    if type(allowed) ~= 'table' then return nil, 'weapon components are not configured' end
    local allow = {}
    for key, value in pairs(allowed) do allow[itemName(type(key) == 'number' and value or key)] = value ~= false end
    local out, seen = {}, {}
    for key, value in pairs(raw) do
        local component = itemName(type(key) == 'number' and value or key)
        if not component or not allow[component] then return nil, 'weapon component is not allowed' end
        if not seen[component] then out[#out + 1], seen[component] = component, true end
    end
    table.sort(out)
    return out
end

local function serial(name)
    local prefix = tostring(weaponCfg.serialPrefix or 'QB'):upper():gsub('[^A-Z0-9]', ''):sub(1, 12)
    return ('%s-%s-%d-%06d'):format(prefix ~= '' and prefix or 'QB', name:upper():gsub('[^A-Z0-9]', ''):sub(1, 16), os.time(), math.random(0, 999999))
end

-- A cartridge identifier is deliberately unrelated to a firearm serial.  A
-- recovered casing is linked to a weapon only by the protected police record,
-- never by simply reading an item tooltip or a client event payload.
local function roundId()
    return ('RD-%d-%06d-%06d'):format(os.time(), math.random(0, 999999), math.random(0, 999999))
end

local function roundMetadata(ammoType, legacy)
    return {
        id = roundId(),
        ammoType = ammoType,
        lot = ('LOT-%06d'):format(math.random(0, 999999)),
        legacy = legacy == true or nil,
    }
end

local function normaliseLoadedBullets(info, ammo, ammoType)
    if ballisticsCfg.enabled ~= true then
        info.loadedBullets = nil
        info.ammo = math.max(0, math.floor(tonumber(ammo) or 0))
        return
    end
    local cap = math.max(0, math.floor(tonumber(ballisticsCfg.maxLoadedRounds) or 240))
    ammo = math.min(math.max(0, math.floor(tonumber(ammo) or 0)), cap)
    local out = {}
    for _, raw in ipairs(type(info.loadedBullets) == 'table' and info.loadedBullets or {}) do
        if #out >= ammo then break end
        if type(raw) == 'table' then
            out[#out + 1] = {
                id = type(raw.id) == 'string' and raw.id:sub(1, 96) or roundId(),
                ammoType = type(raw.ammoType) == 'string' and raw.ammoType:sub(1, 64) or ammoType,
                lot = type(raw.lot) == 'string' and raw.lot:sub(1, 64) or ('LOT-%06d'):format(math.random(0, 999999)),
                legacy = raw.legacy == true or nil,
            }
        end
    end
    -- Old persisted weapons had a count only.  Migrate them losslessly by
    -- giving every previously-loaded round its own (clearly marked) record.
    while #out < ammo do out[#out + 1] = roundMetadata(ammoType, true) end
    info.loadedBullets, info.ammo = out, #out
end

---Return canonical weapon metadata. Call only from server code; a supplied
---serial is retained for migration, while new weapons receive a server serial.
function W.prepareMetadata(name, metadata)
    name = itemName(name)
    if not W.isWeapon(name) then return nil, 'item is not a registered weapon' end
    local info = copy(metadata or {})
    -- qb-weapons called this field `quality`. Keep reading and mirroring it
    -- during the migration so older server scripts and persisted inventories
    -- see the value they expect while qbinventory uses `durability` internally.
    local durability = tonumber(info.durability)
    if durability == nil then durability = tonumber(info.quality) end
    if durability == nil then durability = tonumber(weaponCfg.defaultDurability) or 100 end
    info.durability = math.max(0, math.min(100, durability))
    info.quality = info.durability
    local ammo = math.floor(tonumber(info.ammo) or 0)
    ammo = math.max(0, math.min(math.floor(tonumber(weaponCfg.maxAmmo) or 10000), ammo))
    local weapon = internal.itemDef(name) or {}
    normaliseLoadedBullets(info, ammo, weapon.ammotype)
    if info.tint ~= nil then
        local tint = tonumber(info.tint)
        if tint == nil then return nil, 'invalid weapon tint' end
        info.tint = math.max(0, math.min(32, math.floor(tint)))
    end
    local components, err = normaliseComponents(name, info.components)
    if not components then
        -- Existing/migrated weapons with no component data are valid. Any
        -- supplied components must be explicitly configured.
        if info.components ~= nil then return nil, err end
        components = {}
    end
    info.components = components
    if type(info.serial) ~= 'string' or info.serial == '' or #info.serial > 96 then info.serial = serial(name) end
    return info
end

local function insertOutput(items, slots, output)
    local metadata = copy(output.metadata)
    if W.isWeapon(output.name) then
        local prepared, err = W.prepareMetadata(output.name, metadata)
        if not prepared then return false, err end
        metadata = prepared
    end
    local one, err = internal.buildItem(output.name, output.amount, nil, metadata)
    if not one then return false, err end
    if one.unique then
        for _ = 1, output.amount do
            local slot
            for candidate = 1, slots do if not items[candidate] then slot = candidate; break end end
            if not slot then return false, 'no free slot for recipe output' end
            local individual = copy(one)
            individual.amount, individual.slot = 1, slot
            -- Unique weapons must never receive a duplicated serial.
            if W.isWeapon(individual.name) then individual.info = assert(W.prepareMetadata(individual.name, {})); individual.metadata = copy(individual.info) end
            items[slot] = individual
        end
        return true
    end
    for _, slot in ipairs(sortedSlots(items)) do
        local existing = items[slot]
        if existing and itemName(existing.name) == one.name and not existing.unique and I.sameInfo(existing.info or {}, one.info or {}) then
            existing.amount = existing.amount + output.amount
            return true
        end
    end
    for slot = 1, slots do
        if not items[slot] then one.slot = slot; items[slot] = one; return true end
    end
    return false, 'no free slot for recipe output'
end

local function planCraft(src, recipe)
    local primary = internal.playerKey(src)
    local key, inventory = internal.resolveInventory(primary)
    if key ~= primary or not inventory then return nil, 'player inventory not found' end
    local planned = copy(inventory.items)
    for _, ingredient in ipairs(recipe.ingredients) do
        local removed, removeErr = consume(planned, ingredient)
        if not removed then return nil, removeErr end
    end
    for _, output in ipairs(recipe.outputs) do
        local inserted, insertErr = insertOutput(planned, inventory.slots, output)
        if not inserted then return nil, insertErr end
    end
    if internal.totalWeight(planned) > inventory.maxWeight then return nil, 'over weight' end
    return planned, nil, primary
end

---Report whether the current inventory can complete a registered transaction.
---Access callbacks and hooks are deliberately not run by this read-only query.
function C.canCraft(src, recipeId)
    src = tonumber(src)
    local recipe = recipes[recipeId]
    if not src or not recipe then return false, 'unknown recipe' end
    local primary = internal.playerKey(src)
    return internal.lock({ primary }, function()
        local planned, err = planCraft(src, recipe)
        return planned ~= nil, err
    end)
end

---Craft from static data only. `context` is opaque, trusted server context for
---the recipe access callback; never wire a raw client/NUI payload here.
function C.craft(src, recipeId, context)
    src = tonumber(src)
    local recipe = recipes[recipeId]
    if not src or not recipe then return false, 'unknown recipe' end
    if recipe.access then
        local allowed, err = invoke(recipe.access, src, copy(recipe), context)
        if not allowed then return false, err end
    end
    local primary = internal.playerKey(src)
    return internal.lock({ primary }, function()
        local planned, planErr, inventoryKey = planCraft(src, recipe)
        if not planned then return false, planErr end
        for _, hook in pairs(hooks) do
            local allowed, hookErr = invoke(hook.callback, {
                source = src, recipe = copy(recipe), inventory = inventoryKey, context = context,
            })
            if not allowed then return false, hookErr end
        end
        local committed, commitErr = internal.setInventoryItems(inventoryKey, planned)
        if not committed then return false, commitErr end
        local result = #recipe.outputs == 1 and copy(recipe.output) or copy(recipe.outputs)
        TriggerEvent('qbinventory:server:crafted', src, recipe.id, result)
        return true, result
    end)
end

local function replaceWeaponState(src, slot, mutate)
    src, slot = tonumber(src), math.floor(tonumber(slot) or 0)
    if not src or slot < 1 then return false, 'invalid weapon slot' end
    local primary = internal.playerKey(src)
    return internal.lock({ primary }, function()
        local key, inventory = internal.resolveInventory(primary)
        if key ~= primary or not inventory then return false, 'player inventory not found' end
        local item = inventory.items[slot]
        if not item or not W.isWeapon(item) then return false, 'weapon not found' end
        local nextInfo = copy(item.info or item.metadata or {})
        local ok, err = mutate(nextInfo, item)
        if ok == false then return false, err end
        local prepared, prepareErr = W.prepareMetadata(item.name, nextInfo)
        if not prepared then return false, prepareErr end
        local planned = copy(inventory.items)
        planned[slot].info, planned[slot].metadata = prepared, copy(prepared)
        local committed, commitErr = internal.setInventoryItems(primary, planned)
        if not committed then return false, commitErr end
        TriggerEvent('qbinventory:server:weaponStateChanged', src, slot, copy(prepared))
        return true, copy(prepared)
    end)
end

---Set only canonical weapon state fields. This is server-export-only; clients
---must ask their owning gameplay resource, which validates the action first.
function W.setState(src, slot, changes)
    if type(changes) ~= 'table' then return false, 'invalid weapon state' end
    return replaceWeaponState(src, slot, function(info, item)
        if changes.durability ~= nil then
            local durability = tonumber(changes.durability)
            if durability == nil then return false, 'invalid weapon durability' end
            info.durability = math.max(0, math.min(100, durability))
        end
        if changes.ammo ~= nil then
            local ammo = tonumber(changes.ammo)
            if ammo == nil then return false, 'invalid weapon ammo' end
            info.ammo = math.max(0, math.min(math.floor(tonumber(weaponCfg.maxAmmo) or 10000), math.floor(ammo)))
        end
        if changes.components ~= nil then
            local components, componentErr = normaliseComponents(item.name, changes.components)
            if not components then return false, componentErr end
            info.components = components
        end
        if changes.tint ~= nil then
            local tint = tonumber(changes.tint)
            if tint == nil then return false, 'invalid weapon tint' end
            info.tint = math.max(0, math.min(32, math.floor(tint)))
        end
        return true
    end)
end

function W.consumeDurability(src, slot, amount)
    amount = tonumber(amount)
    if not amount or amount <= 0 then return false, 'invalid durability amount' end
    return replaceWeaponState(src, slot, function(info)
        info.durability = math.max(0, (tonumber(info.durability) or tonumber(weaponCfg.defaultDurability) or 100) - amount)
        return true
    end)
end

function W.getState(src, slot)
    local _, inventory = internal.resolveInventory(internal.playerKey(tonumber(src)))
    local item = inventory and inventory.items[tonumber(slot)] or nil
    return item and W.isWeapon(item) and copy(item.info or item.metadata or {}) or nil
end

function W.setAmmo(src, slot, ammo) return W.setState(src, slot, { ammo = ammo }) end
function W.setComponents(src, slot, components) return W.setState(src, slot, { components = components }) end

---Load `count` independently identifiable rounds into one server-resolved
---weapon.  The caller has already proved it owns the magazine and that this
---weapon accepts its ammo type; no client metadata ever reaches this method.
function W.loadRounds(src, slot, ammoType, count)
    count = math.floor(tonumber(count) or 0)
    if count < 1 then return false, 'invalid ammunition amount' end
    return replaceWeaponState(src, slot, function(info, item)
        local def = internal.itemDef(item.name) or {}
        if def.ammotype ~= ammoType then return false, 'ammunition does not fit this weapon' end
        local bullets = type(info.loadedBullets) == 'table' and copy(info.loadedBullets) or {}
        local cap = math.min(math.floor(tonumber(weaponCfg.maxAmmo) or 10000),
            math.max(0, math.floor(tonumber(ballisticsCfg.maxLoadedRounds) or 240)))
        local accepted = math.min(count, math.max(0, cap - #bullets))
        if accepted < 1 then return false, 'weapon is full' end
        for _ = 1, accepted do bullets[#bullets + 1] = roundMetadata(ammoType, false) end
        info.loadedBullets, info.ammo = bullets, #bullets
        return true
    end)
end

---Consume exactly one server-owned round.  It returns the round plus the
---weapon's opaque identifiers for the police evidence subsystem; callers
---must not expose the returned firearm serial to a client.
function W.fireRound(src, slot)
    local fired
    local ok, stateOrErr = replaceWeaponState(src, slot, function(info, item)
        local bullets = type(info.loadedBullets) == 'table' and copy(info.loadedBullets) or {}
        if #bullets < 1 then return false, 'weapon is empty' end
        fired = table.remove(bullets, 1)
        info.loadedBullets, info.ammo = bullets, #bullets
        fired.weapon = item.name
        fired.weaponSerial = info.serial
        return true
    end)
    if not ok then return false, stateOrErr end
    return true, fired
end

AddEventHandler('onResourceStop', function(name)
    for id, recipeOwner in pairs(recipeOwners) do if recipeOwner == name then recipes[id], recipeOwners[id] = nil, nil end end
    for id, hook in pairs(hooks) do if hook.owner == name then hooks[id] = nil end end
end)

exports('RegisterCraftRecipe', C.register)
exports('RemoveCraftRecipe', C.remove)
exports('GetCraftRecipe', C.get)
exports('CanCraftRecipe', C.canCraft)
exports('CraftItem', C.craft)
exports('RegisterCraftHook', C.registerHook)
exports('RemoveCraftHook', C.removeHook)
exports('PrepareWeaponMetadata', W.prepareMetadata)
exports('GetWeaponState', W.getState)
exports('SetWeaponState', W.setState)
exports('ConsumeWeaponDurability', W.consumeDurability)
exports('SetWeaponAmmo', W.setAmmo)
exports('SetWeaponComponents', W.setComponents)
exports('LoadWeaponRounds', W.loadRounds)
exports('FireWeaponRound', W.fireRound)

return { crafting = C, weapons = W }
