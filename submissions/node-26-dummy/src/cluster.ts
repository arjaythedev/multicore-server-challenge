import cluster from 'node:cluster';
import { availableParallelism } from 'node:os';

if (cluster.isPrimary) {
  const workers = Number(process.env.WORKERS ?? Math.min(availableParallelism(), 90));
  if (!Number.isInteger(workers) || workers < 1 || workers > 90) throw new Error('WORKERS must be an integer from 1 to 90');
  const poolSize = Math.min(10, Math.floor(90 / workers));
  let stopping = false;
  let exitCode = 0;
  let deadline: NodeJS.Timeout | undefined;
  const active = new Set<number>();

  function shutdown(code: number): void {
    exitCode = Math.max(exitCode, code);
    if (stopping) return;
    stopping = true;
    deadline = setTimeout(() => {
      exitCode = 1;
      for (const worker of Object.values(cluster.workers ?? {})) worker?.process.kill('SIGKILL');
    }, 10_000);
    for (const worker of Object.values(cluster.workers ?? {})) worker?.process.kill('SIGTERM');
    if (active.size === 0) { clearTimeout(deadline); process.exit(exitCode); }
  }

  cluster.on('exit', (worker, code, signal) => {
    active.delete(worker.id);
    console.log(JSON.stringify({ event: 'worker_exit', pid: worker.process.pid, code, signal }));
    if (!stopping) shutdown(1);
    else if (code !== 0 || signal != null) exitCode = 1;
    if (stopping && active.size === 0) {
      clearTimeout(deadline);
      process.exit(exitCode);
    }
  });
  cluster.on('online', worker => console.log(JSON.stringify({ event: 'worker_online', pid: worker.process.pid })));
  process.once('SIGINT', () => shutdown(0));
  process.once('SIGTERM', () => shutdown(0));
  console.log(JSON.stringify({ event: 'cluster_started', pid: process.pid, workers,
    poolSize, maxConnections: workers * poolSize, connectionBudget: 90, reservedConnections: 10 }));
  for (let i = 0; i < workers; i++) {
    const worker = cluster.fork({ PG_POOL_SIZE: String(poolSize) });
    active.add(worker.id);
  }
} else {
  await import('./server.js');
}
