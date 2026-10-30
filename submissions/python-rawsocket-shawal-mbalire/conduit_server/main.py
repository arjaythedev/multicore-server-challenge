import gc
import os
import resource
import signal
import sys
from psycopg_pool import ConnectionPool

from conduit_server.adapters.inbound.socket_server import RawSocketHttpServer, make_listener
from conduit_server.adapters.inbound.router import router
import conduit_server.adapters.inbound.controllers as controllers

from conduit_server.adapters.outbound.pg_repository import (
    PgPipeline,
    PostgresUserRepository,
    SingleConnection,
    configure_connection,
)
from conduit_server.adapters.outbound.crypto_adapter import JoseBcryptCryptoAdapter

# Total Postgres connections across every worker in threaded mode (max_connections = 100; the spec asks for <= 95).
DB_BUDGET = int(os.getenv("DB_BUDGET", 64))
MAX_CONNECTIONS = 95


def connections_per_worker(threads: int, pool_size: int, pipeline: bool, pg_readers: int) -> int:
    """Postgres connections one worker can open. Inline with the pipeline: PG_READERS read pipelines + 1 write
    pipeline + 1 for the bcrypt helper thread (the loop's own SingleConnection is never opened). Inline without it:
    the loop's connection + the helper's. Threaded: its pool."""
    if threads:
        return pool_size
    return (pg_readers + 1 if pipeline else 1) + 1


def serve(listener, database_url: str, jwt_secret: str, pool_size: int, threads: int, pg_readers: int):
    """One worker: its own connections (they can't cross a fork) and thread pool, the shared listener.
    threads=0: handlers run inline on the loop thread; bcrypt routes (router.offload) run on one helper thread with
    its own connection; queries that handlers `yield` run on PG_READERS read pipelines and one write pipeline
    (pg_readers=0, i.e. PIPELINE=0: on the loop's own connection, blocking). See connections_per_worker."""
    if threads == 0:
        db_pool = SingleConnection(database_url)
    else:
        db_pool = ConnectionPool(
            conninfo=database_url,
            min_size=pool_size,
            max_size=pool_size,
            configure=configure_connection,
            open=True,
        )
    article_repository = PostgresUserRepository(db_pool)
    crypto_adapter = JoseBcryptCryptoAdapter(secret_key=jwt_secret)

    # Composition root: wire ports into controllers, then start the raw socket server.
    controllers.bootstrap(article_repository, crypto_adapter)

    if threads == 0 and pg_readers:
        pipeline = tuple(PgPipeline(database_url) for _ in range(pg_readers + 1))
    else:
        pipeline = None
    server = RawSocketHttpServer(
        host="", port=0, router=router, threads=threads, listener=listener,
        offload=frozenset(router.offload), pipeline=pipeline,
    )
    server.start()


def main():
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < hard:
            resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, 200000), hard))
    except OSError:
        pass
    database_url = os.getenv("DATABASE_URL")
    port = int(os.getenv("PORT", 3000))
    host = os.getenv("HOST", "0.0.0.0")
    jwt_secret = os.getenv("JWT_SECRET")
    # 6: with the Postgres pipeline a worker no longer idles while its queries run, so it needs no spare workers to
    # cover the waits; fewer workers keep more queries in flight per connection, and they share round trips. At
    # 8,000 users: 16 workers 565k ns/req of app + Postgres CPU, 8: 532k, 6: 503k, 4: 441-455k (but p99 270-430 ms).
    workers = max(1, int(os.getenv("WORKERS", 6)))

    if not database_url or not jwt_secret:  # no default secret: tokens signed with a guessable key would be forgeable
        print("Error: DATABASE_URL and JWT_SECRET environment variables are required.", file=sys.stderr)
        sys.exit(1)

    print(f"Initializing Conduit server on {host}:{port} with {workers} worker(s)...", flush=True)

    # Shared by every worker: all imported code and compiled routes (copy-on-write after fork; gc.freeze keeps the
    # collector from dirtying those pages). Listening sockets are made here too, before the fork. Served directly,
    # each virtual user keeps one connection on whichever worker accepted it, so the split must be even:
    # REUSEPORT=1 (default) gives every worker its own SO_REUSEPORT listener and the kernel hashes connections across
    # them. REUSEPORT=0 shares one listener (EPOLLEXCLUSIVE wakes one worker); measured 347-700 connections per
    # worker at 8,000 users.
    reuseport = workers > 1 and os.getenv("REUSEPORT", "1") != "0"
    if reuseport:
        listeners = [make_listener(host, port, reuseport=True) for _ in range(workers)]
    else:
        listeners = [make_listener(host, port)] * workers
    # Default THREADS=0: each worker is one thread running handlers inline on its epoll loop, with one connection.
    # Measured ~25% more req/s per CPU than a thread pool per worker, whose GIL handoffs cost ~20 context switches
    # per request. THREADS=N brings back the pool: N threads sharing DB_BUDGET // WORKERS connections.
    threads = int(os.getenv("THREADS", 0))
    pool_size = 1 if threads == 0 else DB_BUDGET // workers
    pg_readers = max(1, int(os.getenv("PG_READERS", 2))) if threads == 0 and os.getenv("PIPELINE", "1") != "0" else 0
    total = workers * connections_per_worker(threads, pool_size, bool(pg_readers), pg_readers)
    if total > MAX_CONNECTIONS:
        print(f"Error: {workers} workers would open up to {total} Postgres connections (limit {MAX_CONNECTIONS});"
              " lower WORKERS, PG_READERS or DB_BUDGET.", file=sys.stderr)
        sys.exit(1)

    if workers == 1:
        try:
            serve(listeners[0], database_url, jwt_secret, pool_size, threads, pg_readers)
        except KeyboardInterrupt:
            sys.exit(0)
        return

    gc.freeze()
    children = []
    for i in range(workers):
        pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            signal.signal(signal.SIGINT, signal.SIG_DFL)
            if reuseport:
                for j, other in enumerate(listeners):
                    if j != i:
                        other.close()  # only this worker's listener stays open in it
            try:
                serve(listeners[i], database_url, jwt_secret, pool_size, threads, pg_readers)
            except BaseException:
                import traceback
                traceback.print_exc()
            finally:
                os._exit(1)
        children.append(pid)

    def stop(*_):
        for child in children:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # No restarts (rule 9): if any worker dies, take the whole server down.
    pid, status = os.wait()
    print(f"worker {pid} exited with status {status}; stopping", file=sys.stderr, flush=True)
    stop()


if __name__ == "__main__":
    main()
