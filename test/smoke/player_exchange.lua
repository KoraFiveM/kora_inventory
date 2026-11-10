local H=dofile('test/harness.lua')
local setup=dofile('test/exchange_fixture.lua')

local function prepare()
    local f=setup();assert(f.login(1,'CID1'))
    assert(Core.inventory.addItem(1,'water_bottle',3))
    return f
end

-- One durable operation combines item removal, money, reputation and all receipts.
do
    local f=prepare();local terms=f.terms({take={{name='water_bottle',amount=2}},cash=100,dealerRep=2})
    local receipt=assert(f.execute('settle',terms))
    H.equal(receipt.citizenid,'CID1');H.equal(f.count('water_bottle'),1)
    H.equal(f.data().money.cash,100);H.equal(f.data().metadata.rep.dealer,7)
    H.equal(f.data().metadata.rep.crafting,7);H.equal(next(f.db.fences),nil)
    assert(f.execute('settle',terms));H.equal(f.data().money.cash,100);H.equal(f.count('water_bottle'),1)
    H.equal(f.data().metadata.rep.dealer,7,'retry cannot duplicate reputation')
    terms.cash=101;local result,code=f.execute('settle',terms);H.equal(result,nil);H.equal(code,'conflict')
    terms.cash=100;terms.citizenid='CID2';result,code=f.execute('settle',terms);H.equal(result,nil);H.equal(code,'conflict')
end

-- Marked bills retain server metadata and deterministic request identity.
do
    local f=prepare();local terms=f.terms({take={{name='water_bottle',amount=1}},give={{name='markedbills',amount=1,info={worth=200,origin='dealer'}}},dealerRep=-8})
    assert(f.execute('bills',terms));H.equal(f.data().metadata.rep.dealer,0)
    local bills;for _,item in pairs(f.data().items) do if item.name=='markedbills' then bills=item end end
    H.equal(bills.info.worth,200);H.equal(f.data().money.cash,0)
    terms.give[1].info={origin='dealer',worth=200};assert(f.execute('bills',terms));H.equal(f.count('markedbills'),1)
    terms.give[1].info.worth=201;local result,code=f.execute('bills',terms);H.equal(result,nil);H.equal(code,'conflict')
end

-- Failures cannot consume an item without paying, or mint money without capacity.
for _,failure in ipairs({'missing','capacity','rollback','tax'}) do
    local f=prepare();local before=json.encode(f.data())
    local terms=f.terms({take={{name='water_bottle',amount=1}},cash=100,dealerRep=1})
    if failure=='missing' then terms.take[1].amount=4 end
    if failure=='capacity' then Config.kora_inventory.playerMaxWeight=0;terms.give={{name='markedbills',amount=1}} end
    if failure=='rollback' then f.rollback=true end
    if failure=='tax' then exports.kora_core.getTransactionTax=function() return 5 end end
    local result=f.execute('failure',terms);H.equal(result,nil,failure)
    H.equal(json.encode(f.data()),before,'failed exchange preserves player state: '..failure)
    H.equal(next(f.db.fences),nil);H.equal(next(f.db.receipts),nil)
end

-- Existing physical-cash authority remains item-backed with a zero ledger mirror.
do
    local f=prepare();Config.kora_inventory.cash.asItem=true
    f.caller='kora_inventory';assert(Core.money.registerPhysicalCash('cash'));f.caller='kora_drugs'
    assert(f.execute('cash-item',f.terms({take={{name='water_bottle',amount=1}},cash=50})))
    H.equal(f.count('cash'),50);H.equal(f.data().money.cash,0)
    H.equal(Core.money.getMoney(1,'cash'),50)
end

-- Real core column fences reject ordinary writes throughout an unknown outcome.
for _,outcome in ipairs({'commit','rollback','throw','delayed'}) do
    local f=prepare();local terms=f.terms({take={{name='water_bottle',amount=1}},cash=30,dealerRep=1})
    if outcome=='throw' then f.throw=true elseif outcome=='delayed' then f.delayed=true else f.ambiguous=outcome end
    local result,code=f.execute('uncertain',terms);H.equal(result,nil);H.equal(code,'pending')
    H.equal(Core.money.addMoney(1,'cash',1),false)
    H.equal(Core.inventory.addItem(1,'water_bottle',1),false)
    H.equal(Core.metadata.setMetaData(1,'rep',{dealer=100}),false)
    H.ok(next(f.db.fences),'unknown operation remains durably fenced')
    f.ambiguous,f.throw,f.delayed=nil,nil,nil
    assert(f.execute('uncertain',terms))
    H.equal(f.data().money.cash,30);H.equal(f.count('water_bottle'),2);H.equal(f.data().metadata.rep.dealer,6)
    H.equal(next(f.db.fences),nil)
end

-- A restarted provider recovers durable core fences without needing online players.
do
    local f=prepare();f.ambiguous='commit'
    local terms=f.terms({take={{name='water_bottle',amount=1}},cash=70,dealerRep=1})
    H.equal(f.execute('restart',terms),nil)
    local restarted=setup(f.db)
    H.equal(restarted.login(1,'CID1'),false,'login must not cross a persisted fence')
    assert(restarted.get('restart'));H.equal(next(restarted.db.fences),nil)
    assert(restarted.login(1,'CID1'));H.equal(restarted.count('water_bottle'),2)
    H.equal(restarted.data().money.cash,70);H.equal(restarted.data().metadata.rep.dealer,6)
    assert(restarted.execute('restart',terms));H.equal(restarted.data().money.cash,70)
end

-- Scope, source reuse, conflicts while a worker runs, and failed publication.
do
    local f=prepare();f.caller='other'
    H.equal(f.provided.ExecutePlayerExchange(1,'forged',f.terms({cash=100})),nil)
    f.afterFence=function()
        H.equal(Core.player.logout(1),false,'logout must not cross the pending exchange')
        Core.player.dropPlayer(1,'controlled source reuse')
        assert(f.login(1,'OTHER'))
    end
    H.equal(f.execute('reused',f.terms({cash=100})),nil)
    H.equal(f.data().citizenid,'OTHER');H.equal(f.data().money.cash,0)
    H.equal(next(f.db.receipts),nil)
end

do
    local f=prepare();f.failRelease=true
    H.equal(f.execute('release',f.terms({cash=15})),nil)
    H.ok(next(f.db.fences));f.failRelease=false
    assert(f.get('release'));H.equal(f.data().money.cash,15);H.equal(next(f.db.fences),nil)
end

-- Competing requests and ordinary writes cannot cross the in-flight SQL boundary.
do
    local f=prepare();f.defer=true
    local terms=f.terms({cash=25,dealerRep=1})
    local worker=coroutine.create(function() return f.execute('concurrent',terms) end)
    local ok,wait=coroutine.resume(worker);H.equal(ok,true);H.equal(wait,'commit')
    local result,code=f.execute('concurrent',terms);H.equal(result,nil);H.equal(code,'pending')
    result,code=f.execute('different',terms);H.equal(result,nil);H.equal(code,'pending')
    H.equal(Core.metadata.setMetaData(1,'hunger',0),false)
    H.equal(Core.money.addMoney(1,'bank',100),false)
    H.equal(Core.inventory.clearInventory(1),false)
    ok,result=coroutine.resume(worker);H.equal(ok,true);H.equal(result.cash,25)
    H.equal(f.data().money.cash,25);H.equal(f.data().metadata.rep.dealer,6)
end

-- Read failures retain fences; a stopped provider is recovered by the native worker.
do
    local f=prepare();f.ambiguous='commit'
    H.equal(f.execute('read-failure',f.terms({cash=40})),nil)
    f.failRead=true;local result,code=f.get('read-failure');H.equal(result,nil);H.equal(code,'pending')
    H.equal(Core.money.addMoney(1,'cash',1),false);H.ok(next(f.db.fences))
    local restored=setup(f.db)
    local worker=coroutine.create(restored.threads[#restored.threads])
    H.equal(coroutine.resume(worker),true);H.equal(next(restored.db.fences),nil)
    assert(restored.login(1,'CID1'));H.equal(restored.data().money.cash,40)
end

do
    local f=prepare();f.ambiguous='rollback'
    local terms=f.terms({take={{name='water_bottle',amount=1}},cash=40})
    H.equal(f.execute('rolled-back-restart',terms),nil)
    local restored=setup(f.db)
    local result,code=restored.get('rolled-back-restart');H.equal(result,nil);H.equal(code,'not_found')
    H.equal(next(restored.db.fences),nil);assert(restored.login(1,'CID1'))
    H.equal(restored.count('water_bottle'),3);H.equal(restored.data().money.cash,0)
    assert(restored.execute('rolled-back-restart',terms));H.equal(restored.data().money.cash,40)
end

-- A conflicting fingerprint cannot release a worker which has not reached its receipt.
do
    local f=prepare();f.delayed=true
    local terms=f.terms({cash=10});H.equal(f.execute('old-worker',terms),nil)
    f.delayed=nil;local changed=f.terms({cash=20})
    local result,code=f.execute('old-worker',changed);H.equal(result,nil);H.equal(code,'pending')
    H.ok(next(f.db.fences));H.equal(f.data().money.cash,0)
    assert(f.execute('old-worker',terms));H.equal(f.data().money.cash,10)
end

do
    local f=prepare()
    H.equal(f.execute('empty',f.terms()),nil)
    local bad=f.terms({cash=10});bad.unhandled=1;H.equal(f.execute('extra',bad),nil)
    local info={};info.self=info
    H.equal(f.execute('cyclic',f.terms({give={{name='markedbills',amount=1,info=info}}})),nil)
    H.equal(next(f.db.receipts),nil)
end

H.finish()
