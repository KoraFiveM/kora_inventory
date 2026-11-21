-- Hidden container contents while searching another player, and the validated
-- openTargetContainer intent. Real server.lua + server/containers.lua; only the
-- framework natives and kora_core are stubbed.
local H = dofile('test/harness.lua')

Config = { kora_inventory = {} }
dofile('config.lua')
dofile('shared.lua')

local function clone(value)
    local seen = {}
    local function copy(v)
        if type(v) ~= 'table' then return v end
        if seen[v] then return seen[v] end
        local out = {}
        seen[v] = out
        for k, vv in pairs(v) do out[copy(k)] = copy(vv) end
        return out
    end
    return copy(value)
end

local callbacks, handlers, netEvents, sent = {}, {}, {}, {}
Kora = {
    util = { deepClone = clone },
    resources = { serverRegistry = function() return { track = function() end, untrack = function() end } end },
    callback = { register = function(name, fn) callbacks[name] = fn end },
    distance = { player = function(source, point, distance)
        return math.abs(point.x - GetEntityCoords(GetPlayerPed(source)).x) <= distance
    end },
    sql = {},
    notify = { send = function() end },
    lang = function(key) return key end,
}
local positions = { [7] = 0, [9] = 1, [11] = 1 }
GetCurrentResourceName = function() return 'kora_inventory' end
GetInvokingResource = function() return nil end
CreateThread = function() end
RegisterCommand = function() end
AddEventHandler = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end
RegisterNetEvent = function(name, fn) netEvents[name] = fn end
TriggerClientEvent = function(name, src, ...) sent[#sent + 1] = { name = name, src = src, args = { ... } } end
TriggerEvent = function(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end
GetGameTimer = function() return 5000 end
GetPlayerPed = function(source) return source end
GetEntityCoords = function(ped) return { x = positions[ped], y = 0, z = 0 } end
GetPlayerRoutingBucket = function() return 0 end

local ITEMS = {
    phone = { name = 'phone', label = 'Phone', weight = 100, useable = true },
    backpack = { name = 'backpack', label = 'Backpack', weight = 500, unique = true },
    weed = { name = 'weed', label = 'Weed', weight = 10 },
}
local playerData = { [7] = { citizenid = 'CID-7' }, [9] = { citizenid = 'CID-9' }, [11] = { citizenid = 'CID-11' } }
local playersItems = { [7] = {}, [9] = {}, [11] = {} }
playersMetadata = {}
local registered = {}
exports = setmetatable({}, {
    __call = function(_, name, fn) registered[name] = fn end,
    __index = function(_, resource)
        return setmetatable({}, { __index = function(_, name)
            return function(_, ...)
                if resource == 'kora_core' then
                    if name == 'allShared' then return {} end
                    if name == 'getShared' then
                        local registry, item = ...
                        return registry == 'items' and ITEMS[item] or nil
                    end
                    if name == 'getPlayerData' then
                        local src, fields = ...
                        if not playerData[src] then return nil end
                        if fields and fields[1] == 'items' then
                            if fields[2] then return playersItems[src][fields[2]] end
                            return playersItems[src]
                        end
                        if fields and fields[1] == 'metadata' then return playersMetadata[src] end
                        return playerData[src]
                    end
                    if name == 'setPath' then
                        local src, path, value = ...
                        if path[1] ~= 'items' then return false, 'unsupported path' end
                        if path[2] then playersItems[src][path[2]] = value else playersItems[src] = value end
                        return true
                    end
                end
                local fn = registered[name]
                if fn then return fn(...) end
            end
        end })
    end,
})

dofile('server/persistence.lua')
dofile('server.lua')
dofile('server/containers.lua')

local I = KoraInventory.internal
local intent = callbacks['kora_inventory:server:intent']
H.ok(type(intent) == 'function', 'the intent callback is registered')

-- The searcher is allowed to look at other players for this test.
Config.kora_inventory.playerInspection.access = function() return true end

-- Target 9: a phone, a bound backpack with contents, an unbound backpack.
playersItems[9][1] = I.buildItem('phone', 1, 1, {})
playersItems[9][3] = I.buildItem('backpack', 1, 3, {})
playersItems[9][5] = I.buildItem('backpack', 1, 5, {})
local opened = KoraInventory.containers.openConfiguredItem(9, 3)
H.ok(opened, 'the target opens their own backpack (binds it)')
local containerId = playersItems[9][3].info.containerId
H.ok(type(containerId) == 'string' and containerId ~= '', 'the backpack carries a server-generated container id')
local containerKey = 'container:' .. containerId
H.ok(I.setInventoryItems(containerKey, { [1] = I.buildItem('weed', 5, 1, {}) }), 'the bag holds weed')
I.close(9, 'test')

local function deepFind(value, needle, seen)
    seen = seen or {}
    if type(value) == 'string' then return value:find(needle, 1, true) ~= nil end
    if type(value) ~= 'table' or seen[value] then return false end
    seen[value] = true
    for k, v in pairs(value) do
        if deepFind(k, needle, seen) or deepFind(v, needle, seen) then return true end
    end
    return false
end

local function search()
    positions[7], positions[9] = 0, 1
    local ok, payload = I.openInventory(7, 'player', 9)
    H.ok(ok, 'the searcher opens the target inventory')
    return payload
end

-- View: contents are hidden --------------------------------------------------

local view = search()
local bag = view.secondary.items[3]
H.equal(bag.closedContainer, true, 'the bound bag is shown closed')
H.equal(bag.openable, true, 'the bag is openable when search.openContainers is on')
H.equal(bag.useable, false, 'a closed bag has no Use action for the searcher')
H.equal(bag.container, false, 'a closed bag is not a container for the searcher')
H.equal(bag.info.containerId, nil, 'the bound container id is not in info')
H.equal(bag.metadata.containerId, nil, 'the bound container id is not in metadata')
H.equal(deepFind(view, containerId), false, 'the container id appears nowhere in the whole view payload')
H.equal(deepFind(view, 'weed'), false, 'nothing about the contents appears in the view')
H.equal(deepFind(view, 'Weed'), false, 'no content label appears in the view')
for _, row in ipairs(bag.displayMeta) do
    H.ok(row.key ~= 'containerId', 'no containerId row in the inspector metadata')
end
H.equal(view.secondary.items[5].closedContainer, true, 'an unbound bag is shown closed too (no tell)')
H.equal(view.secondary.items[1].closedContainer, nil, 'ordinary items are untouched')
H.equal(view.secondary.items[1].useable, true, 'ordinary items keep their Use action')
H.equal(view.secondary.weight, I.totalWeight(playersItems[9]), 'the inventory weight is unchanged (contents never counted)')
H.equal(bag.weight, 500, 'the bag weighs its own definition weight, not its contents')

-- The owner's own view keeps everything.
local ownOK, ownPayload = I.openSelf(9)
H.ok(ownOK, 'the owner opens their own inventory')
H.equal(ownPayload.primary.items[3].closedContainer, nil, 'the owner never sees their bag as closed')
H.equal(ownPayload.primary.items[3].info.containerId, containerId, 'the owner view is unchanged')
I.close(9, 'test')

-- Broadcast patches are concealed per viewer.
view = search()
I.openSelf(9)
view = search()
sent = {}
I.bump('player:9')
I.broadcast('player:9')
local sawSearcher, sawOwner = false, false
for _, event in ipairs(sent) do
    if event.name == 'kora_inventory:client:sessionPatched' and event.args[2].key == 'player:9' then
        local item = event.args[2].inventory.items[3]
        if event.src == 7 then
            sawSearcher = true
            H.equal(item.closedContainer, true, 'a patch to the searcher stays concealed')
            H.equal(deepFind(event.args[2], containerId), false, 'a patch to the searcher never carries the container id')
        end
        if event.src == 9 then
            sawOwner = true
            H.equal(item.closedContainer, nil, 'a patch to the owner is the full view')
            H.equal(item.info.containerId, containerId, 'the owner patch keeps the container id')
        end
    end
end
H.ok(sawSearcher, 'the searcher received a patch')
H.ok(sawOwner, 'the owner (own session) received the unconcealed patch')
I.close(7, 'test')

-- hideContainerContents = false shows the bag like any other item.
Config.kora_inventory.search.hideContainerContents = false
view = search()
H.equal(view.secondary.items[3].closedContainer, nil, 'hideContainerContents = false leaves the bag unflagged')
Config.kora_inventory.search.hideContainerContents = true
I.close(7, 'test')

-- Intent validation ----------------------------------------------------------

local function request(payload, overrides)
    local s = I.sessionOf(7)
    local req = {
        token = s and s.token or 'none', action = 'openTargetContainer', payload = payload,
        primaryRevision = I.getRevision('player:7'), secondaryRevision = I.getRevision('player:9'),
    }
    for k, v in pairs(overrides or {}) do req[k] = v end
    return req
end

view = search()
local ok, err = intent(7, request({ inventory = 'player:7', slot = 3 }))
H.equal(ok, false, 'a wrong (own) inventory id is refused')
H.equal(err, 'inventory not in session', 'the refusal says the inventory is not in the session')
ok, err = intent(7, request({ inventory = 'player:11', slot = 3 }))
H.equal(ok, false, 'another player inventory that was never granted is refused')
ok, err = intent(7, request({ inventory = 'container:' .. containerId, slot = 1 }))
H.equal(ok, false, 'a container id sent as the inventory is refused')
ok, err = intent(7, request({ slot = 3 }))
H.equal(ok, false, 'a missing inventory id is refused')

ok, err = intent(7, request({ inventory = 'player:9', slot = 3, containerId = containerId }))
H.equal(ok, false, 'a payload carrying a container id is refused outright')
H.equal(err, 'invalid request', 'it is refused as an invalid request')
ok = intent(7, request({ inventory = 'player:9', slot = 3, target = 9 }))
H.equal(ok, false, 'a payload naming a target player is refused')
ok = intent(7, request({ inventory = 'player:9', slot = 3, item = { name = 'backpack' } }))
H.equal(ok, false, 'a payload carrying an item record is refused')
ok = intent(7, request({ containerId = containerId }))
H.equal(ok, false, 'a payload with only a container id is refused')
H.equal(I.sessionOf(7).secondary, 'player:9', 'refused requests leave the search session intact')

ok, err = intent(7, request({ inventory = 'player:9', slot = 1 }))
H.equal(ok, false, 'a non-container slot is refused')
H.equal(err, 'item is not a portable container', 'the refusal names the reason')
ok = intent(7, request({ inventory = 'player:9', slot = 2 }))
H.equal(ok, false, 'an empty slot is refused')
ok = intent(7, request({ inventory = 'player:9', slot = 999 }))
H.equal(ok, false, 'an out-of-range slot is refused')
ok = intent(7, request({ inventory = 'player:9', slot = 'x' }))
H.equal(ok, false, 'a non-numeric slot is refused')

ok, err = intent(7, request({ inventory = 'player:9', slot = 5 }))
H.equal(ok, false, 'an unbound container is refused')
H.equal(err, 'container is empty', 'the refusal says it is empty')

ok, err = intent(7, request({ inventory = 'player:9', slot = 3 }, { secondaryRevision = 999 }))
H.equal(ok, false, 'a stale revision is refused')
H.equal(err, 'stale source inventory', 'stale revisions are checked like a move out of the searched inventory')
ok, err = intent(7, request({ inventory = 'player:9', slot = 3 }, { token = 'forged' }))
H.equal(ok, false, 'a forged token is refused')
H.equal(err, 'invalid session', 'the lease is checked')

Config.kora_inventory.search.openContainers = false
ok, err = intent(7, request({ inventory = 'player:9', slot = 3 }))
H.equal(ok, false, 'a disabled config refuses the open')
H.equal(err, 'opening containers is disabled', 'with the disabled reason')
H.equal(I.sessionOf(7).secondary, 'player:9', 'a disabled refusal keeps the session')
view = search()
H.equal(view.secondary.items[3].openable, false, 'the view stops offering Open when disabled')
H.equal(view.secondary.items[3].closedContainer, true, 'the bag stays closed when opening is disabled')
Config.kora_inventory.search.openContainers = true
view = search()

-- Out of range: refused by the same access check a move gets, and the session closes.
positions[9] = 50
ok, err = intent(7, request({ inventory = 'player:9', slot = 3 }))
H.equal(ok, false, 'an out-of-range target is refused')
H.equal(err, 'too far away', 'for distance')
H.equal(I.sessionOf(7), nil, 'the session is closed when the target is out of range')
positions[9] = 1

-- Not searchable any more: the inspection policy says no.
view = search()
Config.kora_inventory.playerInspection.access = function() return false end
ok = intent(7, request({ inventory = 'player:9', slot = 3 }))
H.equal(ok, false, 'a target that is no longer searchable is refused')
Config.kora_inventory.playerInspection.access = function() return true end

-- Success -----------------------------------------------------------------

view = search()
ok, err = intent(7, request({ inventory = 'player:9', slot = 3 }))
H.ok(ok, 'a valid openTargetContainer opens the bag: ' .. tostring(err))
local session = I.sessionOf(7)
H.equal(session.secondary, containerKey, 'the bag is now the searcher secondary inventory')
H.equal(session.primary, 'player:7', 'the primary stays the searcher own inventory')
local seen
for _, event in ipairs(sent) do
    if event.name == 'kora_inventory:client:sessionOpened' and event.src == 7 then seen = event.args[1] end
end
H.equal(seen.secondary.items[1].name, 'weed', 'the opened bag shows its contents')

-- Closing the bag returns to the target's inventory.
I.close(7, 'requested')
session = I.sessionOf(7)
H.ok(session, 'closing the bag reopens a session')
H.equal(session.secondary, 'player:9', 'it returns to the target inventory')

-- Other close reasons do not.
view = search()
H.ok(intent(7, request({ inventory = 'player:9', slot = 3 })), 'the bag opens again')
I.close(7, 'expired')
H.equal(I.sessionOf(7), nil, 'an expiry does not return to the target')

-- While the bag is open, access is re-validated live.
view = search()
H.ok(intent(7, request({ inventory = 'player:9', slot = 3 })), 'opened once more')
positions[9] = 50
local syncOK = intent(7, { token = I.sessionOf(7).token, action = 'sync', payload = {}, primaryRevision = 0 })
H.equal(syncOK, false, 'walking away from the target revokes the searcher access to the bag')
H.equal(I.sessionOf(7), nil, 'and closes the session')
positions[9] = 1

view = search()
H.ok(intent(7, request({ inventory = 'player:9', slot = 3 })), 'opened for the drop test')
local carried = playersItems[9][3]
playersItems[9][3] = nil
syncOK = intent(7, { token = I.sessionOf(7).token, action = 'sync', payload = {}, primaryRevision = 0 })
H.equal(syncOK, false, 'the target dropping the bag revokes the searcher access')
playersItems[9][3] = carried

-- The searcher cannot open a bag in their OWN pockets through this intent, nor
-- take the grant to a container by any other route.
playersItems[7][1] = I.buildItem('backpack', 1, 1, {})
I.openSelf(7)
ok = intent(7, request({ inventory = 'player:7', slot = 1 }))
H.equal(ok, false, 'the intent never opens the searcher own bag (use does)')
I.close(7, 'test')

-- Domain rule: no network or NUI entry point accepts a container id.
for name in pairs(netEvents) do
    H.ok(not name:lower():find('container'), 'no net event named after containers: ' .. name)
end
local source = assert(io.open('server/containers.lua')):read('*a')
H.equal(source:find('RegisterNetEvent', 1, true), nil, 'containers.lua registers no net event')
H.equal(source:find('RegisterNUICallback', 1, true), nil, 'containers.lua registers no NUI callback')
H.equal(source:find('RegisterServerEvent', 1, true), nil, 'containers.lua registers no server event')

-- Direct API is bounded too.
Config.kora_inventory.search.openContainers = true
positions[9] = 1
H.equal(select(1, KoraInventory.containers.openForSearcher(7, 7, 3)), false, 'openForSearcher refuses searcher == target')
H.equal(select(1, KoraInventory.containers.openForSearcher(7, 9, 1)), false, 'openForSearcher refuses a non-container slot')
H.equal(select(1, KoraInventory.containers.openForSearcher(7, 77, 3)), false, 'openForSearcher refuses an unknown target')
H.equal(select(1, KoraInventory.containers.openForSearcher('x', 9, 3)), false, 'openForSearcher refuses a malformed searcher')

H.finish()
