// Own processes/ports only. Read-only workload against an explicitly supplied test DB.
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, mkdtempSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { performance } from 'node:perf_hooks';
import { gunzipSync } from 'node:zlib';
import { Pool } from 'pg';
import { SignJWT } from 'jose';

const mode = process.argv[2];
assert(['otel', 'overhead'].includes(mode), 'verify.mjs otel|overhead');
assert(process.env.TEST_DATABASE_URL, 'TEST_DATABASE_URL must target an isolated seed clone');
const dbUrl = new URL(process.env.TEST_DATABASE_URL);
assert(dbUrl.pathname.startsWith('/node26_'), 'Use an isolated node26_* database');
const root = new URL('../', import.meta.url).pathname;
const secret = 'isolated-diagnostic-verification';
const db = new Pool({ connectionString: dbUrl.href });
const slug = (await db.query('SELECT slug FROM articles WHERE id=5000')).rows[0].slug;
const tag = (await db.query('SELECT name FROM tags ORDER BY id LIMIT 1')).rows[0].name;
await db.end();
const token = await new SignJWT({ sub: '100' }).setProtectedHeader({ alg: 'HS256' }).setExpirationTime('2h').sign(new TextEncoder().encode(secret));
const children = new Set();
const logRoot = mkdtempSync(join(tmpdir(), 'node26-verify-logs-'));
const records = app => app.output.split('\n').flatMap(line => {
  try { const value = JSON.parse(line); return value.event === 'pool_diagnostics' ? [value] : []; } catch { return []; }
});
const workerPids = app => app.output.split('\n').flatMap(line => {
  try { const value = JSON.parse(line); return value.event === 'worker_online' ? [value.pid] : []; } catch { return []; }
});
async function freePort() {
  const server = http.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}
async function request(app, path, agent = false) {
  const begin = performance.now();
  return new Promise(resolve => {
    const req = http.get({ host: '127.0.0.1', port: app.port, path, agent,
      headers: { authorization: `Token ${token}` }, timeout: 5000 }, res => {
      res.resume(); res.on('end', () => resolve({ ms: performance.now() - begin, error: res.statusCode !== 200 }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', () => resolve({ ms: performance.now() - begin, error: true }));
  });
}
async function start(enabled, extraEnv = {}) {
  const port = await freePort();
  const logDir = join(logRoot, String(port));
  const app = spawn(process.execPath, ['dist/cluster.js'], { cwd: root,
    env: { ...process.env, NODE_OPTIONS: '', OTEL_SDK_DISABLED: 'true',
      DATABASE_URL: dbUrl.href, JWT_SECRET: secret, HOST: '127.0.0.1', PORT: String(port), WORKERS: '6',
      BENCH_DIAGNOSTICS: enabled ? '1' : '0', BENCH_RUN_ID: `verify-${mode}-${enabled ? 'on' : 'off'}`,
      BENCH_HTTP_DIAGNOSTICS: enabled ? '1' : '0',
      BENCH_DIAGNOSTICS_DIR: enabled ? logDir : '', BENCH_DIAGNOSTICS_MAX_BYTES: '10485760', ...extraEnv },
    stdio: ['ignore', 'pipe', 'pipe'] });
  app.port = port; app.logDir = logDir; app.output = ''; app.errors = ''; app.bytes = 0;
  app.stdout.on('data', chunk => { app.output += chunk; app.bytes += chunk.length; });
  app.stderr.on('data', chunk => { app.errors += chunk; });
  app.done = new Promise(resolve => app.on('exit', (code, signal) => resolve({ code, signal })));
  children.add(app);
  for (let n = 0; n < 300; n++) {
    assert.equal(app.exitCode, null, app.errors);
    if (workerPids(app).length === 6 && app.output.split('dummy app listening').length === 7 && !(await request(app, '/api/tags')).error) return app;
    await delay(50);
  }
  throw new Error(`Server readiness timeout: ${app.errors}`);
}
async function stop(app, enabled) {
  app.kill('SIGTERM');
  let timer;
  const exit = await Promise.race([app.done, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Cluster shutdown timeout')), 12000);
  })]);
  clearTimeout(timer); children.delete(app);
  assert.equal(exit.code, 0, app.errors);
  for (const pid of workerPids(app)) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  const all = records(app);
  if (!enabled) { assert.equal(all.length, 0); assert(!app.output.includes('"event":"http_diagnostics"')); }
  else {
    const final = all.filter(r => r.final);
    assert.equal(final.length, 6);
    assert.equal(new Set(final.map(r => r.pid)).size, 6);
    assert.equal(new Set(final.map(r => r.worker_id)).size, 6);
    for (const record of final) assert.equal(record.current.total, 0);
    const files = readdirSync(app.logDir);
    for (const record of final) {
      const filename = `worker-${record.worker_id}-${record.pid}.jsonl`;
      assert(files.includes(filename));
      const content = readFileSync(join(app.logDir, filename), 'utf8').trim().split('\n').map(JSON.parse);
      assert.deepEqual(content.at(-1), record, 'final JSON on disk matches stdout');
    }
    for (const file of files) assert(statSync(join(app.logDir, file)).size <= 10485760);
    assert(files.length <= 24);
    const httpRecords = app.output.split('\n').flatMap(line => { try { const r = JSON.parse(line); return r.event === 'http_diagnostics' ? [r] : []; } catch { return []; } });
    assert.equal(httpRecords.filter(r => r.kind === 'worker' && r.final).length, 6);
    for (const r of httpRecords.filter(r => r.kind === 'worker')) {
      assert.equal(r.output.stdout.dropped, 0); assert.equal(r.output.stdout.errors, 0);
      assert.equal(r.output.file.dropped, 0); assert.equal(r.output.file.errors, 0);
    }
    for (const pid of workerPids(app)) {
      const r = httpRecords.filter(r => r.pid === pid && r.kind === 'endpoint');
      assert.equal(r.reduce((s, x) => s + x.started, 0), r.reduce((s, x) => s + x.finished + x.premature_close, 0));
      assert(r.filter(x => x.final).every(x => x.in_flight === 0));
      const file = files.find(f => f.startsWith('http-worker-') && f.endsWith(`-${pid}.jsonl`));
      assert(file); assert(readFileSync(join(app.logDir, file), 'utf8').includes('"final":true'));
    }
    for (const pid of workerPids(app)) {
      const own = all.filter(r => r.pid === pid);
      assert.equal(own.reduce((sum, r) => sum + r.connections.created, 0), own.reduce((sum, r) => sum + r.connections.removed, 0));
    }
  }
  return all;
}
const cpuTicks = app => [app.pid, ...workerPids(app)].reduce((sum, pid) => {
  const stat = readFileSync(`/proc/${pid}/stat`, 'utf8');
  const fields = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
  return sum + Number(fields[11]) + Number(fields[12]);
}, 0);
const paths = [
  ...Array(6).fill(`/api/articles/${slug}/comments`), ...Array(6).fill(`/api/articles/${slug}`),
  ...Array(4).fill('/api/tags'), '/api/articles?limit=10&offset=0', '/api/articles?limit=10&offset=40',
  '/api/articles/feed?limit=10&offset=20', `/api/articles?tag=${encodeURIComponent(tag)}&limit=10`,
];
async function workload(app, seconds) {
  const agent = new http.Agent({ keepAlive: true, maxSockets: 100 });
  const pending = [];
  let late = 0;
  const start = performance.now(), ticks = cpuTicks(app), bytes = app.bytes;
  for (let n = 0; n < seconds * 100; n++) {
    const due = start + n * 10;
    if (due > performance.now()) await delay(due - performance.now());
    if (performance.now() - due > 100) late++;
    pending.push(request(app, paths[n % paths.length], agent));
  }
  const results = await Promise.all(pending);
  const duration = performance.now() - start;
  const usedTicks = cpuTicks(app) - ticks;
  agent.destroy();
  const sorted = results.map(r => r.ms).sort((a, b) => a - b);
  const percentile = p => sorted[Math.ceil(sorted.length * p) - 1];
  return { requests: results.length, duration_ms: duration, errors: results.filter(r => r.error).length,
    p50_ms: percentile(0.5), p95_ms: percentile(0.95), p99_ms: percentile(0.99),
    node_cpu_ticks: usedTicks, log_bytes: app.bytes - bytes, scheduling_late_over_100ms: late };
}
let receiver;
try {
  if (mode === 'otel') {
    const exports = [];
    receiver = http.createServer(async (req, res) => {
      try {
        const chunks = []; for await (const chunk of req) chunks.push(chunk);
        const bytes = Buffer.concat(chunks);
        exports.push(JSON.parse((req.headers['content-encoding'] === 'gzip' ? gunzipSync(bytes) : bytes).toString()));
        res.writeHead(200, { 'content-type': 'application/json' }).end('{}');
      } catch { res.writeHead(400).end(); }
    });
    await new Promise(resolve => receiver.listen(0, '127.0.0.1', resolve));
    const spans = () => exports.flatMap(e => (e.resourceSpans ?? []).flatMap(r => (r.scopeSpans ?? []).flatMap(s => s.spans.map(span => ({ ...span, resource: r.resource })))));
    const app = await start(true, { OTEL_SDK_DISABLED: 'false',
      NODE_OPTIONS: '--experimental-loader=@opentelemetry/instrumentation/hook.mjs --import=@opentelemetry/auto-instrumentations-node/register',
      OTEL_SERVICE_NAME: 'conduit-pool-test', OTEL_NODE_RESOURCE_DETECTORS: 'env,host,os,process',
      OTEL_RESOURCE_ATTRIBUTES: 'benchmark.run_id=verify-otel-on',
      OTEL_TRACES_EXPORTER: 'otlp', OTEL_METRICS_EXPORTER: 'none', OTEL_LOGS_EXPORTER: 'none',
      OTEL_EXPORTER_OTLP_PROTOCOL: 'http/json', OTEL_EXPORTER_OTLP_ENDPOINT: `http://127.0.0.1:${receiver.address().port}`,
      OTEL_TRACES_SAMPLER: 'always_on', OTEL_NODE_ENABLED_INSTRUMENTATIONS: 'http,pg', OTEL_BSP_SCHEDULE_DELAY: '200' });
    for (let n = 0; n < 36; n++) assert.equal((await request(app, paths[n % paths.length])).error, false);
    const exportedPids = () => new Set(spans().flatMap(s => s.resource.attributes.filter(a => a.key === 'process.pid')
      .map(a => Number(a.value.intValue ?? a.value.doubleValue))));
    for (let n = 0; n < 100 && exportedPids().size < 6; n++) {
      await request(app, '/api/tags'); await delay(100);
    }
    const all = spans();
    const connect = all.filter(s => s.name === 'pg-pool.connect');
    const queries = all.filter(s => s.name.startsWith('pg.query'));
    assert(connect.length > 0, `Missing pg-pool.connect: ${all.map(s => s.name).join(',')}`);
    assert(queries.length > 0, 'Missing pg.query');
    const byId = new Map(all.map(s => [s.spanId, s]));
    const hasHttpAncestor = span => {
      let parent = byId.get(span.parentSpanId);
      while (parent) { if (parent.name.includes('GET') && parent.traceId === span.traceId) return true; parent = byId.get(parent.parentSpanId); }
      return false;
    };
    assert(connect.some(hasHttpAncestor)); assert(queries.some(hasHttpAncestor));
    const diag = await stop(app, true);
    const tracePids = exportedPids();
    for (const record of diag.filter(r => r.final)) assert(tracePids.has(record.pid), `OTel PID ${record.pid} not in ${[...tracePids]}`);
    console.log(JSON.stringify({ test: 'otel', spans: all.length, pool_spans: connect.length, query_spans: queries.length,
      workers_with_pid_correlation: 6, sample: diag.find(r => r.final && r.successes > 0) }));
  } else {
    const pairs = Number(process.env.OVERHEAD_PAIRS ?? 3);
    assert(Number.isInteger(pairs) && pairs >= 1 && pairs <= 3);
    for (let pair = 0; pair < pairs; pair++) for (const enabled of pair % 2 ? [true, false] : [false, true]) {
      const app = await start(enabled);
      await workload(app, 30);
      const result = await workload(app, 60);
      await stop(app, enabled);
      console.log(JSON.stringify({ test: 'overhead', pair: pair + 1, diagnostics: enabled, ...result }));
    }
  }
} finally {
  for (const child of children) { child.kill('SIGTERM'); await child.done; }
  if (receiver) await new Promise(resolve => receiver.close(resolve));
  rmSync(logRoot, { recursive: true, force: true });
}
