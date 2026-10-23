import asyncio
import contextlib
import gc
import os
import signal
import sys
import time

import uvloop

from . import app, httpd

# Postgres has 100 connections and the rules let us use 95, so stay well under.
MAX_TOTAL_CONNECTIONS = 90


def settings() -> dict:
    # Everything is sized from the number of CPUs this process may run on (affinity and cpusets count), so 2, 8 or
    # 32 vCPUs all end up with the same ratios.
    cpus = os.process_cpu_count() or os.cpu_count() or 1
    # 4 connections per CPU. Postgres needed 7-10% less CPU per request with that than with 10-12, because fewer
    # backends are runnable at the same time.
    total = min(int(os.environ.get("DB_CONNECTIONS") or 4 * cpus), MAX_TOTAL_CONNECTIONS)
    # A request takes about 0.2 ms of event loop and 0.35 ms of Postgres, so the workers need well under half the
    # box. On the 4 vCPU test VM 2 to 4 workers were equally fast and 6 to 8 a bit slower. So: 3/4 of the CPUs, at
    # least 2 (one stuck worker shouldn't stall the server), and few enough that each gets 2 connections.
    workers = int(os.environ.get("WORKERS") or max(2, cpus * 3 // 4))
    workers = max(1, min(workers, total // 2))
    return {
        "cpus": cpus,
        "dsn": os.environ["DATABASE_URL"],
        "host": os.environ.get("HOST", "127.0.0.1"),
        "port": int(os.environ.get("PORT", "3000")),
        "workers": workers,
        "pool_size": total // workers,
        "hash_threads": int(os.environ.get("HASH_THREADS") or 2),
    }


def worker(cfg: dict) -> None:
    async def main() -> None:
        loop = asyncio.get_running_loop()
        stop = loop.create_future()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, lambda: stop.done() or stop.set_result(None))
        await app.start(cfg["dsn"], cfg["pool_size"], cfg["hash_threads"])
        server = httpd.Server(app.handle, loop)
        await server.start(cfg["host"], cfg["port"])
        # What exists now lives as long as the process, so keep it away from the garbage collector.
        gc.collect()
        gc.freeze()
        gc.set_threshold(50_000, 20, 20)
        await stop
        await server.close()
        await app.stop()

    uvloop.run(main())


def supervise(cfg: dict) -> None:
    children: dict[int, int] = {}  # pid -> worker number
    started: dict[int, float] = {}
    stopping = False

    def spawn(i: int) -> None:
        pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            code = 0
            try:
                worker(cfg)
            except BaseException as e:
                print(f"worker {i} failed: {e!r}", file=sys.stderr, flush=True)
                code = 1
            os._exit(code)
        children[pid] = i
        started[i] = time.monotonic()

    def stop(signum, frame) -> None:
        nonlocal stopping
        stopping = True
        for pid in tuple(children):
            with contextlib.suppress(ProcessLookupError):
                os.kill(pid, signal.SIGTERM)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"conduit: {cfg['cpus']} CPUs, {cfg['workers']} workers with {cfg['pool_size']} connections each, "
          f"listening on {cfg['host']}:{cfg['port']}", file=sys.stderr, flush=True)
    for i in range(cfg["workers"]):
        spawn(i)
    while children:
        try:
            pid, status = os.wait()
        except ChildProcessError:
            break
        i = children.pop(pid, None)
        if i is None or stopping:
            continue
        print(f"worker {i} (pid {pid}) exited with status {status}, restarting", file=sys.stderr, flush=True)
        if time.monotonic() - started[i] < 2:  # dying right after start: don't spin
            time.sleep(1)
        if not stopping:
            spawn(i)


if __name__ == "__main__":
    supervise(settings())
