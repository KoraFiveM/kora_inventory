// Run only by exchange_database.py against its disposable socket-only server.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const mysql = require(path.join(root, '../kora_sql/node_modules/mysql2/promise'));
const { TransactionRunner } = require(path.join(root, '../kora_sql/server/js/transaction'));
const { SchemaManager } = require(path.join(root, '../kora_sql/server/js/schema'));
function exchangeSchema() {
    const dump = spawnSync('lua', ['-'], { cwd: root, encoding: 'utf8', input: `
        dofile('test/exchange_fixture.lua')(); dofile('server/schema.lua')
        for _,spec in ipairs(QBInventorySchema) do
            if spec.name=='kora_inventory_player_exchanges' then print('SPEC:'..json.encode(spec)) end
        end
    ` });
    assert.equal(dump.status, 0, dump.stderr);
    return JSON.parse(dump.stdout.split('SPEC:')[1].trim());
}
function emittedStatements() {
    const capture = spawnSync('lua', ['-'], { cwd: root, encoding: 'utf8', input: `
        local f=dofile('test/exchange_fixture.lua')(); assert(f.login(1,'CID1'))
        assert(Core.inventory.addItem(1,'water_bottle',3)); f.rollback=true
        local read; local run=Kora.sql.transactionChecked
        Kora.sql.transactionChecked=function(statements,context)
            if statements[1].query:find('SELECT * FROM \`kora_inventory_player_exchanges\`',1,true) then read=statements[1] end
            return run(statements,context)
        end
        f.execute('settle',f.terms({take={{name='water_bottle',amount=2}},cash=100,dealerRep=2}))
        print('CAPTURE:'..json.encode({statements=f.lastStatements,context=f.lastContext,before=f.db.players.CID1,read=read}))
    ` });
    assert.equal(capture.status, 0, capture.stderr);
    return JSON.parse(capture.stdout.split('CAPTURE:')[1].trim().replace(/\\\n/g, '\\n').replace(/\\0/g, '\\u0000'));
}
test('actual exchange SQL and qbsql checked transactions on disposable MariaDB', { skip: !process.env.QBINVENTORY_TEST_SOCKET }, async t => {
    const fixture = emittedStatements();
    const pool = mysql.createPool({ socketPath: process.env.QBINVENTORY_TEST_SOCKET, user: 'root', database: 'exchange_test', multipleStatements: true, connectionLimit: 5 });
    const runner = new TransactionRunner({ write: pool });
    const rows = async query => (await pool.query(query))[0];
    const snapshot = async () => (await rows('SELECT inventory,money,metadata FROM players WHERE citizenid="CID1"'))[0];
    const reset = async () => {
        await pool.query('DELETE FROM kora_inventory_player_exchanges; DELETE FROM players;');
        const before = fixture.before;
        await pool.query('INSERT INTO players(citizenid,inventory,money,metadata) VALUES (?,?,?,?)', [before.citizenid,before.inventory,before.money,before.metadata]);
    };
    const read = async (executor = runner) => executor.transactionChecked([fixture.read]);
    const original = () => ({ inventory: fixture.before.inventory, money: fixture.before.money, metadata: fixture.before.metadata });
    const expected = () => ({ inventory: fixture.statements[1].values[0], money: fixture.statements[1].values[1], metadata: fixture.statements[1].values[2] });
    try {
        await pool.query('CREATE TABLE players(citizenid VARCHAR(50) PRIMARY KEY, inventory LONGTEXT, money LONGTEXT, metadata LONGTEXT, deleted_at TIMESTAMP NULL) ENGINE=InnoDB');
        await t.test('migration is repeatable and receipts precede the guarded player mutation', async () => {
            const schema = new SchemaManager({ write: pool }); const spec = exchangeSchema();
            await schema.ensureTable(spec); await schema.ensureTable(spec); await reset();
            assert.match(fixture.statements[0].query, /^INSERT INTO `kora_inventory_player_exchanges`/);
            assert.match(fixture.statements[1].query, /^UPDATE `players`/);
            assert.equal(fixture.statements[0].expectedRows, 1); assert.equal(fixture.statements[1].expectedRows, 1);
            assert.match(fixture.read.query, /FOR UPDATE$/);
        });
        await t.test('item, cash, reputation and receipt commit together; restart replay is rejected', async () => {
            assert.equal((await runner.transactionChecked(fixture.statements, fixture.context)).success, true);
            assert.deepEqual(await snapshot(), expected());
            const stored = (await read()).results[0][0];
            assert.equal(stored.request, fixture.context.fingerprint); assert.equal(stored.citizenid, 'CID1');
            assert.equal(JSON.parse(stored.receipt).dealerRep, 2);
            assert.equal(JSON.parse(stored.player_values).metadata.rep.crafting, 7);
            const restarted = new TransactionRunner({ write: pool });
            assert.equal((await restarted.transactionChecked(fixture.statements, fixture.context)).code, 'duplicate');
            assert.deepEqual(await snapshot(), expected());
            assert.equal((await rows('SELECT COUNT(*) n FROM kora_inventory_player_exchanges'))[0].n, 1);
        });
        await t.test('missing or deleted player rolls back the earlier receipt insert', async () => {
            for (const deleted of [false, true]) {
                await reset(); if (deleted) await pool.query('UPDATE players SET deleted_at=NOW()');
                const statements = structuredClone(fixture.statements);
                if (!deleted) statements[1].values[3] = 'MISSING';
                assert.equal((await runner.transactionChecked(statements, fixture.context)).code, 'conflict');
                assert.deepEqual(await snapshot(), original()); assert.equal((await read()).results[0].length, 0);
            }
        });
        await t.test('SQL failure after both writes rolls the entire operation back', async () => {
            await reset();
            const result = await runner.transactionChecked([...fixture.statements, { query: 'INSERT INTO missing_exchange_table VALUES (1)' }], fixture.context);
            assert.equal(result.code, 'unavailable');
            assert.deepEqual(await snapshot(), original()); assert.equal((await read()).results[0].length, 0);
        });
        await t.test('lost commit acknowledgements resolve from durable receipts after runner restart', async () => {
            for (const committed of [true, false]) {
                await reset();
                const uncertain = new TransactionRunner({ write: { getConnection: async () => {
                    const connection = await pool.getConnection();
                    return new Proxy(connection, { get(target, name) {
                        if (name === 'commit') return async () => {
                            if (committed) await target.commit(); else await target.rollback();
                            throw new Error('Controlled missing COMMIT acknowledgement');
                        };
                        const value = target[name]; return typeof value === 'function' ? value.bind(target) : value;
                    } });
                } } });
                assert.equal((await uncertain.transactionChecked(fixture.statements, fixture.context)).code, 'indeterminate');
                const restarted = new TransactionRunner({ write: pool });
                assert.equal((await read(restarted)).results[0].length, committed ? 1 : 0);
                assert.deepEqual(await snapshot(), committed ? expected() : original());
                if (!committed) assert.equal((await restarted.transactionChecked(fixture.statements, fixture.context)).success, true);
                assert.equal((await restarted.transactionChecked(fixture.statements, fixture.context)).code, 'duplicate');
                assert.deepEqual(await snapshot(), expected());
            }
        });
        await t.test('fresh write-primary receipt read waits for an old worker commit or rollback', async () => {
            for (const committed of [true, false]) {
                await reset(); const previous = await pool.getConnection();
                try {
                    await previous.beginTransaction();
                    for (const statement of fixture.statements) await previous.query(statement.query, statement.values);
                    assert.deepEqual(await snapshot(), original());
                    assert.equal((await rows('SELECT COUNT(*) n FROM kora_inventory_player_exchanges'))[0].n, 0);
                    let finished = false;
                    const restarted = new TransactionRunner({ write: pool, read: { getConnection() { throw new Error('Replica must not reconcile'); } } });
                    const recovery = read(restarted).then(value => { finished = true; return value; });
                    await new Promise(resolve => setTimeout(resolve, 40));
                    assert.equal(finished, false, 'locking receipt read must join the old database transaction');
                    if (committed) await previous.commit(); else await previous.rollback();
                    const result = await recovery;
                    assert.equal(result.success, true); assert.equal(result.results[0].length, committed ? 1 : 0);
                    assert.deepEqual(await snapshot(), committed ? expected() : original());
                } finally { await previous.rollback(); previous.release(); }
            }
        });
    } finally { await pool.end(); }
});
