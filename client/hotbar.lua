-- Slot 1-5 hotbar keybinds. qbinventory has no separate hotbar/quickslot data
-- model of its own -- see client/compat.lua's `qb-inventory:client:hotbar`,
-- which is a deliberate no-op because "the hotbar is part of qbinventory's
-- own UI and is driven from its session, not from a caller-supplied item
-- list". Since no reserved hotbar range exists anywhere in the item/slot data
-- model (server.lua indexes player items 1..Config.qbinventory.playerSlots
-- with no special first-N meaning), this picks the same interpretation real
-- qb-inventory/ox_inventory hotbars use: the first N general inventory slots
-- double as the hotbar, rather than inventing a new reserved slot range.
--
-- The range comes from config rather than a constant here because a second
-- feature reads the same "is it in the hotbar" question: weaponCarry's
-- 'hotbar' visibility mode shows exactly these slots on a player's body and
-- charges extra to draw from outside them. Two constants would silently
-- disagree about which slots the player can actually see.
local HOTBAR_SLOTS = math.max(0, math.floor(tonumber(Config.qbinventory.hotbarSlots) or 5))

local function useHotbarSlot(slot)
    -- Keys 1-5 also type into chat/search boxes and the pause menu. Only fire
    -- while nothing already owns keyboard focus -- same guard client/compat.lua
    -- uses for the `inventory` command. This also means the panel is always
    -- closed here in practice, since SetNuiFocus(true, true) (client/ui.lua)
    -- captures keyboard input the moment a qbinventory session opens.
    if IsPauseMenuActive() or IsNuiFocused() then return end

    local data = exports.qbcore:getPlayerData()
    local item = data and data.items and data.items[slot]
    if type(item) ~= 'table' then return end

    -- Same progress-bar gate as the NUI 'use' path in client.lua, shared
    -- through QbInventory so a cancelled bar never reaches the server here
    -- either.
    if not QbInventory.useGate(item) then return end

    -- Reuse the existing legacy hotbar transport instead of adding a second
    -- server-side use path: server.lua's `QBCore:Server:UseItem` handler
    -- already re-resolves the slot from qbcore-owned PlayerData and never
    -- trusts the transmitted item record (only `owned.name == item.name` is
    -- compared before it calls the same useItem() the NUI 'use' intent does).
    TriggerServerEvent('QBCore:Server:UseItem', { slot = slot, name = item.name })
end

for slot = 1, HOTBAR_SLOTS do
    local command = ('qbinventory:hotbar%d'):format(slot)
    QB.keybind.add({
        name = command,
        description = ('Use hotbar item %d'):format(slot),
        defaultMapper = 'keyboard',
        defaultKey = tostring(slot),
        onPressed = function() useHotbarSlot(slot) end,
    })
end
