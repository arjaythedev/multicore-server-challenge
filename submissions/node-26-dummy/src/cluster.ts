import cluster, { type Worker } from "node:cluster";
import { availableParallelism } from "node:os";

const workerCount = Number(process.env.WORKERS ?? availableParallelism());

if (!Number.isSafeInteger(workerCount) || workerCount < 1) {
  throw new Error("WORKERS must be a positive integer");
}

if (cluster.isPrimary) {
  let shuttingDown = false;
  let restartTimes: number[] = [];

  console.log(JSON.stringify({
    event: "cluster_started",
    pid: process.pid,
    workers: workerCount,
  }));

  const spawnWorker = (): Worker => cluster.fork();

  cluster.on("online", (worker) => {
    console.log(JSON.stringify({
      event: "worker_online",
      pid: worker.process.pid,
    }));
  });

  cluster.on("listening", (worker, address) => {
    console.log(JSON.stringify({
      event: "worker_listening",
      pid: worker.process.pid,
      port: address.port,
    }));
  });

  cluster.on("exit", (worker, code, signal) => {
    console.error(JSON.stringify({
      event: "worker_exited",
      pid: worker.process.pid,
      code,
      signal,
    }));

    if (shuttingDown || worker.exitedAfterDisconnect) {
      return;
    }

    const now = Date.now();
    restartTimes = restartTimes.filter((time) => now - time < 30_000);
    restartTimes.push(now);

    if (restartTimes.length > 5) {
      console.error("Too many worker crashes");
      shutdown("crash_limit", 1);
      return;
    }

    setTimeout(() => {
      if (!shuttingDown) {
        spawnWorker();
      }
    }, 1_000);
  });

  function shutdown(reason: string, exitCode = 0): void {
    if (shuttingDown) {
      return;
    }

    shuttingDown = true;
    console.log(JSON.stringify({ event: "cluster_shutdown", reason }));

    const timeout = setTimeout(() => {
      console.error("Graceful shutdown timed out");
      process.exit(1);
    }, 10_000);

    cluster.disconnect(() => {
      clearTimeout(timeout);
      process.exit(exitCode);
    });
  }

  process.once("SIGINT", () => shutdown("SIGINT"));
  process.once("SIGTERM", () => shutdown("SIGTERM"));

  for (let index = 0; index < workerCount; index += 1) {
    spawnWorker();
  }
} else {
  await import("./server.js");
}
