local H = dofile('test/harness.lua')
local file = assert(io.open('client/ui.lua', 'r'))
local source = file:read('*a')
file:close()

H.ok(source:find("type%(payload%.patch%) == 'table'"),
    'unwraps the client transport { token, patch } envelope')
H.ok(source:find('token, patch = payload.token, payload.patch', 1, true),
    'keeps the session token paired with the inner authoritative patch')
H.ok(source:find("send('qbinventory:nui:sessionPatched', wire)", 1, true),
    'forwards the normalised authoritative patch to the browser')
H.ok(source:find("'qbinventory:client:itemBox'", 1, true),
    'relays inventory-owned item receipt payloads to the bundled UI')
H.ok(source:find("send('qbinventory:nui:itemBox', payload)", 1, true),
    'item receipts can render without an inventory session')
H.ok(source:find("QB.notify.send({", 1, true),
    'rejected inventory actions are presented as notifications')

Config = {}
dofile('config.lua')
local images = Config.qbinventory.ui.images
H.equal(images.localPath, 'nui://qbinventory/images', 'artwork uses qbinventory NUI paths')
H.equal(images.preferLocal, true, 'bundled artwork is preferred over remote fallbacks')

local canonicalImage = io.open('images/advancedlockpick.png', 'rb')
H.ok(canonicalImage ~= nil, 'canonical qb-inventory artwork is bundled')
if canonicalImage then canonicalImage:close() end
H.finish()
