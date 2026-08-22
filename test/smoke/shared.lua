local H = dofile('test/harness.lua')
Config = { qbinventory = {} }
dofile('shared.lua')

local I = QbInventory
H.equal(I.amount('2'), 2, 'amount coerces integer')
H.equal(I.amount(0), nil, 'zero is invalid')
H.ok(I.sameInfo({ serial = 'a' }, { serial = 'a' }), 'matching metadata stacks')
H.equal(I.stackSlot({ [2] = { name = 'water', amount = 1, info = {} } }, { name = 'water', info = {} }), 2, 'find stack')
H.equal(I.firstFreeSlot({ [1] = {} }, 3), 2, 'first free slot')
H.equal(I.totalWeight({ [1] = { weight = 10, amount = 2 } }), 20, 'weight totals')
H.finish()
