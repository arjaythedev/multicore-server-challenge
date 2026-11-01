import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createHttpDiagnostics } from '../dist/http-diagnostics.js';
import http from 'node:http';
import { spawnSync } from 'node:child_process';

const dir = mkdtempSync(join(tmpdir(), 'node26-http-unit-'));
process.env.BENCH_DIAGNOSTICS_DIR = dir;
const random = Math.random;
try {
  Math.random = () => 0; // Deterministically exercise all sampled phases.
  const diag = await createHttpDiagnostics();
  for (const [label, bytes, status] of [['comments', 100, 200], ['articles', 10000, 200], ['articles', 100000, 200], ['error', 30, 401], ['delete', 0, 204]]) {
    const res = new EventEmitter(); res.statusCode = status;
    diag.begin(res); diag.route(res, label);
    for (const phase of ['auth', 'lookup', 'query', 'mapping']) diag.phase(res, phase);
    diag.end(res, bytes, diag.serializationStart(res));
    diag.end(res, bytes); // no double-counting
    res.emit('finish'); res.emit('close');
    assert.equal(res.listenerCount('close'), 0);
  }
  const res = new EventEmitter(); res.statusCode = 200;
  diag.begin(res); diag.route(res, 'aborted'); res.emit('close'); res.emit('finish');
  diag.phase(res, 'query'); diag.end(res, 123); // handler can finish after disconnect
  const during = new EventEmitter(); during.statusCode = 200;
  diag.begin(during); diag.route(during, 'close-after-end'); diag.end(during, 9000); during.emit('close');
  const spanning = new EventEmitter(); spanning.statusCode = 200;
  diag.begin(spanning); diag.route(spanning, 'spanning');
  await delay(10050); // periodic report while a request remains in flight
  diag.end(spanning, 2); spanning.emit('finish'); spanning.emit('close');
  const finish = diag.finish(); assert.equal(diag.finish(), finish); await finish;
  const records = readdirSync(dir).flatMap(f => readFileSync(join(dir, f), 'utf8').trim().split('\n').map(JSON.parse));
  const worker = records.find(r => r.kind === 'worker' && r.final);
  assert(worker.final && worker.loop_delay_ms && worker.cpu_user_ms >= 0);
  const endpoints = records.filter(r => r.kind === 'endpoint');
  assert.equal(endpoints.reduce((s, r) => s + r.started, 0), 8);
  assert.equal(endpoints.reduce((s, r) => s + r.finished, 0), 6);
  assert.equal(endpoints.reduce((s, r) => s + r.premature_close, 0), 2);
  assert(endpoints.filter(r => r.final).every(r => r.in_flight === 0));
  assert.equal(endpoints.find(r => r.label === 'spanning' && !r.final).in_flight, 1);
  assert.equal(endpoints.find(r => r.label === 'spanning' && r.final).finished, 1);
  assert.equal(endpoints.find(r => r.label === 'error').errors, 1);
  const articles = endpoints.find(r => r.label === 'articles');
  assert.deepEqual(articles.sizes.map(s => s.count), [0, 1, 1]);
  assert.equal(endpoints.find(r => r.label === 'comments').phases.auth.count, 1);
  assert.equal(endpoints.find(r => r.label === 'aborted').flush_ms.count, 0);
  process.env.BENCH_DIAGNOSTICS_DIR = join(dir, 'network');
  const netDiag = await createHttpDiagnostics();
  let abortRequest;
  const server = http.createServer((req, res) => {
    netDiag.begin(res); netDiag.route(res, 'network');
    if (req.url === '/abort') {
      abortRequest.destroy();
      setTimeout(() => { netDiag.end(res, 4); res.end('late'); }, 30);
    } else { netDiag.end(res, 2); res.end('ok'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    await new Promise(resolve => http.get(`http://127.0.0.1:${server.address().port}/ok`, { agent: false }, res => { res.resume(); res.on('end', resolve); }));
    await new Promise(resolve => { abortRequest = http.get(`http://127.0.0.1:${server.address().port}/abort`, { agent: false }); abortRequest.on('error', resolve); });
    await delay(60);
  } finally { await new Promise(resolve => server.close(resolve)); await netDiag.finish(); }
  const networkRecords = readdirSync(join(dir, 'network')).flatMap(f => readFileSync(join(dir, 'network', f), 'utf8').trim().split('\n').map(JSON.parse));
  const network = networkRecords.find(r => r.label === 'network');
  assert.equal(network.finished, 1); assert.equal(network.premature_close, 1); assert.equal(network.in_flight, 0);
  for (const flag of ['0', undefined]) {
    const env = { ...process.env, DATABASE_URL: 'postgres://unused/unused', JWT_SECRET: 'unit', PG_POOL_SIZE: '1', BENCH_DIAGNOSTICS: '0', BENCH_HTTP_DIAGNOSTICS: flag,
      BENCH_DIAGNOSTICS_DIR: '/dev/null/invalid', BENCH_DIAGNOSTICS_MAX_BYTES: 'invalid' };
    if (flag === undefined) delete env.BENCH_HTTP_DIAGNOSTICS;
    const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
      import assert from 'node:assert/strict';
      const timers = process.getActiveResourcesInfo().filter(x => x === 'Timeout').length;
      const { httpDiagnostics, pool } = await import('./dist/utils.js');
      assert.equal(httpDiagnostics, undefined);
      assert.equal(process.getActiveResourcesInfo().filter(x => x === 'Timeout').length, timers);
      await pool.end();`], { env, encoding: 'utf8', timeout: 3000 });
    assert.equal(child.status, 0, child.stderr); assert.equal(child.stdout, '');
  }
  console.error('PASS HTTP: sizes, sampled phases, 401/204, close before/after end, no double count, listeners, final flush');
} finally { Math.random = random; rmSync(dir, { recursive: true, force: true }); }
