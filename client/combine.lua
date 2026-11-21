-- Client half of server/combine.lua (drag one item onto another).
--
-- Two jobs, neither of which decides anything:
--   * run the kora_lib progress bar the server asks for and report whether it
--     finished. The server enforces a minimum elapsed time and re-reads both
--     slots afterwards, so a client that answers early or lies gains nothing;
--   * keep the list of recipe NAMES and LABELS the browser may show a confirm
--     popover for (config recipes plus those other resources registered at
--     runtime). No amounts, results or permissions cross this boundary.

KoraInventory = KoraInventory or {}

local remote = {}

local function recipeRows(list, out)
    if type(list) ~= 'table' then
        return out
    end
    for _, row in ipairs(list) do
        if type(row) == 'table' and type(row.a) == 'string' and type(row.b) == 'string' then
            out[#out + 1] = {
                a = row.a,
                b = row.b,
                label = type(row.label) == 'string' and row.label ~= '' and row.label or 'Combine',
            }
        end
    end
    return out
end

---The `combine` table pushed to the browser with the rest of its config.
---Read on every push, so a live /config change applies on the next open.
function KoraInventory.combinePresentation()
    local settings = (Config.kora_inventory or {}).combine
    settings = type(settings) == 'table' and settings or {}
    local recipes = recipeRows(settings.recipes, {})
    recipeRows(remote, recipes)
    return { enabled = settings.enabled == true, recipes = recipes }
end

RegisterNetEvent('kora_inventory:client:combinations', function(list)
    if type(GetInvokingResource) == 'function' and GetInvokingResource() then
        return
    end
    remote = type(list) == 'table' and list or {}
end)

-- Recipes other resources registered before this client connected.
CreateThread(function()
    local ok, list = pcall(Kora.callback.trigger, 'kora_inventory:server:combinations')
    if ok and type(list) == 'table' then
        remote = list
    end
end)

-- Server callback: runs the bar. true = finished, false = cancelled/refused.
Kora.callback.register('kora_inventory:client:combineProgress', function(request)
    local duration = math.floor(tonumber(request and request.time) or 0)
    if duration <= 0 then
        return true
    end
    local ped = Kora.cache.ped()
    local label = type(request.label) == 'string' and request.label or Kora.lang('ui.combine')
    local started, completed = pcall(Kora.progressbar.start, {
        label = label,
        duration = duration,
        canCancel = true,
    })
    if not started or completed ~= true then
        return false
    end
    return Kora.cache.ped() == ped and not IsPedDeadOrDying(ped, true)
end)
