-- Contract coverage for the two access paths most likely to become unsafe
-- during compatibility work: another player's inventory and owner-scoped
-- stashes. Runtime callbacks require FXServer, so these assertions lock the
-- public authority shape without pretending an offline test can grant access.
local H = dofile('test/harness.lua')

local function read(path)
    local file = assert(io.open(path, 'r'))
    local source = file:read('*a')
    file:close()
    return source
end

local server = read('server.lua')
local config = read('config.lua')
local docs = read('docs.md')

-- Inspection is opt-in and proximity cannot be used as an implicit grant.
H.ok(config:find('playerInspection = { access = nil }', 1, true), 'inspection starts default-deny')
H.ok(server:find("return allowed, allowed and nil or 'player inspection not authorised'", 1, true), 'inspection requires an explicit trusted grant')
H.ok(server:find('if I.isCallable(policy.access) then', 1, true), 'configured inspection policy must be executable server code')
H.ok(server:find('pcall(callback, src, target', 1, true), 'inspection policies are isolated from authority errors')
H.ok(server:find("if result == false then return false, reason or 'player inspection denied' end", 1, true), 'one inspection policy can veto access')
H.ok(server:find('I.copy(playerData(src) or {})', 1, true), 'inspection policies receive detached source data')
H.ok(server:find('I.copy(playerData(target) or {})', 1, true), 'inspection policies receive detached target data')
H.ok(server:find('if not sameBucket(src, inv.source)', 1, true), 'inspection validates routing bucket before policy')
H.ok(server:find('QB.distance.player(src, GetEntityCoords(GetPlayerPed(inv.source)), C.interactionDistance)', 1, true), 'inspection validates live target distance before policy')
H.ok(server:find('return mayInspectPlayer(src, inv.source)', 1, true), 'player access funnels through inspection policy')

-- owner=true is a server registration template. The concrete stash namespace
-- must be derived from the opener's citizen id rather than any client field.
H.ok(server:find("local ownedStashTemplates = {}", 1, true), 'owned stash registrations are templates')
H.ok(server:find("if owner == true then\n        ownedStashTemplates[tostring(id)] = opts", 1, true), 'owner=true stores only a template')
H.ok(server:find("type(data.citizenid) ~= 'string' or data.citizenid == ''", 1, true), 'owned stash requires a server player identity')
H.ok(server:find('opts.owner = data.citizenid', 1, true), 'owned stash owner derives from qbcore player data')
H.ok(server:find("('%s:%s'):format(tostring(identifier), data.citizenid)", 1, true), 'owned stash key includes the derived citizen id')
H.ok(server:find("inv.owner ~= src and inv.owner ~= data.citizenid", 1, true), 'secondary owner check accepts only the authenticated owner')
H.ok(server:find("ownedStash(src, identifier, ownedStashTemplates[tostring(identifier)])", 1, true), 'network open resolves registered owned stash server-side')
H.ok(docs:find("A caller cannot choose another owner's", 1, true), 'owned stash boundary is documented')

-- One inventory id may be registered at several real-world fixtures. Both the
-- initial open and lease revalidation still funnel through canAccess.
H.ok(server:find('local function withinCoordinates(src, coords, distance)', 1, true), 'coordinate access has one shared helper')
H.ok(server:find('local points = I.coordinateList(coords)', 1, true), 'single and multi-point forms share normalisation')
H.ok(server:find('tonumber(point.distance) or distance', 1, true), 'each shared fixture may retain its own bounded interaction radius')
H.ok(server:find('if not withinCoordinates(src, inv.coords, inv.distance)', 1, true), 'all secondary access enforces the coordinate helper')
H.ok(server:find('refreshRegistration(inv, opts)', 1, true), 'stash re-registration refreshes a moved fixture boundary')
H.ok(server:find('refreshRegistration(inv, data)', 1, true), 'shop re-registration refreshes a moved fixture boundary')
H.ok(server:find('if inv then return inv, true end', 1, true), 'live shop re-registration cannot reseed and erase stock')

H.finish()
