// Supplemental integration checks. Creates and drops only its own seed clone.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { Pool } from 'pg';
import { SignJWT } from 'jose';

if (!process.env.TEST_DATABASE_URL) throw new Error('TEST_DATABASE_URL must be an administrator URL to postgres; conduit_dev must exist');
const database = `node26_verify_${process.pid}`;
const adminUrl = new URL(process.env.TEST_DATABASE_URL);
const admin = new Pool({ connectionString: adminUrl.href });
const appUrl = new URL(adminUrl);
appUrl.pathname = `/${database}`;
appUrl.username = 'conduit';
appUrl.password = 'conduit';
const secret = 'integration-secret';
const key = new TextEncoder().encode(secret);
const children = new Set();
let db;
let utils;
let created = false;
const waitFor = async predicate => {
  for (let i = 0; i < 200; i++) {
    if (await predicate()) return;
    await delay(50);
  }
  throw new Error('Timed out waiting for condition');
};
const request = async (port, path, options = {}) => {
  const response = await fetch(`http://127.0.0.1:${port}${path}`, { ...options, signal: AbortSignal.timeout(15000) });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : null };
};
async function start(port) {
  const child = spawn(process.execPath, ['dist/cluster.js'], {
    cwd: import.meta.dirname,
    env: { ...process.env, DATABASE_URL: appUrl.href, JWT_SECRET: secret, WORKERS: '2', HOST: '127.0.0.1', PORT: String(port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  children.add(child);
  child.done = once(child, 'exit');
  child.output = '';
  child.stdout.on('data', chunk => { child.output += chunk; });
  child.stderr.on('data', chunk => { child.output += chunk; });
  await waitFor(async () => {
    if (child.exitCode !== null) throw new Error(child.output);
    try { return (await request(port, '/api/tags')).status === 200 && workerPids(child).length === 2; }
    catch { return false; }
  });
  return child;
}
const events = child => child.output.split('\n').flatMap(line => { try { return [JSON.parse(line)]; } catch { return []; } });
const workerPids = child => events(child).filter(e => e.event === 'worker_online').map(e => e.pid);
const stopped = async child => {
  const outcome = await Promise.race([child.done, delay(12000).then(() => { throw new Error('Shutdown timeout'); })]);
  children.delete(child);
  for (const pid of workerPids(child)) assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  return outcome;
};

try {
  await admin.query(`CREATE DATABASE ${database} TEMPLATE conduit_dev`);
  created = true;
  const dbUrl = new URL(adminUrl); dbUrl.pathname = `/${database}`;
  db = new Pool({ connectionString: dbUrl.href });
  process.env.DATABASE_URL = appUrl.href;
  process.env.JWT_SECRET = secret;
  process.env.PG_POOL_SIZE = '2';
  utils = await import('./dist/utils.js');
  assert.equal(utils.safeInteger('9007199254740991'), Number.MAX_SAFE_INTEGER);
  assert.throws(() => utils.safeInteger('9007199254740992'));
  assert.equal(utils.validId('9223372036854775807'), true);
  assert.equal(utils.validId('9223372036854775808'), false);
  assert.deepEqual(utils.pagination(new URL('http://local/?limit=01&offset=2147483647')), { limit: 1, offset: 2147483647 });
  assert.throws(() => utils.pagination(new URL('http://local/?offset=2147483648')));
  await utils.pool.end();
  await utils.finishPoolDiagnostics?.();

  const port = Number(process.env.TEST_PORT ?? 33112);
  let child = await start(port);
  const budget = events(child).find(e => e.event === 'cluster_started');
  assert.equal(budget.maxConnections, 20);
  assert.equal(budget.reservedConnections, 10);
  const token = await new SignJWT({ sub: '1' }).setProtectedHeader({ alg: 'HS256' }).setIssuedAt().setExpirationTime('1h').sign(key);
  const auth = { authorization: `Token ${token}`, 'content-type': 'application/json' };
  const slug = (await db.query('SELECT slug FROM articles ORDER BY id LIMIT 1')).rows[0].slug;

  // Failure after article and tag INSERTs must roll back both.
  await db.query('REVOKE INSERT ON article_tags FROM conduit');
  try {
    const result = await request(port, '/api/articles', { method: 'POST', headers: auth,
      body: JSON.stringify({ article: { title: 'rollback-probe', description: 'd', body: 'b', tagList: ['rollback-probe-tag'] } }) });
    assert.equal(result.status, 500);
    assert.equal((await db.query("SELECT count(*) FROM articles WHERE title='rollback-probe'")).rows[0].count, '0');
    assert.equal((await db.query("SELECT count(*) FROM tags WHERE name='rollback-probe-tag'")).rows[0].count, '0');
  } finally { await db.query('GRANT INSERT ON article_tags TO conduit'); }

  // Bigint subjects stay exact; unsafe numeric comment IDs must not round.
  const huge = '9007199254740993';
  await db.query(`INSERT INTO users(id,username,email,password_hash) SELECT $1,'big-id','big-id@example.com',password_hash FROM users WHERE id=1`, [huge]);
  const bigToken = await new SignJWT({ sub: huge }).setProtectedHeader({ alg: 'HS256' }).setIssuedAt().setExpirationTime('1h').sign(key);
  const bigUser = await request(port, '/api/user', { headers: { authorization: `Token ${bigToken}` } });
  assert.equal(bigUser.status, 200);
  assert.equal(bigUser.body.user.username, 'big-id');
  assert.equal(bigUser.body.user.token, bigToken);
  await db.query("SELECT setval(pg_get_serial_sequence('comments','id'),$1,false)", [huge]);
  const badComment = await request(port, `/api/articles/${slug}/comments`, { method: 'POST', headers: auth,
    body: JSON.stringify({ comment: { body: 'unsafe-id-probe' } }) });
  assert.equal(badComment.status, 500);
  assert.equal((await db.query("SELECT count(*) FROM comments WHERE body='unsafe-id-probe'")).rows[0].count, '0');

  // Saturate both pools while the tag table is locked; shutdown must drain requests.
  const locker = await db.connect();
  await locker.query('BEGIN');
  await locker.query('LOCK TABLE tags IN ACCESS EXCLUSIVE MODE');
  const pending = Promise.all(Array.from({ length: 120 }, () => request(port, '/api/tags')));
  try {
    await waitFor(async () => {
      const n = Number((await db.query("SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND application_name='node-26-conduit'", [database])).rows[0].count);
      assert.ok(n <= 20);
      return n === 20;
    });
    child.kill('SIGTERM');
    await delay(150);
    assert.equal(child.exitCode, null);
  } finally { await locker.query('ROLLBACK'); locker.release(); }
  const responses = await pending;
  assert.ok(responses.every(r => r.status === 200));
  assert.deepEqual(await stopped(child), [0, null], child.output);
  assert.equal((await db.query("SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND application_name='node-26-conduit'", [database])).rows[0].count, '0');
  console.log('PASS: rollback, bigint/JSON, pagination, 20-connection bound, in-flight draining and pool shutdown');

  for (const signal of ['SIGKILL', 'SIGTERM']) {
    child = await start(port);
    const pids = workerPids(child);
    process.kill(pids[0], signal);
    assert.deepEqual(await stopped(child), [1, null]);
    assert.equal(workerPids(child).length, 2, 'No replacement worker');
    if (signal === 'SIGTERM') assert.ok(events(child).some(e => e.event === 'worker_exit' && e.pid === pids[0] && e.code === 0));
  }
  console.log('PASS: unexpected worker exit (SIGKILL and exit 0) terminates all workers without restart');
  child = await start(port);
  process.kill(workerPids(child)[0], 'SIGSTOP');
  child.kill('SIGTERM');
  assert.deepEqual(await stopped(child), [1, null]);
  console.log('PASS: unresponsive worker is forcibly terminated after the shutdown deadline');
} finally {
  for (const child of children) {
    child.kill('SIGTERM');
    await child.done;
  }
  if (utils && !utils.pool.ended) await utils.pool.end();
  if (db) await db.end();
  if (created) await admin.query(`DROP DATABASE ${database} WITH (FORCE)`);
  await admin.end();
}
