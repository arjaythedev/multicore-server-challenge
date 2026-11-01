"""DB_DRIVER=asyncpg: the same statements (pg_repository.py's JSON statements) on asyncpg (its own binary protocol
in Cython/C) instead of libpq. Needs HTTP_SERVER=uvloop (asyncpg runs on the asyncio loop) and ALT_ADAPTERS=1 at
build. No broker (it is built on libpq): per worker, PG_READERS read connections + 1 write connection.

asyncpg runs one query at a time per connection (no pipeline mode), so each connection has a queue that a task
drains in order. Results go straight back to the transport (`attach`), not through a file descriptor. The
synchronous calls of the bcrypt routes (on the transport's helper thread) run on the same connections, through
`run_coroutine_threadsafe`.
"""

import asyncio
from collections import deque

import asyncpg

from conduit_server.adapters.outbound.pg_repository import PostgresUserRepository
from conduit_server.domain.errors import DuplicateError
from conduit_server.ports.outbound import DatabaseDriverPort, QueryPipelinePort

_SESSION = ("SET jit = off; SET enable_seqscan = off; SET enable_memoize = off;"
            " SET plan_cache_mode = force_generic_plan; SET TimeZone = 'UTC'")


def _raw(value):
    return value


class AsyncpgPipeline(QueryPipelinePort):
    def __init__(self, url: str):
        self.url = url
        self.conn = None
        self.sql = {}  # statement index -> SQL text
        self.inflight = deque()  # (query, token, future or None)
        self.draining = False
        self.loop = self.on_results = None

    def attach(self, loop, on_results) -> None:
        """Run on `loop`; finished queries go to on_results([(token, value, error)])."""
        self.loop, self.on_results = loop, on_results

    def fileno(self) -> int:
        return -1

    def flush(self) -> bool:
        return False

    def ready(self) -> list:
        return []

    def submit(self, query, token) -> None:
        self.inflight.append((query, token, None))
        self._kick()

    async def call(self, query):
        """`query`'s value, through this connection's queue (for synchronous callers on other threads)."""
        fut = self.loop.create_future()
        self.inflight.append((query, None, fut))
        self._kick()
        return await fut

    def _kick(self):
        if not self.draining:
            self.draining = True
            self.loop.create_task(self._drain())

    async def _drain(self):
        q = self.inflight
        try:
            while q:
                query, token, fut = q[0]
                try:
                    value, error = await self._run(query), None
                except Exception as e:
                    value, error = None, e
                q.popleft()
                if fut is None:
                    self.on_results([(token, value, error)])
                elif error is None:
                    fut.set_result(value)
                else:
                    fut.set_exception(error)
        finally:
            self.draining = False

    async def _run(self, query):
        if self.conn is None or self.conn.is_closed():
            # asyncpg's own statement cache prepares each statement once per connection. (An explicit prepare() with
            # the cache off cost Postgres 490 µs per list page against 190: re-prepared on every call.)
            self.conn = await asyncpg.connect(self.url, statement_cache_size=1024)
            await self.conn.execute(_SESSION)
            # json comes back as its bytes (binary format = the text), with no decoding: the response body
            await self.conn.set_type_codec("json", schema="pg_catalog", encoder=_raw, decoder=_raw, format="binary")
        stmt = query.stmt
        sql = self.sql.get(stmt.index)
        if sql is None:
            sql = self.sql[stmt.index] = stmt.sql.decode()
        try:
            if query.json:
                return await self.conn.fetchval(sql, *query.args)
            records = await self.conn.fetch(sql, *query.args)
        except asyncpg.UniqueViolationError:
            raise DuplicateError("username or email already taken")
        if records and stmt.cols is None:
            stmt.cols = list(records[0].keys())
        rows = [tuple(r) for r in records]
        return rows if query.finish is None else query.finish(rows)


class AsyncpgRepository(PostgresUserRepository):
    """PostgresUserRepository's methods and Query objects; its synchronous calls run on the driver's connections."""

    def __init__(self, driver: "AsyncpgDriver"):
        self.pool = None
        self.driver = driver

    def _sync(self, query):
        loop = self.driver.loop
        if loop is None:
            raise RuntimeError("DB_DRIVER=asyncpg needs HTTP_SERVER=uvloop with the pipeline on")
        pipe = self.driver.pipes[0]
        return asyncio.run_coroutine_threadsafe(pipe.call(query), loop).result()

    def _rows(self, stmt, args) -> list:
        return self._sync(_Plain(stmt, args, False))

    def _json(self, stmt, args):
        return self._sync(_Plain(stmt, args, True))


class _Plain:
    __slots__ = ("stmt", "args", "json")
    finish = None

    def __init__(self, stmt, args, json):
        self.stmt, self.args, self.json = stmt, args, json


class AsyncpgDriver(DatabaseDriverPort):
    supports_broker = False
    needs_asyncio = True  # main.py: only with an asyncio transport (HTTP_SERVER=uvloop)

    def __init__(self, database_url: str):
        self.database_url = database_url
        self.pipes = ()

    @property
    def loop(self):
        return self.pipes[0].loop if self.pipes else None

    def repository(self, threads: int, pool_size: int, codec=None) -> AsyncpgRepository:
        if threads:
            raise SystemExit("Error: DB_DRIVER=asyncpg runs inline only (THREADS=0)")
        return AsyncpgRepository(self)

    def pipelines(self, readers: int) -> tuple:
        self.pipes = tuple(AsyncpgPipeline(self.database_url) for _ in range(readers + 1))
        return self.pipes

    @staticmethod
    def connections_per_worker(threads: int, pool_size: int, readers: int) -> int:
        if not readers:
            raise SystemExit("Error: DB_DRIVER=asyncpg needs the pipeline (PIPELINE=1)")
        return readers + 1

