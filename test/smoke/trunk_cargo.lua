-- Trunk cargo is cosmetic. This covers the pure helpers in
-- shared/trunk_cargo.lua (model resolution, boot bounds, shelf packing) and
-- the config default, without FXServer.
local H = dofile('test/harness.lua')

local defs = {
    water_bottle = { name = 'water_bottle', type = 'item' },
    bread = { name = 'bread', type = 'item' },
    crate = { name = 'crate', type = 'item', dropProp = 'prop_box_wood02a' },
    weapon_pistol = { name = 'weapon_pistol', type = 'weapon' },
}
exports = { kora_core = {} }
function exports.kora_core:getShared(kind, name)
    local def = defs[name]
    if kind == 'weapons' then return def and def.type == 'weapon' and def or nil end
    return def and def.type ~= 'weapon' and def or nil
end

Config = { kora_inventory = { vehicles = { trunkCargo = {
    enabled = true,
    fallbackModel = 'prop_med_bag_01b',
    models = { water_bottle = 'prop_ld_flow_bottle', bad = 'not a model!' },
} } } }

KoraInventory = nil
dofile('shared/trunk_cargo.lua')
local inv = KoraInventory

-- cargoVisual: overrides, weapons, item props, fallback, and refusals.
H.equal(inv.cargoVisual('water_bottle').model, 'prop_ld_flow_bottle', 'config override wins')
H.equal(inv.cargoVisual('WATER_BOTTLE').model, 'prop_ld_flow_bottle', 'names are case-insensitive')
H.equal(inv.cargoVisual('weapon_pistol').weapon, 'weapon_pistol', 'weapons render as their weapon model')
H.equal(inv.cargoVisual('crate').model, 'prop_box_wood02a', 'definition dropProp is used')
H.equal(inv.cargoVisual('bread').model, 'prop_med_bag_01b', 'unknown props use the fallback')
H.equal(inv.cargoVisual('nope'), nil, 'unknown items render nothing')
H.equal(inv.cargoVisual('bad name'), nil, 'malformed names are refused')
H.equal(inv.cargoVisual(('x'):rep(65)), nil, 'overlong names are refused')
H.equal(inv.cargoVisual(42), nil, 'non-string names are refused')

-- cargoBounds: a valid model box yields a smaller box inside it.
local min, max = { x = -1, y = -2.5, z = -0.6 }, { x = 1, y = 2.5, z = 0.9 }
local rear = inv.cargoBounds(min, max, false, nil, {})
H.ok(rear, 'rear boot bounds are produced')
for _, axis in ipairs({ 'x', 'y', 'z' }) do
    H.ok(rear.min[axis] >= min[axis] and rear.max[axis] <= max[axis], 'rear bounds stay inside the model on ' .. axis)
    H.ok(rear.max[axis] > rear.min[axis], 'rear bounds are non-empty on ' .. axis)
end
H.ok(rear.max.y < 0, 'a rear boot sits behind the centre')
local front = inv.cargoBounds(min, max, true, nil, {})
H.ok(front and front.min.y > 0, 'a front boot sits ahead of the centre')
H.equal(inv.cargoBounds({ x = 0, y = 0, z = 0 }, { x = 0, y = 1, z = 1 }, false), nil, 'a flat model box is refused')
local override = { min = { x = -0.5, y = -2, z = 0 }, max = { x = 0.5, y = -1, z = 0.5 } }
H.equal(inv.cargoBounds(min, max, false, override).min.y, -2, 'an in-model override is used as-is')
H.equal(inv.cargoBounds(min, max, false, { min = { x = -5, y = -2, z = 0 }, max = override.max }), nil,
    'an override outside the model is refused')

-- cargoLayout: deterministic, bounded, never overflows the volume.
local volume = { min = { x = 0, y = 0, z = 0 }, max = { x = 1, y = 1, z = 1 } }
local small = { min = { x = -0.1, y = -0.1, z = 0 }, max = { x = 0.1, y = 0.1, z = 0.2 } }
local entries = {}
for slot = 1, 30 do entries[#entries + 1] = { slot = slot, min = small.min, max = small.max } end
local poses = inv.cargoLayout(volume, entries)
local count = 0
for slot, pose in pairs(poses) do
    count = count + 1
    H.ok(slot <= 24, 'only the first 24 entries are considered')
    H.ok(pose.pos.x >= -1e-9 and pose.pos.y >= -1e-9 and pose.pos.z >= -1e-9, 'pose starts inside the volume')
end
H.ok(count > 0 and count <= 24, 'some props are placed and never more than 24')
local huge = { slot = 1, min = { x = -2, y = -2, z = 0 }, max = { x = 2, y = 2, z = 2 } }
H.equal(next(inv.cargoLayout(volume, { huge })), nil, 'an oversized prop is simply not drawn')
H.equal(next(inv.cargoLayout(nil, entries)), nil, 'a missing volume places nothing')
local again = inv.cargoLayout(volume, entries)
H.equal(again[1].pos.x, poses[1].pos.x, 'layout is deterministic')

-- Shipped default is off.
local file = assert(io.open('config.lua', 'r'))
local source = file:read('*a')
file:close()
H.ok(source:find('trunkCargo = {%s*enabled = false,'), 'trunk cargo ships disabled')

H.finish()
