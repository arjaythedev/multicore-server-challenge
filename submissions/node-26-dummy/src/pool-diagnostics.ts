import type { Pool, PoolClient } from 'pg';
import cluster from 'node:cluster';
import { hostname } from 'node:os';
import { performance } from 'node:perf_hooks';
import { mkdir, open, rename, type FileHandle } from 'node:fs/promises';
import { join } from 'node:path';
import type { Writable } from 'node:stream';

// Output queues include the in-flight record and never exceed this bound.
const pendingLimit = 64 * 1024;
class BoundedSink {
  private queue: string[] = [];
  private running = false;
  private stopped = false;
  private waiters: (() => void)[] = [];
  readonly stats = { pending_bytes: 0, dropped: 0, errors: 0 };
  constructor(private readonly write: (line: string) => Promise<void>) {}
  enqueue(line: string, final: boolean): void {
    const bytes = Buffer.byteLength(line);
    if (final) while (this.queue.length && this.stats.pending_bytes + bytes > pendingLimit) {
      this.stats.pending_bytes -= Buffer.byteLength(this.queue.shift()!); this.stats.dropped++;
    }
    if (this.stopped || this.stats.pending_bytes + bytes > pendingLimit) { this.stats.dropped++; return; }
    this.stats.pending_bytes += bytes; this.queue.push(line);
    if (!this.running) void this.pump();
  }
  private async pump(): Promise<void> {
    this.running = true;
    while (this.queue.length) {
      const line = this.queue.shift()!;
      try { await this.write(line); }
      catch { this.stats.errors++; this.stop(); }
      this.stats.pending_bytes -= Buffer.byteLength(line);
    }
    this.running = false;
    for (const resolve of this.waiters.splice(0)) resolve();
  }
  idle(): Promise<void> {
    return this.running ? new Promise(resolve => this.waiters.push(resolve)) : Promise.resolve();
  }
  stop(): void {
    this.stopped = true;
    for (const line of this.queue.splice(0)) { this.stats.pending_bytes -= Buffer.byteLength(line); this.stats.dropped++; }
  }
}

// Exported for focused stream/rotation tests. Application construction happens
// only inside instrumentPool, after BENCH_DIAGNOSTICS=1 is checked in utils.
export class DiagnosticOutput {
  private readonly stdoutSink: BoundedSink;
  private readonly fileSink: BoundedSink | undefined;
  private file: FileHandle | undefined;
  private size = 0;
  private rejectStdout: ((error: Error) => void) | undefined;
  private readonly stdoutError = (error: Error): void => { this.rejectStdout?.(error); };
  private finishing: Promise<void> | undefined;
  constructor(private readonly stdout: Writable, private readonly path?: string,
    private readonly maxBytes = 10 * 1024 * 1024) {
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 4096 || maxBytes > 64 * 1024 * 1024) {
      throw new Error('BENCH_DIAGNOSTICS_MAX_BYTES must be an integer between 4096 and 67108864');
    }
    this.stdout.on('error', this.stdoutError);
    this.stdoutSink = new BoundedSink(line => this.writeStdout(line));
    this.fileSink = path ? new BoundedSink(line => this.writeFile(line)) : undefined;
  }
  snapshot(): object {
    return { stdout: { ...this.stdoutSink.stats }, file: this.fileSink ? { ...this.fileSink.stats } : null };
  }
  write(line: string, final = false): void {
    this.stdoutSink.enqueue(line, final); this.fileSink?.enqueue(line, final);
  }
  private writeStdout(line: string): Promise<void> {
    return new Promise((resolve, reject) => {
      let returned = false, callbackDone = false, needsDrain = false, drained = false;
      const cleanup = (): void => { this.stdout.off('drain', onDrain); this.rejectStdout = undefined; };
      const fail = (error: Error): void => { cleanup(); reject(error); };
      const complete = (): void => {
        if (returned && callbackDone && (!needsDrain || drained)) { cleanup(); resolve(); }
      };
      const onDrain = (): void => { drained = true; complete(); };
      this.rejectStdout = fail;
      this.stdout.on('drain', onDrain);
      try {
        needsDrain = !this.stdout.write(line, (error?: Error | null) => {
          if (error) fail(error); else { callbackDone = true; complete(); }
        });
        returned = true; complete();
      } catch (error) { fail(error instanceof Error ? error : new Error('stdout write failed')); }
    });
  }
  private async writeFile(line: string): Promise<void> {
    const path = this.path!;
    const bytes = Buffer.byteLength(line);
    if (bytes > this.maxBytes) throw new Error('Diagnostic record exceeds file limit');
    if (!this.file) { this.file = await open(path, 'a', 0o600); this.size = (await this.file.stat()).size; }
    if (this.size + bytes > this.maxBytes) {
      await this.file.close(); this.file = undefined;
      await rename(path, `${path}.1`);
      this.file = await open(path, 'w', 0o600); this.size = 0;
    }
    await this.file.writeFile(line); this.size += bytes;
  }
  finish(timeoutMs = 1500): Promise<void> {
    return this.finishing ??= (async () => {
      let timer: NodeJS.Timeout | undefined;
      const fileDrained = (async () => {
        await this.fileSink?.idle();
        if (this.file) { await this.file.close(); this.file = undefined; }
      })();
      const drained = Promise.all([this.stdoutSink.idle(), fileDrained]).then(() => {
        this.stdout.off('error', this.stdoutError);
        return true;
      });
      const complete = await Promise.race([drained, new Promise<false>(resolve => {
        timer = setTimeout(() => resolve(false), timeoutMs);
      })]);
      clearTimeout(timer);
      if (!complete) {
        this.stdoutSink.stop(); this.fileSink?.stop();
        process.stderr.write('pool_diagnostics: output flush deadline exceeded; queued records dropped\n');
      }
      if (this.fileSink?.stats.errors) process.stderr.write('pool_diagnostics: file output failed\n');
    })();
  }
}

export async function instrumentPool(target: Pool): Promise<() => Promise<void>> {
  const dir = process.env.BENCH_DIAGNOSTICS_DIR;
  if (dir) await mkdir(dir, { recursive: true, mode: 0o700 });
  const file = dir ? join(dir, `worker-${cluster.worker?.id ?? 0}-${process.pid}.jsonl`) : undefined;
  const output = new DiagnosticOutput(process.stdout, file, Number(process.env.BENCH_DIAGNOSTICS_MAX_BYTES ?? 10485760));
  const bounds = [0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 250, 500, 1000, 2500, 5000, 10000];
  const histogram = () => ({ count: 0, sum_ms: 0, max_ms: 0, buckets: Array<number>(bounds.length + 1).fill(0) });
  type Histogram = ReturnType<typeof histogram>;
  const record = (h: Histogram, ms: number): void => {
    h.count++; h.sum_ms += ms; h.max_ms = Math.max(h.max_ms, ms);
    const found = bounds.findIndex(bound => ms <= bound);
    const index = found < 0 ? bounds.length : found;
    h.buckets[index] = (h.buckets[index] ?? 0) + 1;
  };
  const gauges = () => ({ total: target.totalCount, idle: target.idleCount, waiting: target.waitingCount });
  const interval = () => ({ acquisitions: { all: histogram(), new: histogram(), reused: histogram(),
    unknown: histogram(), failed: histogram() }, connections: { created: 0, removed: 0,
    unknown_removed: 0, removed_lifetime: histogram() }, observed_max: gauges() });
  let data = interval();
  let started = performance.now();
  let startUtc = new Date().toISOString();
  let sequence = 0;
  const clients = new WeakMap<PoolClient, { born: number; acquired: boolean }>();
  let live = 0;
  let removalComplete: (() => void) | undefined;
  const sample = (): void => {
    const current = gauges();
    data.observed_max.total = Math.max(data.observed_max.total, current.total);
    data.observed_max.idle = Math.max(data.observed_max.idle, current.idle);
    data.observed_max.waiting = Math.max(data.observed_max.waiting, current.waiting);
  };
  const onConnect = (client: PoolClient): void => {
    clients.set(client, { born: performance.now(), acquired: false });
    live++;
    data.connections.created++; sample();
  };
  const onRemove = (client: PoolClient): void => {
    data.connections.removed++;
    const state = clients.get(client);
    if (state) { record(data.connections.removed_lifetime, performance.now() - state.born); live--; }
    else data.connections.unknown_removed++;
    clients.delete(client); sample();
    if (live === 0) removalComplete?.();
  };
  target.on('connect', onConnect);
  target.on('remove', onRemove);
  target.on('acquire', sample);
  target.on('release', sample);
  const original = target.connect;
  type Callback = Parameters<Pool['connect']>[0];
  function connect(this: Pool): Promise<PoolClient>;
  function connect(this: Pool, callback: Callback): void;
  function connect(this: Pool, callback?: Callback): Promise<PoolClient> | void {
    const begin = performance.now();
    let completed = false;
    const done = (error: unknown, client?: PoolClient): void => {
      if (completed) return;
      completed = true;
      const elapsed = performance.now() - begin;
      record(data.acquisitions.all, elapsed);
      if (error) record(data.acquisitions.failed, elapsed);
      else {
        const state = client ? clients.get(client) : undefined;
        record(state ? (state.acquired ? data.acquisitions.reused : data.acquisitions.new) : data.acquisitions.unknown, elapsed);
        if (state) state.acquired = true;
      }
      sample();
    };
    // Invoke the existing method (including any OTel wrapper) with its receiver.
    const invoke = original.bind(this);
    try {
      if (callback) {
        invoke(function (this: unknown, error, client, release) {
          done(error, client);
          callback.call(this, error, client, release);
        });
        sample();
        return;
      }
      const result = invoke();
      sample();
      return result.then(client => { done(null, client); return client; },
        (error: unknown) => { done(error); throw error; });
    } catch (error) { done(error); throw error; }
  }
  target.connect = connect;
  const runId = process.env.BENCH_RUN_ID;
  const identity = { pid: process.pid, worker_id: cluster.worker?.id ?? null, hostname: hostname(),
    run_id: runId && /^[a-zA-Z0-9_-]+$/.test(runId) ? runId : null };
  const emit = (final: boolean): void => {
    sample();
    const end = performance.now();
    const endUtc = new Date().toISOString();
    const payload = { event: 'pool_diagnostics', ...identity, sequence: ++sequence,
      interval_start: startUtc, interval_end: endUtc, duration_ms: end - started, final,
      current: gauges(), histogram_upper_bounds_ms: [...bounds, '+Inf'],
      histogram_cumulative: false, successes: data.acquisitions.all.count - data.acquisitions.failed.count,
      failures: data.acquisitions.failed.count, output: output.snapshot(), ...data };
    data = interval(); started = end; startUtc = endUtc;
    output.write(JSON.stringify(payload) + '\n', final);
  };
  const sampler = setInterval(sample, 1000).unref();
  const reporter = setInterval(() => emit(false), 10000).unref();
  let finishing: Promise<void> | undefined;
  return () => finishing ??= new Promise<void>((resolve, reject) => {
    clearInterval(sampler); clearInterval(reporter);
    removalComplete = () => {
      target.off('connect', onConnect); target.off('remove', onRemove);
      target.off('acquire', sample); target.off('release', sample);
      target.connect = original;
      // Bounded final flush of independent sinks before server.ts exits.
      emit(true);
      void output.finish().then(resolve, reject);
    };
    // pg-pool can resolve end() before client.end callbacks emit 'remove'.
    // Keep listeners until those physical connections have actually closed.
    if (live === 0) removalComplete();
  });
}
