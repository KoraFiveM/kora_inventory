-- Client half of server/weapon_upkeep.lua: jam blocking and the clear-jam key,
-- the upkeep progress bar, and the repair counter interaction.
--
-- Nothing here is authority.
--   * A jam is set (and cleared) only by the server. The server tells this
--     client which slot is jammed; the client merely stops the local trigger
--     and shows a hint. A client that ignores it still has every shot refused
--     server-side while the weapon is jammed.
--   * Clearing a jam sends a payload-free intent. The server decides which
--     weapon is meant (the one it recorded as drawn) and runs the bar itself.
--   * The repair counter only sends its configured index. The server checks the
--     player's real position/bucket, prices the repair, and charges.

local HOLD_MS = 600
local CONFIRM_WINDOW_MS = 10000
-- INPUT_ATTACK, INPUT_ATTACK2, INPUT_MELEE_ATTACK_LIGHT/HEAVY/ALTERNATE,
-- INPUT_VEH_ATTACK / INPUT_VEH_ATTACK2.
local FIRE_CONTROLS = { 24, 25, 69, 70, 92, 140, 141, 142, 257, 263, 264 }

local function weaponsConfig()
    return (Config.kora_inventory and Config.kora_inventory.weapons) or {}
end

local function lang(key, vars, fallback)
    local ok, value = pcall(Kora.lang, key, vars)
    if ok and type(value) == 'string' and value ~= key then
        return value
    end
    return fallback or key
end

local function notify(message, kind)
    pcall(Kora.notify.send, { title = lang('inventory.title', nil, 'Inventory'), message = message, type = kind or 'error' })
end

---------------------------------------------------------------------------
-- Jam state
---------------------------------------------------------------------------

-- Slot the server says is jammed, or nil. Compared to the drawn slot on every
-- frame, so holstering or swapping weapons lifts the block with no event.
local jammedSlot
local blocking = false
local hintId

local function drawnSlot()
    return KoraInventory.getDrawnWeaponSlot and KoraInventory.getDrawnWeaponSlot() or nil
end

local function jammedNow()
    return jammedSlot ~= nil and drawnSlot() == jammedSlot
end

local function hideHint()
    if hintId then
        pcall(Kora.textui.hide, hintId)
        hintId = nil
    end
end

local function showHint()
    if hintId then
        return
    end
    local ok, id = pcall(Kora.textui.show, lang('inventory.weapon_jammed_hint', nil, 'Weapon jammed — hold R to clear'), {
        key = 'R',
        icon = 'TriangleAlert',
        position = 'bottom-center',
    })
    if ok then
        hintId = id
    end
end

local function startBlocking()
    if blocking then
        return
    end
    blocking = true
    CreateThread(function()
        showHint()
        while jammedNow() do
            DisablePlayerFiring(PlayerId(), true)
            for _, control in ipairs(FIRE_CONTROLS) do
                DisableControlAction(0, control, true)
            end
            Wait(0)
        end
        hideHint()
        blocking = false
    end)
end

RegisterNetEvent('kora_inventory:client:weaponJamState', function(state)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    if type(state) ~= 'table' then
        return
    end
    local slot = math.floor(tonumber(state.slot) or 0)
    if state.jammed == true and slot > 0 then
        jammedSlot = slot
        if jammedNow() then
            startBlocking()
        end
    elseif jammedSlot == slot or slot == 0 then
        jammedSlot = nil
    end
end)

-- The draw can finish after the server's jam-state event, so re-evaluate
-- whenever the drawn slot changes.
AddEventHandler('kora_inventory:client:weaponDrawnChanged', function()
    if jammedNow() then
        startBlocking()
    end
end)

-- Logout / character switch: the next character does not inherit a jam.
RegisterNetEvent('QBCore:Client:OnPlayerUnload', function()
    jammedSlot = nil
end)

---------------------------------------------------------------------------
-- Hold-to-clear key (rebindable in the FiveM key settings)
---------------------------------------------------------------------------

local holding = false

Kora.keybind.add({
    name = 'kora_inventory_clearjam',
    description = lang('inventory.keybind_clear_jam', nil, 'Clear weapon jam (hold)'),
    defaultKey = 'R',
    onPressed = function(handle)
        if holding or not jammedNow() then
            return
        end
        holding = true
        CreateThread(function()
            local startedAt = GetGameTimer()
            while handle.isPressed() and jammedNow() do
                if GetGameTimer() - startedAt >= HOLD_MS then
                    -- No weapon, slot or item: the server resolves the drawn weapon.
                    TriggerServerEvent('kora_inventory:server:clearJam')
                    break
                end
                Wait(0)
            end
            holding = false
        end)
    end,
})

---------------------------------------------------------------------------
-- Server-run progress bar (clear / repair kit / cleaning)
---------------------------------------------------------------------------

local BAR_LABELS = {
    clear = { 'inventory.weapon_clearing_jam', 'Clearing jam...' },
    repair = { 'inventory.weapon_repairing', 'Repairing weapon...' },
    clean = { 'inventory.weapon_cleaning', 'Cleaning weapon...' },
}

Kora.callback.register('kora_inventory:client:weaponUpkeepBar', function(request)
    local entry = BAR_LABELS[type(request) == 'table' and request.kind or false]
    if not entry then
        return false
    end
    local ped = Kora.cache.ped()
    if IsPedDeadOrDying(ped, true) then
        return false
    end
    local duration = math.max(0, math.floor(tonumber(request.time) or 0))
    if duration > 0 then
        local started, completed = pcall(Kora.progressbar.start, {
            label = lang(entry[1], nil, entry[2]),
            duration = duration,
            canCancel = true,
        })
        if not started or completed ~= true then
            return false
        end
    end
    return Kora.cache.ped() == ped and not IsPedDeadOrDying(ped, true)
end)

---------------------------------------------------------------------------
-- Repair counters (kora_target)
---------------------------------------------------------------------------

local pendingConfirm -- { index, expires }
local counterZones = {}

local function selectCounter(index)
    CreateThread(function()
        local now = GetGameTimer()
        if pendingConfirm and pendingConfirm.index == index and now < pendingConfirm.expires then
            pendingConfirm = nil
            -- Counter index only; the server re-checks its own live quote.
            TriggerServerEvent('kora_inventory:server:repairConfirm', index)
            return
        end
        pendingConfirm = nil
        local ok, result = Kora.callback.trigger('kora_inventory:server:repairQuote', index)
        if ok ~= true or type(result) ~= 'table' then
            notify(lang('inventory.weapon_repair_refused', { reason = tostring(result or 'unavailable') }, 'Weapon repairs unavailable.'))
            return
        end
        pendingConfirm = { index = index, expires = GetGameTimer() + CONFIRM_WINDOW_MS }
        notify(lang('inventory.weapon_repair_quote', {
            weapon = tostring(result.weapon),
            price = tonumber(result.price) or 0,
            account = tostring(result.account),
        }, 'Weapon repair quoted.'), 'info')
    end)
end

local function clearCounters()
    for _, id in ipairs(counterZones) do
        pcall(function() exports.kora_target:removeZone(id) end)
    end
    counterZones = {}
end

local function registerCounters()
    clearCounters()
    local counters = (weaponsConfig().repair or {}).counters or {}
    if counters.enabled ~= true then
        return
    end
    for index, counter in ipairs(counters.locations or {}) do
        local point = counter.coords
        if point and tonumber(point.x) and tonumber(point.y) and tonumber(point.z) then
            local x, y, z = point.x + 0.0, point.y + 0.0, point.z + 0.0
            counterZones[#counterZones + 1] = exports.kora_target:addSphereZone(KoraInventory.shopZoneSprite({
                coords = { x = x, y = y, z = z },
                radius = tonumber(counter.distance) or 2.5,
                options = {
                    {
                        label = tostring(counter.label or 'Weapon repairs'),
                        icon = 'screwdriver-wrench',
                        onSelect = function() selectCounter(index) end,
                    },
                },
            }, { x = x, y = y, z = z }))
        end
    end
end

registerCounters()

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'kora_target' then
        registerCounters()
    end
end)

-- kora_target drops every zone it owns when it stops; forget the stale ids.
AddEventHandler('onClientResourceStop', function(resource)
    if resource == 'kora_target' then
        counterZones = {}
    elseif resource == GetCurrentResourceName() then
        hideHint()
    end
end)
