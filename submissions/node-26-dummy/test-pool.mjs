// Isolated pool contracts. TEST_DATABASE_URL points to the test PostgreSQL instance.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { Pool } from 'pg';

assert(process.env.TEST_DATABASE_URL, 'TEST_DATABASE_URL required');
const mode = process.argv[2];
if (!mode) {
  for (const scenario of ['off', 'unset', 'on', 'failure']) {
    const env = { ...process.env, BENCH_DIAGNOSTICS: scenario === 'off' ? '0' : '1' };
    if (scenario === 'unset') delete env.BENCH_DIAGNOSTICS;
    const child = spawn(process.execPath, [import.meta.filename, scenario], { env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    const code = await new Promise(resolve => child.on('exit', resolve));
    assert.equal(code, 0, `${scenario}: ${stderr}`);
    const records = stdout.split('\n').flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
    if (['off', 'unset'].includes(scenario)) assert.equal(records.length, 0);
    else {
      assert.equal(records.filter(r => r.final).length, 1);
      const final = records.at(-1);
      assert.equal(final.current.total, 0);
      for (const record of records) {
        assert(record.duration_ms > 0);
        assert.equal(record.acquisitions.all.count, record.successes + record.failures);
        for (const h of Object.values(record.acquisitions)) assert.equal(h.count, h.buckets.reduce((a, b) => a + b, 0));
      }
      const sum = path => records.reduce((n, r) => n + path(r), 0);
      if (scenario === 'on') {
        assert.equal(sum(r => r.connections.created), 2);
        assert.equal(sum(r => r.connections.removed), 2);
        assert.equal(sum(r => r.acquisitions.new.count), 2);
        assert(sum(r => r.acquisitions.reused.count) >= 5);
        assert(sum(r => r.failures) >= 2);
        assert(records.some(r => r.observed_max.waiting >= 1));
        assert(records.some(r => !r.final));
      } else {
        assert.equal(sum(r => r.failures), 2);
        assert.equal(sum(r => r.connections.created), 0);
      }
      console.log(`PASS ${scenario}: ${records.length} intervals; callback/Promise accounting and cleanup`);
    }
    console.log(`PASS ${scenario}: child exits naturally (no diagnostic timer keeps it alive)`);
  }
} else {
  const url = new URL(process.env.TEST_DATABASE_URL);
  if (mode === 'failure') url.pathname = '/node26_missing_diagnostic_database';
  process.env.DATABASE_URL = url.href;
  process.env.JWT_SECRET = 'pool-tests';
  process.env.PG_POOL_SIZE = '2';
  const original = Pool.prototype.connect;
  const timersBefore = process.getActiveResourcesInfo().filter(x => x === 'Timeout').length;
  const { pool, transaction, finishPoolDiagnostics } = await import('./dist/utils.js');
  if (['off', 'unset'].includes(mode)) {
    assert.equal(pool.connect, original);
    assert.equal(finishPoolDiagnostics, undefined);
    assert.equal(process.getActiveResourcesInfo().filter(x => x === 'Timeout').length, timersBefore);
    assert.equal(pool.listenerCount('connect'), 0);
    await pool.query('SELECT 1');
    await pool.end();
  } else if (mode === 'failure') {
    await assert.rejects(pool.connect(), error => error.code === '3D000');
    await new Promise((resolve, reject) => pool.connect((error, client) => {
      try { assert.equal(error.code, '3D000'); assert.equal(client, undefined); resolve(); } catch (e) { reject(e); }
    }));
    await pool.end(); await finishPoolDiagnostics();
  } else {
    const first = await pool.connect();
    first.release();
    await new Promise((resolve, reject) => {
      assert.equal(pool.connect((error, client, release) => {
        try {
          assert.ifError(error); assert.equal(client, first); assert.equal(release, client.release);
          release(); resolve();
        } catch (e) { reject(e); }
      }), undefined);
    });
    assert.equal((await pool.query('SELECT 42 AS n')).rows[0].n, 42);
    await new Promise((resolve, reject) => pool.query('SELECT 7 AS n', (error, result) => {
      try { assert.ifError(error); assert.equal(result.rows[0].n, 7); resolve(); } catch (e) { reject(e); }
    }));
    assert.equal(await transaction(async client => (await client.query('SELECT 8 AS n')).rows[0].n), 8);
    const sentinel = new Error('rollback');
    await assert.rejects(transaction(async () => { throw sentinel; }), error => error === sentinel);
    const a = await pool.connect(), b = await pool.connect();
    assert.notEqual(a, b);
    const queued = pool.connect();
    assert.equal(pool.waitingCount, 1);
    await delay(50); a.release();
    const reused = await queued; assert.equal(reused, a);
    // Keep both clients held long enough to exercise the real 10s acquire timeout
    // and the periodic report, without changing application pool settings.
    await assert.rejects(pool.connect(), /timeout exceeded/);
    reused.release(); b.release();
    await pool.end();
    await assert.rejects(pool.connect(), /after calling end/);
    await finishPoolDiagnostics(); await finishPoolDiagnostics();
    assert.equal(pool.connect, original);
  }
}
