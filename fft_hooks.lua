-- Optional FFT development hooks (client). Listed last in fxmanifest.lua and
-- inert unless `setr fft_kora_hooks true`. No other inventory file references
-- FFT. All mutations still flow through the rendered NUI.
if not GetConvar or GetConvar('fft_kora_hooks','false') ~= 'true' then return end
local runner = 'fft'
local pending, counter = {}, 0
local sync
local function session()
    if not GetConvar or GetConvar('fft_kora_hooks','false') ~= 'true' then return nil end
    if GetResourceState(runner) ~= 'started' then return nil end
    local id = LocalPlayer.state.fftSession
    return type(id)=='string' and id or nil
end
local function fftAction(action,item,amount)
    local id=session()
    if GetInvokingResource()~=runner or not id then return false,'FFT hooks are disabled or session is not authorised' end
    if action~='dragBuy' and action~='selectItem' and action~='buyReady' and action~='quantity' and action~='buy' then return false,'Unsupported UI action' end
    if type(item)~='string' or #item>100 then return false,'Invalid item' end
    local inventory=exports.kora_inventory:getCurrentSession()
    if not inventory or not inventory.secondary or inventory.secondary.type~='shop' then return false,'No active shop session' end
    counter=counter+1
    local request=tostring(counter)
    local entry={session=id,token=inventory.token}
    pending[request]=entry
    -- The page may have loaded after the session bag changed; restate it first.
    sync(true)
    SendNUIMessage({action='fft:action',data={request=request,session=id,token=inventory.token,action=action,item=item,amount=amount}})
    local deadline=GetGameTimer()+2000
    while not entry.result and GetGameTimer()<deadline and session()==id do Wait(25) end
    pending[request]=nil
    local current=exports.kora_inventory:getCurrentSession()
    if not current or current.token~=entry.token or session()~=id then return false,'Stale UI session' end
    if not entry.result then return false,'Inventory UI hook did not answer' end
    return entry.result.ok==true,entry.result.error
end
RegisterNUICallback('fft:result',function(data,cb)
    local p=type(data)=='table' and pending[data.request]
    if p and p.session==session() and p.session==data.session and p.token==data.token then
        p.result={ok=data.ok==true,error=type(data.error)=='string' and data.error:sub(1,500) or nil}
    end
    cb({ok=true})
end)
RegisterNUICallback('fft:observed',function(data,cb)
    if session() and type(data)=='table' and type(data.action)=='string' then
        TriggerEvent('fft:kora:inventory',{action=data.action:sub(1,40),item=type(data.item)=='string' and data.item:sub(1,100) or nil})
    end
    cb({ok=true})
end)
local lastSession=false
sync=function(force)
    local id=session() or false
    if force or id or lastSession then SendNUIMessage({action='fft:session',data={session=id}}) end
    lastSession=id
end
if AddStateBagChangeHandler then AddStateBagChangeHandler('fftSession',nil,function(bag)
    if bag==('player:%s'):format(GetPlayerServerId(PlayerId())) then SetTimeout(0,sync) end
end) end

exports('fftVersion', function() return 1 end)
exports('fftAction', fftAction)
