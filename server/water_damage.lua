-- Water damage for electronics (Config.kora_inventory.waterDamage, off by default).
--
-- The client only ever says "my player has been swimming" (payload-free net
-- event). Everything else is decided here: whether the feature is on, whether
-- the report is rate limited, which of THAT player's own pocket items are
-- rolled, and what happens to them. The event can only hurt the sender's own
-- items, so a spoofed report is a harm to oneself, never a way to gain or
-- change anything else; see docs/security.md.
local inventoryApi = assert(KoraInventory and KoraInventory.internal, 'kora_inventory server authority must load first')

local waterDamage = {}

-- One accepted report per player every 10 s, whatever the client sends.
local RATE_LIMIT_MS = 10000
local lastReport = {}
local random = function() return math.random() end

local function settings()
    local cfg = Config.kora_inventory.waterDamage
    return type(cfg) == 'table' and cfg or {}
end

local function enabled()
    return settings().enabled == true
end

local function lower(value)
    return type(value) == 'string' and value:lower() or nil
end

local function substitute(text, vars)
    return (tostring(text):gsub('%%{(%w+)}', function(name) return tostring(vars[name] or '') end))
end

local function say(src, key, fallback, vars, kind)
    if not (Kora and Kora.notify and Kora.bridge.sendNotify) then
        return
    end
    local text = KoraInventory.text and KoraInventory.text(key, fallback, vars) or fallback
    Kora.bridge.sendNotify(src, {
        title = KoraInventory.text and KoraInventory.text('inventory.title', 'Inventory') or 'Inventory',
        message = substitute(text, vars or {}),
        type = kind or 'error',
    })
end

local function itemLabel(item)
    local def = inventoryApi.itemDef(item.name)
    return tostring(item.label or (def and def.label) or item.name)
end

local function chanceFor(name)
    local items = settings().items
    local entry = type(items) == 'table' and items[name] or nil
    if type(entry) ~= 'table' then
        for configured, value in pairs(type(items) == 'table' and items or {}) do
            if lower(configured) == lower(name) then
                entry = value
                break
            end
        end
    end
    local chance = type(entry) == 'table' and tonumber(entry.chance) or nil
    if not chance then
        return nil
    end
    return math.max(0, math.min(1, chance))
end

local function sortedSlots(items)
    local slots = {}
    for slot in pairs(items or {}) do
        slots[#slots + 1] = slot
    end
    table.sort(slots)
    return slots
end

local function infoOf(item)
    return inventoryApi.copy(item.info or item.metadata or {})
end

local function playerInventory(src)
    local playerKey = inventoryApi.playerKey(src)
    return playerKey, inventoryApi.getInventory(playerKey)
end

---Override the RNG (tests only). It must return a number in [0, 1).
function waterDamage.setRandom(fn)
    random = type(fn) == 'function' and fn or function() return math.random() end
end

---Forget a player's rate limit (disconnect, tests).
function waterDamage.reset(src)
    if src == nil then
        lastReport = {}
    else
        lastReport[src] = nil
    end
end

---True when this item may not be used because it is water damaged. Tells the
---player why. Only applies while the feature is enabled.
function waterDamage.blocksUse(src, item)
    if not enabled() or type(item) ~= 'table' then
        return false
    end
    local info = item.info or item.metadata
    if type(info) ~= 'table' or info.waterDamaged ~= true then
        return false
    end
    say(src, 'inventory.water_damaged_use', 'This item is water damaged.', { item = itemLabel(item) })
    return true
end

---View-only: badge and inspector row. Never read back from a client.
function waterDamage.decorate(item, metadata)
    if type(metadata) ~= 'table' or metadata.waterDamaged ~= true then
        return
    end
    -- The generic metadata row would print the raw key/value; replace it.
    local rows = item.displayMeta or {}
    for index = #rows, 1, -1 do
        if rows[index].key == 'waterDamaged' then
            table.remove(rows, index)
        end
    end
    if enabled() then
        item.waterDamaged = true
        rows[#rows + 1] = {
            key = 'waterDamaged',
            label = KoraInventory.text and KoraInventory.text('inventory.water_damaged_label', 'Condition') or 'Condition',
            value = KoraInventory.text and KoraInventory.text('inventory.water_damaged_value', 'Water damaged')
                or 'Water damaged',
        }
    end
end

local function setFlag(src, slot, flagged)
    local item = select(2, playerInventory(src)).items[slot]
    local info = infoOf(item)
    info.waterDamaged = flagged and true or nil
    return inventoryApi.setPlayerItemInfo(src, slot, info)
end

---Roll every configured item in the player's pockets. Returns the list of
---outcomes ({ slot, name, mode }). Pockets only: items stored inside a portable
---container are separate inventories and are never rolled.
local function rollItems(src)
    local playerKey, inv = playerInventory(src)
    if not inv then
        return {}
    end
    local cfg = settings()
    local mode = cfg.mode
    local into = lower(cfg.into)
    if mode == 'convert' and (not into or not inventoryApi.itemDef(into)) then
        mode = 'flag'
    elseif mode ~= 'convert' and mode ~= 'remove' then
        mode = 'flag'
    end
    local outcomes = {}
    for _, slot in ipairs(sortedSlots(inv.items)) do
        local item = inv.items[slot]
        local chance = chanceFor(item.name)
        local alreadyFlagged = mode == 'flag' and type(item.info or item.metadata) == 'table'
            and (item.info or item.metadata).waterDamaged == true
        -- chance 0 never rolls; chance 1 always damages.
        if chance and chance > 0 and not alreadyFlagged and random() < chance then
            local label = itemLabel(item)
            local amount = tonumber(item.amount) or 1
            local ok
            if mode == 'flag' then
                ok = setFlag(src, slot, true)
            elseif mode == 'remove' then
                ok = inventoryApi.removeFrom(playerKey, slot, amount)
            else
                local removed, _, removedItem = inventoryApi.removeFrom(playerKey, slot, amount)
                if removed then
                    ok = inventoryApi.addTo(playerKey, into, amount, slot, {}, 'water-damage')
                    if ok and inventoryApi.auditAdd then
                        inventoryApi.auditAdd('water', src, playerKey, into, amount, 'water-damage:' .. tostring(removedItem and removedItem.name or item.name))
                    end
                    if not ok then
                        -- Could not place the replacement: put the original back.
                        inventoryApi.addTo(playerKey, removedItem.name, amount, slot, removedItem.info or removedItem.metadata,
                            'water-damage-rollback')
                    end
                end
            end
            if ok then
                outcomes[#outcomes + 1] = { slot = slot, name = item.name, label = label, mode = mode }
            end
        end
    end
    return outcomes
end

---Handle one "I have been swimming" report from `src`. Returns (accepted,
---outcomes | reason).
function waterDamage.report(src)
    src = tonumber(src)
    if not src or src < 1 then
        return false, 'invalid source'
    end
    if not enabled() then
        return false, 'disabled'
    end
    local stamp = GetGameTimer()
    local last = lastReport[src]
    if last and stamp - last < RATE_LIMIT_MS then
        return false, 'rate limited'
    end
    lastReport[src] = stamp
    local playerKey = inventoryApi.playerKey(src)
    local outcomes = inventoryApi.lock({ playerKey }, function()
        local result = rollItems(src)
        if #result > 0 then
            inventoryApi.bump(playerKey)
            inventoryApi.broadcast(playerKey)
        end
        return result
    end)
    if type(outcomes) ~= 'table' then
        return false, 'inventory busy'
    end
    for _, outcome in ipairs(outcomes) do
        if outcome.mode == 'flag' then
            say(src, 'inventory.water_damaged_item', 'Your %{item} got wet and stopped working.', { item = outcome.label })
        else
            say(src, 'inventory.water_ruined_item', 'Your %{item} was ruined by the water.', { item = outcome.label })
        end
    end
    if #outcomes > 0 and TriggerEvent then
        TriggerEvent('kora_inventory:server:waterDamaged', src, inventoryApi.copy(outcomes))
    end
    return true, outcomes
end

---Using the repair item clears `waterDamaged` from a damaged item in the
---player's pockets and consumes one repair item. No kora_lib menu API exists in
---this stack, so the first damaged slot (lowest number) is repaired; the slot is
---resolved here from the real inventory, never supplied by a client. Returns
---true when the use was handled (nothing is then left for the item's own
---handler); false lets the item behave as it normally does.
function waterDamage.tryRepair(src, item)
    if not enabled() or type(item) ~= 'table' then
        return false
    end
    local repairItem = lower(settings().repairItem)
    if not repairItem or lower(item.name) ~= repairItem then
        return false
    end
    local playerKey = inventoryApi.playerKey(src)
    local handled = inventoryApi.lock({ playerKey }, function()
        local _, inv = playerInventory(src)
        if not inv then
            return false
        end
        local repairSlot = tonumber(item.slot)
        local held = repairSlot and inv.items[repairSlot]
        if not held or lower(held.name) ~= repairItem then
            return false
        end
        local target
        for _, slot in ipairs(sortedSlots(inv.items)) do
            local candidate = inv.items[slot]
            local info = candidate and (candidate.info or candidate.metadata)
            if type(info) == 'table' and info.waterDamaged == true then
                target = slot
                break
            end
        end
        if not target then
            return false
        end
        local targetLabel = itemLabel(inv.items[target])
        local cleared = setFlag(src, target, false)
        if not cleared then
            return false
        end
        local removed = inventoryApi.removeFrom(playerKey, repairSlot, 1)
        if not removed then
            -- Never repair for free.
            setFlag(src, target, true)
            return false
        end
        inventoryApi.bump(playerKey)
        inventoryApi.broadcast(playerKey)
        say(src, 'inventory.water_repaired', 'You repaired your %{item}.', { item = targetLabel }, 'success')
        return true
    end)
    return handled == true
end

KoraInventory.waterDamage = waterDamage

-- Payload-free on purpose: nothing the client sends is read. The server
-- cannot cheaply verify swimming (no server native for it, and a sea-level z
-- heuristic fails for lakes, rivers and pools), so the rate limit above plus
-- the fact that the event only ever affects the sender's own items is the
-- whole defence.
if type(RegisterNetEvent) == 'function' then
    RegisterNetEvent('kora_inventory:server:waterExposure', function()
        if type(GetInvokingResource) == 'function' and GetInvokingResource() then
            return
        end
        waterDamage.report(source)
    end)
end

if type(AddEventHandler) == 'function' then
    AddEventHandler('playerDropped', function()
        lastReport[source] = nil
    end)
end
