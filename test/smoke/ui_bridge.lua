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
H.finish()
