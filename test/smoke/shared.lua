local H = dofile('test/harness.lua')
Config = { kora_inventory = {} }
dofile('shared.lua')

local I = KoraInventory
H.equal(I.amount('2'), 2, 'amount coerces integer')
H.equal(I.amount(0), nil, 'zero is invalid')
H.ok(I.sameInfo({ serial = 'a' }, { serial = 'a' }), 'matching metadata stacks')
H.equal(I.stackSlot({ [2] = { name = 'water', amount = 1, info = {} } }, { name = 'water', info = {} }), 2, 'find stack')
local incoming = { name = 'water', info = { quality = 50 } }
H.equal(I.canStack(nil, incoming), false, 'empty slot is not a stack')
H.equal(I.canStack({ name = 'water', unique = true, info = incoming.info }, incoming), false, 'unique stored item cannot stack')
H.equal(I.canStack({ name = 'water', info = incoming.info }, { name = 'water', unique = true, info = incoming.info }), false, 'unique incoming item cannot stack')
H.equal(I.canStack({ name = 'water', info = { quality = 70 } }, incoming), false, 'different metadata cannot stack')
H.equal(I.canStack({ name = 'bread', info = incoming.info }, incoming), false, 'different names cannot stack')
H.equal(I.canStack({ name = 'water', info = { quality = 50 } }, incoming), true, 'matching nonunique items can stack')
H.equal(I.firstFreeSlot({ [1] = {} }, 3), 2, 'first free slot')
H.equal(I.totalWeight({ [1] = { weight = 10, amount = 2 } }), 20, 'weight totals')
H.equal(I.totalWeight({ [1] = { weight = 10, amount = 2, info = { weight = 25 } } }), 50, 'metadata weight totals')
H.equal(I.totalWeight({ [1] = { weight = 10, amount = 2, info = { weight = 0 } } }), 0, 'zero metadata weight totals')
H.equal(I.totalWeight({ [1] = { weight = 10, amount = 2, info = { weight = -1 } } }), 20, 'invalid metadata weight falls back')
H.equal(I.effectiveItem({ image = 'base.png', imageUrl = 'https://base', info = { image = 'override.png' } }).imageUrl, nil, 'metadata image suppresses the base URL')
local single = { x = 1, y = 2, z = 3 }
H.equal(I.coordinateList(single)[1], single, 'one coordinate becomes a one-entry list')
local many = { single, { x = 4, y = 5, z = 6 } }
H.equal(#I.coordinateList(many), 2, 'a coordinate list retains every valid fixture')
H.equal(#I.coordinateList({}), 0, 'an empty coordinate policy fails closed')
H.equal(#I.coordinateList('invalid'), 0, 'a malformed coordinate policy fails closed')
H.equal(I.coordinateList(nil), nil, 'nil remains the no-coordinate-policy form')
H.finish()
