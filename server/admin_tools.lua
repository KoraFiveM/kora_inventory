-- Admin tools: the /invaudit viewer (item-creation audit log) and /omnipack.
--
-- Every entry point re-checks its ACE permission at call time:
--   * /invaudit (and the `kora_inventory:server:auditQuery` callback it feeds):
--     Config.kora_inventory.audit.ace, checked on EVERY request, not just open;
--   * /omnipack, the openOmnipack export, and every take: Config.kora_inventory.
--     omnipack.ace (see server/omnipack.lua and intentOmnipackTake).
-- The viewer is strictly read-only: there is no write path from the browser.

KoraInventory = KoraInventory or {}
local inventory = KoraInventory
local auditLog = inventory.auditLog
local omnipack = inventory.omnipack

local function auditSettings()
    local config = Config and Config.kora_inventory
    return type(config) == 'table' and type(config.audit) == 'table' and config.audit or {}
end

local function commandName(value, fallback)
    return type(value) == 'string' and value:match('^[%w_%-]+$') and value or fallback
end

---@return string ace
local function auditAce()
    local ace = auditSettings().ace
    return type(ace) == 'string' and ace ~= '' and ace or 'kora_inventory.audit'
end

---Console (source 0) is always allowed; a player needs the audit ACE.
---@param src integer
---@return boolean
local function auditAllowed(src)
    src = tonumber(src)
    if not src or src < 0 then
        return false
    end
    return src == 0 or IsPlayerAceAllowed(tostring(src), auditAce()) == true
end
inventory.auditAllowed = auditAllowed

local function notifyDenied(src, key, fallback)
    local text = inventory.text and inventory.text(key, fallback) or fallback
    Kora.notify.send(src, { title = inventory.text and inventory.text('inventory.title', 'Inventory') or 'Inventory', message = text, type = 'error' })
end

---Parses `player=CID item=bread resource=name range=1h page=2` console/chat args.
---@param args string[]|nil
---@return table filter raw (un-normalised) viewer filter
local function parseArgs(args)
    local filter = {}
    for _, arg in ipairs(args or {}) do
        local name, value = tostring(arg):match('^(%a+)=(.+)$')
        if name and (name == 'player' or name == 'item' or name == 'resource' or name == 'range' or name == 'page') then
            filter[name] = value
        end
    end
    return filter
end

-- ---------------------------------------------------------------------------
-- /invaudit
-- ---------------------------------------------------------------------------

local lastQuery = {}
local QUERY_GAP_MS = 250

if auditLog then
    RegisterCommand(commandName(auditSettings().command, 'invaudit'), function(src, args)
        if src == 0 then
            -- Console fallback: prints a summary (and the newest rows) through
            -- Kora.logging.info. Accepts player=/item=/resource=/range=/page=.
            CreateThread(function()
                auditLog.printSummary(parseArgs(args))
            end)
            return
        end
        if not auditAllowed(src) then
            return notifyDenied(src, 'inventory.audit_denied', 'You do not have permission to view the item audit log.')
        end
        -- The client opens an empty overlay; every data request below is
        -- authorised again.
        TriggerClientEvent('kora_inventory:client:auditOpen', src, parseArgs(args))
    end, false)

    ---Data for the viewer. The ACE is checked on every request, so revoking it
    ---stops the next page. Returns { error } for a refusal, else the query result.
    Kora.callback.register('kora_inventory:server:auditQuery', function(src, filter)
        if not auditAllowed(src) then
            return { error = 'not authorised' }
        end
        local stamp = GetGameTimer()
        if lastQuery[src] and stamp - lastQuery[src] < QUERY_GAP_MS then
            return { error = 'too many requests' }
        end
        lastQuery[src] = stamp
        local ok, result = pcall(auditLog.query, filter)
        if not ok then
            Kora.logging.warn('audit.query_error', 'Audit query failed', { error = tostring(result) })
            return { error = 'query failed' }
        end
        return result
    end)

    AddEventHandler('playerDropped', function()
        lastQuery[source] = nil
    end)
end

-- ---------------------------------------------------------------------------
-- /omnipack
-- ---------------------------------------------------------------------------

local function openOmnipack(src)
    src = tonumber(src)
    if not src or src < 1 then
        return false, 'invalid player'
    end
    local ok, result = omnipack.open(src)
    if not ok and (result == 'not authorised' or result == 'omnipack is disabled') then
        notifyDenied(src, 'inventory.omnipack_denied', 'You do not have permission to use the omnipack.')
    end
    return ok, result
end

if omnipack then
    local settings = type((Config.kora_inventory or {}).omnipack) == 'table' and Config.kora_inventory.omnipack or {}
    RegisterCommand(commandName(settings.command, 'omnipack'), function(src)
        if src == 0 then
            Kora.logging.info('omnipack.console', 'The omnipack can only be opened in game')
            return
        end
        CreateThread(function()
            openOmnipack(src)
        end)
    end, false)

    -- Server-side only. The ACE is checked for the TARGET player, so another
    -- resource cannot open the omnipack for someone without the permission.
    exports('openOmnipack', openOmnipack)
end
