-- Slot 1-5 hotbar keybinds. kora_inventory has no separate hotbar/quickslot data
-- model of its own -- see client/compat.lua's `qb-inventory:client:hotbar`,
-- which is a deliberate no-op because "the hotbar is part of kora_inventory's
-- own UI and is driven from its session, not from a caller-supplied item
-- list". Since no reserved hotbar range exists anywhere in the item/slot data
-- model (server.lua indexes player items 1..Config.kora_inventory.playerSlots
-- with no special first-N meaning), this picks the same interpretation real
-- qb-inventory/ox_inventory hotbars use: the first N general inventory slots
-- double as the hotbar, rather than inventing a new reserved slot range.
--
-- The range comes from config rather than a constant here because a second
-- feature reads the same "is it in the hotbar" question: weaponCarry's
-- 'hotbar' visibility mode shows exactly these slots on a player's body and
-- charges extra to draw from outside them. Two constants would silently
-- disagree about which slots the player can actually see.
-- Locale text with an English fallback (shared.lua's KoraInventory.text).
local function localeText(key, fallback, vars)
    local text = KoraInventory and KoraInventory.text
    return text and text(key, fallback, vars) or fallback
end

local HOTBAR_SLOTS = math.max(0, math.floor(tonumber(Config.kora_inventory.hotbarSlots) or 5))

local function useHotbarSlot(slot)
    -- Keys 1-5 also type into chat/search boxes and the pause menu. Only fire
    -- while nothing already owns keyboard focus -- same guard client/compat.lua
    -- uses for the `inventory` command. This also means the panel is always
    -- closed here in practice, since SetNuiFocus(true, true) (client/ui.lua)
    -- captures keyboard input the moment a kora_inventory session opens.
    if IsPauseMenuActive() or IsNuiFocused() then
        return
    end

    if KoraInventory.isBusy() then
        KoraInventory.notifyBusyBlocked()
        return
    end

    if KoraInventory.isCuffed() then
        KoraInventory.notifyCuffedBlocked()
        return
    end

    local data = exports.kora_core:getPlayerData()
    local item = data and data.items and data.items[slot]
    if type(item) ~= 'table' then
        return
    end

    if KoraInventory.isDowned() then
        local allowed = false
        for _, name in ipairs(Config.kora_inventory.downedAllowedItems or {}) do
            allowed = allowed or (type(name) == 'string' and name:lower() == tostring(item.name):lower())
        end
        if not allowed then
            KoraInventory.notifyDownedBlocked()
            return
        end
    end

    -- Same progress-bar gate as the NUI 'use' path in client.lua, shared
    -- through KoraInventory so a cancelled bar never reaches the server here
    -- either.
    if not KoraInventory.useGate(item) then
        return
    end

    -- Reuse the existing legacy hotbar transport instead of adding a second
    -- server-side use path: server.lua's `QBCore:Server:UseItem` handler
    -- already re-resolves the slot from kora_core-owned PlayerData and never
    -- trusts the transmitted item record (only `owned.name == item.name` is
    -- compared before it calls the same useItem() the NUI 'use' intent does).
    TriggerServerEvent('QBCore:Server:UseItem', { slot = slot, name = item.name })
end

for slot = 1, HOTBAR_SLOTS do
    local command = ('kora_inventory:hotbar%d'):format(slot)
    Kora.keybind.add({
        name = command,
        description = localeText('inventory.keybind_hotbar', ('Use hotbar item %d'):format(slot), { slot = slot }),
        defaultMapper = 'keyboard',
        defaultKey = tostring(slot),
        onPressed = function()
            useHotbarSlot(slot)
        end,
    })
end

-- Players asked for a hotbar they can see without opening the inventory. It is
-- a short-lived overlay rather than a permanent HUD bar, so it costs nothing
-- while hidden: the NUI hides it again after the configured seconds.
Kora.keybind.add({
    name = 'kora_inventory:hotbarshow',
    description = localeText('inventory.keybind_hotbar_show', 'Show hotbar'),
    defaultMapper = 'keyboard',
    defaultKey = 'U',
    onPressed = function()
        local seconds = tonumber((Config.kora_inventory.ui or {}).hotbarSeconds) or 0
        if seconds <= 0 or HOTBAR_SLOTS == 0 or IsPauseMenuActive() or IsNuiFocused() then
            return
        end

        local data = exports.kora_core:getPlayerData()
        local items = data and data.items or {}
        local slots = {}
        for slot = 1, HOTBAR_SLOTS do
            local item = items[slot]
            -- Player data carries no artwork URL; the grid gets it from the shared
            -- item definition, so read the same definition here or items with no
            -- bundled file (bread) would show only the placeholder.
            local def = type(item) == 'table' and type(item.name) == 'string'
                and exports.kora_core:getShared('items', item.name:lower()) or nil
            def = type(def) == 'table' and def or {}
            slots[slot] = type(item) == 'table' and {
                slot = slot,
                name = item.name,
                label = item.label,
                amount = item.amount or item.count or 1,
                image = item.image or def.image,
                imageUrl = item.imageUrl or def.imageUrl,
            } or { slot = slot }
        end

        TriggerEvent('kora_inventory:ui:hotbarShow', { slots = slots, seconds = seconds })
    end,
})
