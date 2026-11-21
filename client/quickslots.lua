-- Quick slots: shortcuts, NOT physical slots.
--
-- Items stay in the player's normal inventory (kora_core PlayerData.items).
-- A quick slot is a pointer that resolves (shared/quickslots.lua) to the real
-- slot of a matching item; it exists only to show a shortcut beside the
-- inventory, in the on-screen hotbar, and to give that item a hotkey.
--
-- Boundary, the same one client/hotbar.lua keeps:
--   * nothing is stored on the server and no server event is added here. A
--     hotkey resolves its slot and goes through KoraInventory.useSlot, the
--     hotbar's own path, so the server re-resolves the real slot and item from
--     kora_core data exactly as it does for the number keys. The ammo shortcut
--     is just "use that ammo item"; server/useables.lua's ammoUseable still
--     validates it against the weapon the server believes is drawn;
--   * pins are a local display preference kept in client KVP per character.
--     They are never sent to the server, and they are re-validated against the
--     live inventory on every resolve, so a stale or edited pin only ever
--     points at an item the player really holds in a matching slot;
--   * the drawn weapon is read through KoraInventory.getDrawnWeaponSlot, a
--     read-only getter in client/weaponcarry.lua.

local config = Config.kora_inventory
local settings = type(config.quickSlots) == 'table' and config.quickSlots or { enabled = false }
local NUI_MESSAGE = 'kora_inventory:nui:quickSlots'

local function send(action, data)
    -- client/ui.lua loads after this file; look its bridge up at call time.
    local ui = KoraInventory and KoraInventory.ui
    if ui and ui.send then
        ui.send(action, data)
    end
end

KoraInventory.quickSlotsClient = KoraInventory.quickSlotsClient or {}
local api = KoraInventory.quickSlotsClient

if settings.enabled == false then
    -- Nothing is registered. Tell the UI once so it never draws the rail; the
    -- delay matches client/ui.lua's locale push (React attaches its listener
    -- after the document has loaded).
    api.push = function() end
    api.hud = function() return nil end
    CreateThread(function()
        Wait(2500)
        send(NUI_MESSAGE, { enabled = false })
    end)
    return
end

-- Only well-formed, uniquely named quick slots are used. The id becomes part
-- of a command name and a KVP key, so it is restricted to word characters.
local slotsConfig, configById = {}, {}
for _, entry in ipairs(type(settings.slots) == 'table' and settings.slots or {}) do
    if type(entry) == 'table' and type(entry.id) == 'string' and entry.id:match('^[%w_]+$')
        and not configById[entry.id]
    then
        slotsConfig[#slotsConfig + 1] = entry
        configById[entry.id] = entry
    end
end

local resolver = KoraInventory.quickSlots

---Item or weapon definition, resolved through kora_core at use time and never
---cached (same lookup as client/hotbar.lua and client/compat.lua).
local function defOf(name)
    if type(name) ~= 'string' then
        return nil
    end
    local key = name:lower()
    local def = exports.kora_core:getShared('items', key) or exports.kora_core:getShared('weapons', key)
    return type(def) == 'table' and def or nil
end

local function playerSlots()
    return math.max(1, math.floor(tonumber(config.playerSlots) or 41))
end

-- --- pins (local preference, per character) ----------------------------------

local KVP_PREFIX = 'kora_inventory:quickslots:'
local pinCache = {} -- citizenid -> { [id] = { name, serial } }

local function characterId()
    local data = exports.kora_core:getPlayerData()
    local cid = type(data) == 'table' and data.citizenid or nil
    return type(cid) == 'string' and cid ~= '' and cid or nil
end

local function cleanPins(raw)
    local pins = {}
    if type(raw) ~= 'table' then
        return pins
    end
    for id, pin in pairs(raw) do
        if configById[id] and not configById[id].linkedTo and type(pin) == 'table'
            and type(pin.name) == 'string' and #pin.name > 0 and #pin.name <= 64
        then
            pins[id] = {
                name = pin.name,
                serial = type(pin.serial) == 'string' and #pin.serial <= 64 and pin.serial or nil,
            }
        end
    end
    return pins
end

local function pinsFor(cid)
    if not cid then
        return {}
    end
    if not pinCache[cid] then
        local stored = GetResourceKvpString(KVP_PREFIX .. cid)
        local ok, decoded = pcall(json.decode, stored or '{}')
        pinCache[cid] = cleanPins(ok and decoded or nil)
    end
    return pinCache[cid]
end

local function savePins(cid)
    local pins = pinsFor(cid)
    if next(pins) == nil then
        DeleteResourceKvp(KVP_PREFIX .. cid)
    else
        SetResourceKvp(KVP_PREFIX .. cid, json.encode(pins))
    end
end

-- --- keys --------------------------------------------------------------------

local handles = {}

---The key currently bound to a quick slot, for the UI hint. Read from the
---game's own key mapping on every push so a rebind in Settings > Key Bindings
---shows up the next time the inventory opens. Falls back to ''.
local function keyLabel(id)
    local handle = handles[id]
    local ok, binding = pcall(function() return handle and handle.getCurrentBinding() end)
    if ok and type(binding) == 'string' and binding ~= '' and binding ~= 'NULL' then
        return binding
    end
    return ''
end

-- --- resolution --------------------------------------------------------------

local function resolveAll()
    local data = exports.kora_core:getPlayerData()
    if type(data) ~= 'table' then
        return {}
    end
    local keys = {}
    for _, entry in ipairs(slotsConfig) do
        keys[entry.id] = keyLabel(entry.id)
    end
    local resolved = resolver.resolve(data.items, slotsConfig, {
        getDef = defOf,
        pins = pinsFor(characterId()),
        equippedSlot = KoraInventory.getDrawnWeaponSlot and KoraInventory.getDrawnWeaponSlot() or nil,
        playerSlots = playerSlots(),
        keys = keys,
    })
    for _, entry in ipairs(resolved) do
        entry.linked = configById[entry.id].linkedTo ~= nil
    end
    return resolved
end

local lastSignature

local function signature(resolved)
    local parts = {}
    for index, entry in ipairs(resolved) do
        parts[index] = ('%s|%s|%s|%s|%s|%s'):format(entry.id, tostring(entry.slot), tostring(entry.name),
            tostring(entry.total), tostring(entry.pinned), entry.key)
    end
    return table.concat(parts, ';')
end

---Send the resolved quick slots to the NUI. Unchanged results are not re-sent
---unless `force` is set (session open always sends).
---@param force boolean|nil
function api.push(force)
    local resolved = resolveAll()
    local sig = signature(resolved)
    if not force and sig == lastSignature then
        return
    end
    lastSignature = sig
    send(NUI_MESSAGE, {
        enabled = true,
        hideWhenMissing = settings.hideWhenMissing ~= false,
        showKeyHints = settings.showKeyHints ~= false,
        slots = resolved,
    })
end

---Resolved quick slots for the on-screen hotbar (client/ui.lua adds this to
---the `kora_inventory:nui:hotbar` payload). Only slots with an item are listed.
---@return table[]|nil
function api.hud()
    if settings.inHotbarHud == false then
        return nil
    end
    local data = exports.kora_core:getPlayerData()
    local items = type(data) == 'table' and data.items or {}
    local list = {}
    for _, entry in ipairs(resolveAll()) do
        local item = entry.slot and items[entry.slot]
        if type(item) == 'table' then
            local def = defOf(item.name) or {}
            list[#list + 1] = {
                id = entry.id,
                slotLabel = entry.label,
                slot = entry.slot,
                name = item.name,
                label = item.label or def.label or item.name,
                amount = entry.total or item.amount or item.count or 1,
                total = entry.total,
                key = entry.key,
                pinned = entry.pinned,
                image = item.image or def.image,
                imageUrl = item.imageUrl or def.imageUrl,
            }
        end
    end
    return list
end

-- Refresh whenever the inventory contents, the drawn weapon or the character
-- change. All of them only re-resolve and re-display.
exports.kora_core:onPlayerDataChange({ 'items' }, function()
    api.push()
end)

AddEventHandler('kora_inventory:client:weaponDrawnChanged', function()
    api.push()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    pinCache = {}
    lastSignature = nil
end)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    pinCache = {}
    lastSignature = nil
end)

-- --- hotkeys -----------------------------------------------------------------

local function useQuickSlot(id)
    for _, entry in ipairs(resolveAll()) do
        if entry.id == id then
            if entry.slot then
                -- Same use path as the hotbar number keys, including every
                -- guard (pause menu, NUI focus, busy, cuffed, downed).
                KoraInventory.useSlot(entry.slot)
            end
            return
        end
    end
end

for _, entry in ipairs(slotsConfig) do
    local id = entry.id
    handles[id] = Kora.keybind.add({
        name = 'kora_inventory:quick_' .. id,
        description = ('Quick slot: %s'):format(tostring(entry.label or id)),
        defaultMapper = 'keyboard',
        defaultKey = type(entry.key) == 'string' and entry.key or '',
        onPressed = function()
            useQuickSlot(id)
        end,
    })
end

-- --- pinning -----------------------------------------------------------------

-- Called by client/ui.lua's `kora_inventory:pinQuickSlot` NUI callback (all NUI
-- callbacks live in ui.lua), with `{ id = string, slot = number|nil }`. nil or
-- 0 removes the pin. Answers the browser only; nothing here is forwarded to
-- the server.
---@param data table
---@return boolean ok
---@return string|nil error
function api.pin(data)
    if type(data) ~= 'table' or type(data.id) ~= 'string' then
        return false, 'invalid quick slot'
    end
    local slotConfig = configById[data.id]
    if not slotConfig then
        return false, 'unknown quick slot'
    end
    if slotConfig.linkedTo then
        return false, 'quick slot cannot be pinned'
    end
    local cid = characterId()
    if not cid then
        return false, 'no character'
    end

    local pins = pinsFor(cid)
    local slot = data.slot
    if slot == nil or slot == 0 then
        pins[data.id] = nil
    else
        if type(slot) ~= 'number' or slot ~= math.floor(slot) or slot < 1 or slot > playerSlots() then
            return false, 'invalid slot'
        end
        local playerData = exports.kora_core:getPlayerData()
        local item = type(playerData) == 'table' and type(playerData.items) == 'table' and playerData.items[slot] or nil
        if type(item) ~= 'table' or type(item.name) ~= 'string' then
            return false, 'no item in that slot'
        end
        if not resolver.matches(slotConfig.accepts, item, defOf(item.name)) then
            return false, 'item does not fit this quick slot'
        end
        pins[data.id] = {
            name = item.name,
            serial = type(item.info) == 'table' and type(item.info.serial) == 'string' and item.info.serial or nil,
        }
    end

    savePins(cid)
    api.push(true)
    return true
end
