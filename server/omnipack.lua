-- Admin omnipack: a read-only, free, infinite-stock "shop" listing EVERY
-- registered item and weapon.
--
-- It is an ordinary shop inventory (key `shop:omnipack`) carrying
-- `omnipack = true`, so the existing session, lease, revision, access, routing
-- bucket and distance checks and the shop UI all apply unchanged. What differs:
--   * access is the ACE `Config.kora_inventory.omnipack.ace`, re-checked by
--     canAccess on every request AND by intentOmnipackTake (server.lua) on every
--     take, so revoking the permission stops the next intent;
--   * stock is infinite and the price is 0, so a take decrements nothing and
--     does not re-send the ~1000 row list (the list is sent once, on open);
--   * a take goes through addPlayer, so weapons get a fresh serial, and is
--     recorded in the audit log as 'omnipack';
--   * it is never persisted (server/persistence.lua shouldPersist).
-- Nothing here is reachable from a client event: the only entry points are the
-- /omnipack command (server/admin_tools.lua) and the `openOmnipack` export.

KoraInventory = KoraInventory or {}
local inventory = KoraInventory
local omnipack = {}
inventory.omnipack = omnipack

local INVENTORY_ID = 'omnipack'
local INFINITE = 9999 -- displayed stack size; stock is never decremented
omnipack.inventoryKey = 'shop:' .. INVENTORY_ID

local lastSignature

local function settings()
    local config = Config and Config.kora_inventory
    return type(config) == 'table' and type(config.omnipack) == 'table' and config.omnipack or {}
end

---@return boolean
function omnipack.enabled()
    return settings().enabled == true
end

---@return string ace
function omnipack.ace()
    local ace = settings().ace
    return type(ace) == 'string' and ace ~= '' and ace or 'kora_inventory.omnipack'
end

---Largest amount of one item a single take may add.
---@return integer
function omnipack.maxAmount()
    return math.floor(math.max(1, math.min(10000, tonumber(settings().maxAmount) or 100)))
end

---The one permission check. Called on open, by the shop's access policy on
---every session request, and on every take.
---@param src integer
---@return boolean allowed
---@return string|nil reason
function omnipack.allowed(src)
    if not omnipack.enabled() then
        return false, 'omnipack is disabled'
    end
    src = tonumber(src)
    if not src or src < 1 or src % 1 ~= 0 then
        return false, 'not authorised'
    end
    if not IsPlayerAceAllowed(tostring(src), omnipack.ace()) then
        return false, 'not authorised'
    end
    return true
end

---Every registered item and weapon name, sorted, from kora_core at call time.
---allShared returns a dense array of records (a name-keyed map is tolerated).
---@return string[] names
function omnipack.catalogNames()
    local names, seen = {}, {}
    for _, registry in ipairs({ 'items', 'weapons' }) do
        local called, all = pcall(function()
            return exports.kora_core:allShared(registry)
        end)
        if called and type(all) == 'table' then
            for key, def in pairs(all) do
                local name = type(def) == 'table' and def.name or (type(key) == 'string' and key) or nil
                if type(name) == 'string' and name ~= '' then
                    name = name:lower()
                    if not seen[name] then
                        seen[name] = true
                        names[#names + 1] = name
                    end
                end
            end
        end
    end
    table.sort(names)
    return names
end

---Builds (or refreshes) the omnipack inventory. The list is only replaced, and
---its revision bumped, when the registry changed, so a second admin opening it
---does not invalidate the first one's session.
---@return table|nil inv
---@return string|nil err
local function sync()
    local internal = inventory.internal
    local names = omnipack.catalogNames()
    local inv = internal.createSecondary('shop', INVENTORY_ID, {
        label = 'Omnipack',
        slots = math.max(1, #names),
        maxWeight = 2 ^ 50,
        temporary = true,
        stock = {},
        prices = {},
        -- The access callback is the ACE; canAccess runs it on every request.
        access = function(src)
            return (omnipack.allowed(src))
        end,
    })
    if not inv then
        return nil, 'omnipack unavailable'
    end
    local signature = table.concat(names, '\n')
    if inv.omnipack ~= true or signature ~= lastSignature then
        local items = {}
        for _, name in ipairs(names) do
            local entry = internal.buildItem(name, 1, #items + 1, {})
            if entry then
                entry.amount = INFINITE
                entry.price = 0
                items[entry.slot] = entry
            end
        end
        inv.omnipack = true
        inv.weightLimit = false
        inv.slots = math.max(1, #names)
        inv.items, inv.stock = items, items
        inv.prices = {}
        inv.currency = 'money'
        inv.accessRequired = true
        lastSignature = signature
        internal.bump(inv.key)
    end
    return inv
end

---Opens the omnipack for `src`. Re-checks the ACE; the shop session machinery
---then re-checks it (via the access callback) on every request.
---@param src integer
---@return boolean opened
---@return table|string result
function omnipack.open(src)
    local allowed, reason = omnipack.allowed(src)
    if not allowed then
        return false, reason
    end
    local inv, err = sync()
    if not inv then
        return false, err
    end
    return inventory.internal.openInventory(src, 'shop', { key = inv.key })
end

---Test hook: forget the cached catalogue signature.
function omnipack.reset()
    lastSignature = nil
end
