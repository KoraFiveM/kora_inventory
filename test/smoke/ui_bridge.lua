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
H.finish()
