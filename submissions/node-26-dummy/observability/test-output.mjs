import assert from 'node:assert/strict';
import { Writable } from 'node:stream';
import { mkdtemp, readFile, readdir, stat, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { DiagnosticOutput } from '../dist/pool-diagnostics.js';
import { spawn } from 'node:child_process';

const dir = await mkdtemp(join(tmpdir(), 'node26-output-'));
const record = n => JSON.stringify({ event: 'pool_diagnostics', sequence: n, padding: 'x'.repeat(700) }) + '\n';
try {
  // Serial callback/drain handling preserves line order, including final flush.
  let received = '';
  const slow = new Writable({ highWaterMark: 1, write(chunk, encoding, callback) {
    setTimeout(() => { received += chunk.toString(); callback(); }, 2);
  } });
  const path = join(dir, 'worker.jsonl');
  const out = new DiagnosticOutput(slow, path, 4096);
  for (let n = 0; n < 20; n++) { out.write(record(n), n === 19); await delay(3); }
  await out.finish(); await out.finish();
  assert.deepEqual(received.trim().split('\n').map(line => JSON.parse(line).sequence), Array.from({ length: 20 }, (_, n) => n));
  const files = (await readdir(dir)).sort();
  assert.deepEqual(files, ['worker.jsonl', 'worker.jsonl.1']);
  const saved = [];
  for (const file of ['worker.jsonl.1', 'worker.jsonl']) {
    const info = await stat(join(dir, file));
    assert(info.size <= 4096); assert.equal(info.mode & 0o777, 0o600);
    saved.push(...(await readFile(join(dir, file), 'utf8')).trim().split('\n').map(JSON.parse));
  }
  assert.equal(saved.at(-1).sequence, 19);
  assert(saved.length < 20, 'old rotations are bounded');
  assert.equal(out.snapshot().stdout.dropped, 0);

  // A permanently blocked stdout cannot grow memory or block final file flush.
  let unblock;
  const blocked = new Writable({ highWaterMark: 1, write(chunk, encoding, callback) { unblock = callback; } });
  const blockedPath = join(dir, 'blocked.jsonl');
  const bounded = new DiagnosticOutput(blocked, blockedPath, 4096);
  for (let n = 0; n < 150; n++) { bounded.write(record(n)); await delay(1); }
  const before = bounded.snapshot();
  assert(before.stdout.pending_bytes <= 65536); assert(before.stdout.dropped > 0);
  bounded.write(JSON.stringify({ event: 'pool_diagnostics', final: true, output: before }) + '\n', true);
  const begin = performance.now();
  await bounded.finish(100);
  assert(performance.now() - begin < 1000);
  assert.equal(JSON.parse((await readFile(blockedPath, 'utf8')).trim().split('\n').at(-1)).final, true);
  assert(bounded.snapshot().stdout.pending_bytes < 4096, 'only one in-flight record remains');
  unblock(); await delay(10);

  // EPIPE and disk errors are counted; no unhandled errors/rejections.
  const broken = new Writable({ write(chunk, encoding, callback) { callback(Object.assign(new Error('closed'), { code: 'EPIPE' })); } });
  const brokenOut = new DiagnosticOutput(broken, join(dir, 'epipe.jsonl'), 4096);
  brokenOut.write(record(1), true); await brokenOut.finish();
  assert.equal(brokenOut.snapshot().stdout.errors, 1);
  assert.equal(JSON.parse((await readFile(join(dir, 'epipe.jsonl'), 'utf8')).trim()).sequence, 1);
  const nullStream = new Writable({ write(chunk, encoding, callback) { callback(); } });
  const badFile = new DiagnosticOutput(nullStream, join(dir, 'missing', 'file.jsonl'), 4096);
  badFile.write(record(1), true); await badFile.finish();
  assert.equal(badFile.snapshot().file.errors, 1);
  assert.throws(() => new DiagnosticOutput(nullStream, undefined, 0));
  // Real OS pipe with a reader that never consumes stdout. Mirror the server's
  // await-finish-then-exit lifecycle and ensure the disk final survives.
  const pipeFile = join(dir, 'pipe.jsonl');
  const code = `import {DiagnosticOutput} from ${JSON.stringify(new URL('../dist/pool-diagnostics.js', import.meta.url).href)};
    process.stdout.write('x'.repeat(1024 * 1024));
    const out = new DiagnosticOutput(process.stdout, ${JSON.stringify(pipeFile)}, 4096);
    out.write(JSON.stringify({event:'pool_diagnostics',final:true})+'\\n', true);
    await out.finish(200); process.exit(0);`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', code], { stdio: ['ignore', 'pipe', 'pipe'] });
  let warning = ''; child.stderr.on('data', data => { warning += data; });
  const watchdog = setTimeout(() => child.kill('SIGKILL'), 5000);
  const exit = await new Promise(resolve => child.on('exit', resolve));
  clearTimeout(watchdog); child.stdout.destroy();
  assert.equal(exit, 0); assert(warning.includes('flush deadline exceeded'));
  assert.equal(JSON.parse((await readFile(pipeFile, 'utf8')).trim()).final, true);
  console.log('PASS output: rotation/permissions; callback+drain ordering; bounded queues; blocked stdout final file; EPIPE; disk errors; shutdown deadline');
} finally { await rm(dir, { recursive: true, force: true }); }
