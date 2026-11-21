-- The /config schema for layouts, quick slots, ammo info, UI QoL and trunk
-- cargo. Loads config.lua and config/schema/core_features.lua with a recording
-- stub of Kora.config (no kora_lib needed).
local H = dofile('test/harness.lua')

-- Guard: without Kora the file returns cleanly and registers nothing.
Kora = nil
Config = { kora_inventory = { ui = {} } }
dofile('config/schema/core_features.lua')
H.equal(next(Config.kora_inventory.ui), nil, 'guard leaves config untouched without Kora')
Kora = { config = {} }
dofile('config/schema/core_features.lua')
H.equal(next(Config.kora_inventory.ui), nil, 'guard leaves config untouched without Kora.config.adopt')

local function lastTable(...)
    local last
    for index = 1, select('#', ...) do
        if type(select(index, ...)) == 'table' then last = select(index, ...) end
    end
    return last
end

local TAG = {}
local function builder(kind)
    return function(default, ...)
        local options = {}
        if kind == 'list' or kind == 'map' then
            options = select(2, ...) or {}
        elseif kind == 'object' or kind == 'optional' then
            options = select(kind == 'optional' and 2 or 1, ...) or {}
        else
            options = lastTable(...) or {}
        end
        return setmetatable({ kind = kind, default = default, options = options }, TAG)
    end
end

Kora = { util = { clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end }, config = setmetatable({
    adopt = function(value) return value end,
}, { __index = function(_, kind) return builder(kind) end }) }
Config = nil
dofile('config.lua')
dofile('config/schema/core_features.lua')

local root = Config.kora_inventory
local function entry(path)
    local node = root
    for part in path:gmatch('[^.]+') do
        node = type(node) == 'table' and node[part] or nil
    end
    H.ok(getmetatable(node) == TAG, path .. ' is registered as a descriptor')
    return node
end

local expected = {
    ['ui.layout'] = 'enum', ['ui.layouts.classic'] = 'boolean', ['ui.layouts.loadout'] = 'boolean',
    ['ui.layouts.compact'] = 'boolean', ['ui.layouts.dock'] = 'boolean', ['ui.playerLayoutChoice'] = 'boolean',
    ['quickSlots.enabled'] = 'boolean', ['quickSlots.hideWhenMissing'] = 'boolean',
    ['quickSlots.showKeyHints'] = 'boolean', ['quickSlots.inHotbarHud'] = 'boolean',
    ['weapons.ammoInfo.enabled'] = 'boolean', ['weapons.ammoInfo.where'] = 'enum',
    ['weapons.ammoInfo.showLoaded'] = 'boolean', ['weapons.ammoInfo.showCompatible'] = 'boolean',
    ['ui.rightClick'] = 'enum', ['ui.quickTransfer'] = 'boolean', ['ui.modifierDrag'] = 'boolean',
    ['ui.quickAmounts'] = 'boolean', ['ui.filters'] = 'boolean', ['ui.tooltips'] = 'boolean',
    ['ui.weightWarnings.enabled'] = 'boolean', ['ui.weightWarnings.warnAt'] = 'number',
    ['ui.weightWarnings.dangerAt'] = 'number',
    ['vehicles.trunkCargo.enabled'] = 'boolean', ['vehicles.trunkCargo.drawDistance'] = 'number',
    ['vehicles.trunkCargo.maxProps'] = 'integer', ['vehicles.trunkCargo.fallbackModel'] = 'string',
    ['vehicles.trunkCargo.models'] = 'map', ['vehicles.trunkCargo.bounds'] = 'map',
}
local restartOnly = {
    ['quickSlots.enabled'] = true, ['vehicles.trunkCargo.fallbackModel'] = true,
    ['vehicles.trunkCargo.models'] = true, ['vehicles.trunkCargo.bounds'] = true,
}

for path, kind in pairs(expected) do
    local node = entry(path)
    H.equal(node.kind, kind, path .. ' kind')
    H.ok(type(node.options.label) == 'string' and #node.options.label > 3, path .. ' has a label')
    H.ok(type(node.options.description) == 'string' and #node.options.description > 20, path .. ' has a description')
    H.equal(node.options.live == true, not restartOnly[path], path .. ' live flag')
end

-- Defaults come from config.lua.
H.equal(entry('ui.layout').default, 'classic', 'layout default')
H.equal(entry('weapons.ammoInfo.where').default, 'both', 'ammo info default')
H.equal(entry('vehicles.trunkCargo.maxProps').default, 24, 'maxProps default')

-- Enum options must be valid, unique, labelled, and contain the default.
local enums = {
    ['ui.layout'] = { 'classic', 'loadout', 'compact', 'dock' },
    ['weapons.ammoInfo.where'] = { 'inspector', 'menu', 'both' },
    ['ui.rightClick'] = { 'split', 'menu', 'none' },
}
for path, values in pairs(enums) do
    local node = entry(path)
    local seen = {}
    for _, option in ipairs(node.options.options) do
        H.ok(type(option.value) == 'string' and type(option.label) == 'string' and option.label ~= '', path .. ' option is labelled')
        H.ok(not seen[option.value], path .. ' option unique')
        seen[option.value] = true
    end
    for _, value in ipairs(values) do H.ok(seen[value], path .. ' offers ' .. value) end
    H.equal(#node.options.options, #values, path .. ' option count')
    H.ok(seen[node.default], path .. ' default is an option')
end

-- Bounds.
for _, key in ipairs({ 'warnAt', 'dangerAt' }) do
    local o = entry('ui.weightWarnings.' .. key).options
    H.equal(o.min, 0.01, key .. ' min'); H.equal(o.max, 1, key .. ' max'); H.equal(o.step, 0.01, key .. ' step')
end
local props = entry('vehicles.trunkCargo.maxProps').options
H.equal(props.min, 1, 'maxProps min'); H.equal(props.max, 24, 'maxProps max')
H.ok(entry('vehicles.trunkCargo.fallbackModel').options.advanced, 'fallbackModel is advanced')
H.ok(entry('vehicles.trunkCargo.models').options.advanced, 'models is advanced')
H.ok(entry('vehicles.trunkCargo.bounds').options.advanced, 'bounds is advanced')
H.ok(entry('quickSlots.enabled').options.description:find('slots', 1, true), 'enabled explains slots stay file-only')

H.finish()
