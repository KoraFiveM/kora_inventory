-- Real core fences, player funnel and inventory planner with SQL transport mocked.
return function(database)
    local mocks = dofile('../kora_core/test/mocks.lua').install()
    dofile('../kora_core/config.lua')
    for _,name in ipairs({'items','jobs','gangs','weapons','vehicles','locations'}) do dofile('../kora_core/shared/'..name..'.lua') end
    for _,path in ipairs({'util/shared','registry/shared','registry/server','player/shared','inventory/shared','replication/server','persistence/server','persistence/operations','player/server','money/server','metadata/server','inventory/server'}) do dofile('../kora_core/modules/'..path..'.lua') end
    local f={db=database or {players={},fences={},receipts={}},provided={},threads={},caller='kora_drugs',core=Core,mocks=mocks}
    local function copy(v) return Core.util.deepClone(v) end
    GetInvokingResource=function() return f.caller end
    GetCurrentResourceName=function() return 'kora_inventory' end
    GetResourceState=function() return 'started' end
    RegisterCommand=function() end
    CreateThread=function(fn) f.threads[#f.threads+1]=fn end
    Wait=function() coroutine.yield('wait') end
    local native={}
    for _,module in pairs(Core) do
        for name,fn in pairs(module) do
            if type(fn)=='function' and name:sub(1,1)~='_' then native[name]=function(_, ...)
                local old=f.caller;f.caller='kora_inventory'
                local values=table.pack(pcall(fn,...));f.caller=old
                if not values[1] then error(values[2]) end
                return table.unpack(values,2,values.n)
            end end
        end
    end
    exports=setmetatable({kora_core=native,kora_sql={hasActivePlayerOperation=function() return false end}}, {__call=function(_,name,fn) f.provided[name]=fn end})
    exports.kora_inventory=setmetatable({}, {__index=function(_,name) return function(_, ...)
        local old=f.caller;f.caller='kora_core';local values=table.pack(pcall(f.provided[name],...));f.caller=old
        if not values[1] then error(values[2]) end;return table.unpack(values,2,values.n)
    end end})
    local sql=Kora.sql
    sql.ready,sql.ensureTables=function() return true end,function() return true end
    sql.query=function(query,params)
        if query:find('kora_core_player_column_operations',1,true) then
            local rows={};for _,row in pairs(f.db.fences) do
                if query:find('`resource`=?',1,true) and row.resource==params[1] or not query:find('`resource`=?',1,true) and row.citizenid==params[1] then rows[#rows+1]=copy(row) end
            end;return rows
        end
        return {}
    end
    sql.single=function(query,params)
        if query:find('kora_core_player_column_operations',1,true) then
            for _,row in pairs(f.db.fences) do if row.citizenid==params[1] then return copy(row) end end;return nil
        end
        if query:find('FROM `players`',1,true) then return copy(f.db.players[params[1]]) end
    end
    sql.enqueueMany=function(_,_,rows)
        for _,row in ipairs(rows) do for field,value in pairs(row.cols) do f.db.players[row.pk][field]=value end end
    end
    sql.flush=function() return true end
    sql.update=function(query,params)
        assert(query:find('DELETE FROM `kora_core_player_column_operations`',1,true),query)
        if f.failRelease then return nil,'release unavailable' end
        for key,row in pairs(f.db.fences) do if row.resource==params[1] and row.operation_key==params[2] then f.db.fences[key]=nil end end
        return 3
    end
    local function commit(statements)
        local p=statements[1].values
        local id=p[1]..':'..p[2]
        if f.db.receipts[id] then return {success=false,code='duplicate'} end
        local row=f.db.players[p[3]]
        if not row then return {success=false,code='conflict'} end
        f.db.receipts[id]={provider=p[1],operation_key=p[2],citizenid=p[3],request=p[4],player_values=p[5],receipt=p[6]}
        local values=statements[2].values
        row.inventory,row.money,row.metadata=values[1],values[2],values[3]
        return {success=true,results={{affectedRows=1},{affectedRows=1}}}
    end
    sql.awaitCheckedOperation=function(_,fingerprint)
        if f.db.pending then
            local pending=f.db.pending
            if fingerprint and fingerprint~=pending.context.fingerprint then return {active=true,result={code='indeterminate'}} end
            f.db.pending=nil;return {active=true,result=commit(pending.statements)}
        end
        return {active=false}
    end
    sql.transactionChecked=function(statements,context)
        local first=statements[1]
        if first.query:find('SELECT * FROM `kora_inventory_player_exchanges`',1,true) then
            if f.failRead then return nil,'read unavailable' end
            local row=f.db.receipts[first.values[1]..':'..first.values[2]]
            return {success=true,results={row and {copy(row)} or {}}}
        end
        if first.query:find('INSERT INTO `kora_core_player_column_operations`',1,true) then
            for _,s in ipairs(statements) do local p=s.values;f.db.fences[p[1]..':'..p[2]]={citizenid=p[1],column_name=p[2],resource=p[3],operation_key=p[4],fingerprint=p[5]} end
            if f.afterFence then f.afterFence() end
            return {success=true}
        end
        assert(first.query:find('INSERT INTO `kora_inventory_player_exchanges`',1,true),first.query)
        f.lastStatements,f.lastContext=copy(statements),copy(context)
        if f.defer then f.defer=false;coroutine.yield('commit') end
        if f.rollback then return {success=false,code='unavailable',message='controlled rollback'} end
        if f.delayed then f.db.pending={statements=copy(statements),context=copy(context)};return {success=false,code='indeterminate'} end
        local result=f.ambiguous=='rollback' and {success=false,code='indeterminate'} or commit(statements)
        if f.throw then error('lost export acknowledgement') end
        if f.ambiguous then return {success=false,code='indeterminate'} end
        return result
    end
    Config.kora_inventory=nil;KoraInventory=nil
    dofile('config.lua');dofile('shared.lua');dofile('server/persistence.lua');dofile('server.lua');dofile('server/exchange.lua')
    f.threads[1]()
    Core.registry.registerShared('items','markedbills',{name='markedbills',label='Marked bills',weight=1000,type='item',unique=true})
    function f.login(src,cid)
        local row=f.db.players[cid]
        local data
        if row then
            local err;data,err=Core.persistence._load(cid);if not data then return false,err end
        else
            data=CoreInternal.player.freshData(cid,'license:'..cid,1,{})
            data.money={cash=0,bank=1000,crypto=0};data.metadata.rep={dealer=5,crafting=7}
            f.db.players[cid]={citizenid=cid,license=data.license,cid=1}
            for _,field in ipairs({'money','metadata','charinfo','job','gang','position'}) do f.db.players[cid][field]=json.encode(data[field]) end
            f.db.players[cid].inventory='{}'
        end
        return Core.player.login(src,cid,data)
    end
    function f.execute(key,terms)
        f.caller='kora_drugs';return f.provided.ExecutePlayerExchange(1,key,terms)
    end
    function f.get(key) f.caller='kora_drugs';return f.provided.GetPlayerExchange(key) end
    function f.data() return Core.player.getPlayerData(1) end
    function f.count(name)
        local count=0;for _,item in pairs(f.data().items) do if item.name==name then count=count+item.amount end end;return count
    end
    function f.terms(extra)
        local value={citizenid='CID1',take={},give={},cash=0,dealerRep=0,reason='delivery'}
        for key,v in pairs(extra or {}) do value[key]=v end;return value
    end
    f.inventory=KoraInventory
    return f
end
