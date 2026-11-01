import type { ServerResponse } from 'node:http';
import { monitorEventLoopDelay, performance } from 'node:perf_hooks';
import cluster from 'node:cluster';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { DiagnosticOutput } from './pool-diagnostics.js';

const bounds = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000, 10000];
const histogram = () => ({ count: 0, sum: 0, max: 0, buckets: Array<number>(bounds.length + 1).fill(0) });
function record(h: ReturnType<typeof histogram>, n: number): void {
  h.count++; h.sum += n; h.max = Math.max(h.max, n);
  const i = bounds.findIndex(b => n <= b), bucket = i < 0 ? bounds.length : i;
  h.buckets[bucket] = (h.buckets[bucket] ?? 0) + 1;
}
const sizes = () => Array.from({ length: 3 }, () => ({ count: 0, bytes: 0, handler_ms: histogram(), flush_ms: histogram() }));
const metrics = () => ({ started: 0, finished: 0, premature_close: 0, errors: 0,
  handler_ms: histogram(), flush_ms: histogram(), serialization_ms: histogram(),
  sizes: sizes(), phases: Object.fromEntries(['auth', 'lookup', 'query', 'mapping', 'serialization'].map(k => [k, histogram()])) });
type State = { begin: number; end?: number; label: string; sampled: boolean; phaseStart: number; bytes: number; size: number };

export async function createHttpDiagnostics() {
  const dir = process.env.BENCH_DIAGNOSTICS_DIR;
  if (dir) await mkdir(dir, { recursive: true, mode: 0o700 });
  const output = new DiagnosticOutput(process.stdout, dir ? join(dir, `http-worker-${cluster.worker?.id ?? 0}-${process.pid}.jsonl`) : undefined,
    Number(process.env.BENCH_DIAGNOSTICS_MAX_BYTES ?? 10485760));
  const states = new WeakMap<ServerResponse, State>();
  const routes = new Map<string, ReturnType<typeof metrics>>();
  const active = new Map<string, number>();
  const get = (label: string) => { let m = routes.get(label); if (!m) { m = metrics(); routes.set(label, m); } return m; };
  const loop = monitorEventLoopDelay({ resolution: 20 }); loop.enable();
  let elu = performance.eventLoopUtilization(), cpu = process.cpuUsage(), begin = performance.now(), utc = new Date().toISOString();
  let sequence = 0;
  const identity = { pid: process.pid, worker_id: cluster.worker?.id ?? null,
    run_id: /^[\w-]+$/.test(process.env.BENCH_RUN_ID ?? '') ? process.env.BENCH_RUN_ID : null };
  const emit = (final: boolean) => {
    const now = performance.now(), end = new Date().toISOString(), nextElu = performance.eventLoopUtilization(), nextCpu = process.cpuUsage();
    const common = { event: 'http_diagnostics', ...identity, sequence: ++sequence, interval_start: utc, interval_end: end, duration_ms: now - begin, final };
    output.write(JSON.stringify({ ...common, kind: 'worker', elu: performance.eventLoopUtilization(nextElu, elu),
      cpu_user_ms: (nextCpu.user - cpu.user) / 1000, cpu_system_ms: (nextCpu.system - cpu.system) / 1000,
      loop_delay_ms: loop.count ? { p50: loop.percentile(50) / 1e6, p95: loop.percentile(95) / 1e6, p99: loop.percentile(99) / 1e6, max: loop.max / 1e6 } : null,
      output: output.snapshot() }) + '\n', final);
    for (const [label, count] of active) if (count > 0) get(label);
    for (const [label, m] of routes) output.write(JSON.stringify({ ...common, kind: 'endpoint', label,
      in_flight: active.get(label) ?? 0, duration_bounds_ms: [...bounds, '+Inf'], size_bounds_bytes: [4096, 65536, '+Inf'],
      sample_ratio: 0.05, ...m }) + '\n', final);
    routes.clear(); loop.reset(); elu = nextElu; cpu = nextCpu; begin = now; utc = end;
  };
  const timer = setInterval(() => emit(false), 10000).unref();
  let finishing: Promise<void> | undefined;
  return {
    begin(response: ServerResponse): void {
      const now = performance.now();
      const state: State = { begin: now, phaseStart: now, label: 'unmatched', sampled: Math.random() < 0.05, bytes: 0, size: 0 };
      states.set(response, state);
      active.set('unmatched', (active.get('unmatched') ?? 0) + 1); get('unmatched').started++;
      let done = false;
      const complete = (finished: boolean) => {
        if (done) return; done = true;
        response.off('finish', onFinish); response.off('close', onClose);
        const m = get(state.label);
        active.set(state.label, (active.get(state.label) ?? 1) - 1);
        if (finished) { m.finished++; if (response.statusCode >= 400) m.errors++;
          if (state.end !== undefined) { const elapsed = performance.now() - state.end; record(m.flush_ms, elapsed); record(m.sizes[state.size]!.flush_ms, elapsed); }
        } else m.premature_close++;
        // Retain weak state until handler completion for closes during SQL.
      };
      const onFinish = () => complete(true), onClose = () => complete(false);
      response.once('finish', onFinish); response.once('close', onClose);
    },
    route(response: ServerResponse, label: string): void {
      const s = states.get(response); if (!s) return;
      // Labels come only from the fixed router, never URLs or user input.
      if (!active.has(label) && active.size >= 32) label = 'other';
      get(s.label).started--; active.set(s.label, (active.get(s.label) ?? 1) - 1);
      s.label = label; get(label).started++; active.set(label, (active.get(label) ?? 0) + 1);
    },
    phase(response: ServerResponse, name: 'auth' | 'lookup' | 'query' | 'mapping'): void {
      const s = states.get(response); if (!s?.sampled) return;
      const now = performance.now(); record(get(s.label).phases[name]!, now - s.phaseStart); s.phaseStart = now;
    },
    serializationStart(response: ServerResponse): number | undefined {
      return states.get(response)?.sampled ? performance.now() : undefined;
    },
    end(response: ServerResponse, bytes: number, serializationStart?: number): void {
      const s = states.get(response); if (!s || s.end !== undefined) return;
      const now = performance.now(), m = get(s.label); s.end = now; s.bytes = bytes; s.size = bytes <= 4096 ? 0 : bytes <= 65536 ? 1 : 2;
      record(m.handler_ms, now - s.begin); const size = m.sizes[s.size]!; size.count++; size.bytes += bytes; record(size.handler_ms, now - s.begin);
      if (serializationStart !== undefined) { record(m.serialization_ms, now - serializationStart); record(m.phases['serialization']!, now - serializationStart); }
    },
    finish(): Promise<void> { return finishing ??= (async () => { clearInterval(timer); loop.disable(); emit(true); await output.finish(); })(); },
  };
}
