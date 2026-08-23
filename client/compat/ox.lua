-- ox_inventory client provider surface. All state is read from qbcore's
-- replicated mirror or qbinventory's server-issued session; no browser state
-- is ever treated as inventory authority.
local function playerData() return exports.qbcore:getPlayerData() or {} end
local function items() return playerData().items or {} end
local function count(name, metadata)
    local total = 0
    for _, item in pairs(items()) do
        if item.name == name and (not metadata or QbInventory.sameInfo(item.info or item.metadata, metadata)) then total = total + (item.amount or item.count or 0) end
    end
    return total
end
local function itemSlots(name, metadata)
    local out = {}
    for slot, item in pairs(items()) do if item.name == name and (not metadata or QbInventory.sameInfo(item.info or item.metadata, metadata)) then out[#out + 1] = item end end
    table.sort(out, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    return out
end
local function weight()
    return QbInventory.totalWeight(items())
end
local function maxWeight()
    local active = exports.qbinventory:getCurrentSession()
    return active and active.primary and active.primary.maxWeight or 120000
end
local function search(kind, requested, metadata)
    local list, single = type(requested) == 'string' and { requested } or requested, type(requested) == 'string'
    if type(list) ~= 'table' then return false end
    local out = {}
    for _, name in ipairs(list) do out[name] = kind == 'slots' and itemSlots(name, metadata) or count(name, metadata) end
    return single and out[requested] or out
end
local Ox = {
    openInventory = function(invType, data) return exports.qbinventory:openInventory(invType, data) end,
    closeInventory = function() return exports.qbinventory:closeInventory() end,
    useSlot = function(slot) return exports.qbinventory:submitIntent({ action = 'use', slot = slot }) end,
    useItem = function(data, cb) local ok = exports.qbinventory:submitIntent({ action = 'use', slot = type(data) == 'table' and data.slot or data }); if cb then cb(ok) end return ok end,
    openNearbyInventory = function() return exports.qbinventory:requestGiveTarget() end,
    giveItemToTarget = function(serverId, slot, count) return exports.qbinventory:submitIntent({ action = 'give', target = serverId, slot = slot, amount = count }) end,
    GetPlayerItems = function() return QbInventory.copy(items()) end,
    GetPlayerWeight = weight,
    GetPlayerMaxWeight = maxWeight,
    GetItemCount = count,
    GetSlotWithItem = function(name, metadata) return itemSlots(name, metadata)[1] end,
    GetSlotIdWithItem = function(name, metadata) local item = itemSlots(name, metadata)[1]; return item and item.slot end,
    GetSlotsWithItem = itemSlots,
    Search = search,
    Items = function(name) local all = exports.qbcore:getShared('Items') or {}; return name and all[name] or all end,
    ItemList = function(name) local all = exports.qbcore:getShared('Items') or {}; return name and all[name] or all end,
    getCurrentWeapon = function() return nil end,
    setStashTarget = function(id, owner) LocalPlayer.state:set('ox:stashTarget', { id = id, owner = owner }, false) end,
    displayMetadata = function() end,
    suppressItemNotifications = function() end,
    notify = function(data) QB.notify.send(data) end,
    Progress = function(data) return QB.progressbar.start(data) end,
    ProgressActive = function() return false end,
    CancelProgress = function() return QB.progressbar.cancel() end,
    Keyboard = function() return nil end,
    weaponWheel = function() end,
    setGetPlayerNameMethod = function() end,
}
for name, fn in pairs(Ox) do
    exports(name, fn)
    AddEventHandler(('__cfx_export_ox_inventory_%s'):format(name), function(setCB) setCB(fn) end)
end
