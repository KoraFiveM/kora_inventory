-- Water damage reporter (Config.kora_inventory.waterDamage). The client's only
-- job is to say, with NO payload, that the local player has been swimming for a
-- while; the server rate-limits it and decides what (if anything) happens to
-- the player's own items. There is no per-frame loop: it ticks once a second
-- while the feature is enabled and idles on a slow poll while it is off.
local EVENT = 'kora_inventory:server:waterExposure'

local function settings()
    local cfg = (Config.kora_inventory or {}).waterDamage
    return type(cfg) == 'table' and cfg or nil
end

local function inWater(ped)
    return IsPedSwimming(ped) or IsPedSwimmingUnderWater(ped)
end

CreateThread(function()
    local seconds = 0
    while true do
        local cfg = settings()
        if not cfg or cfg.enabled ~= true then
            seconds = 0
            Wait(5000)
        else
            Wait(1000)
            if inWater(PlayerPedId()) then
                seconds = seconds + 1
                local needed = math.max(1, math.floor(tonumber(cfg.swimSeconds) or 3))
                if seconds >= needed then
                    seconds = 0
                    TriggerServerEvent(EVENT)
                end
            else
                seconds = 0
            end
        end
    end
end)
