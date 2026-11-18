import asyncio
import collections
import sys

import asyncpg


async def _connect(dsn: str) -> asyncpg.Connection:
    conn = await asyncpg.connect(
        dsn,
        ssl=False,  # asyncpg defaults to "prefer", which turns on TLS even on loopback
        command_timeout=30,
        # plan each statement once per connection; planning costs more than running these queries
        server_settings={
            "jit": "off",
            "TimeZone": "UTC",
            "plan_cache_mode": "force_generic_plan",
            "max_parallel_workers_per_gather": "0",  # every query is short and uses an index
            "application_name": "conduit",
        },
    )
    # json values come back as the bytes Postgres sent, and go into the response as they are
    await conn.set_type_codec("json", schema="pg_catalog", encoder=lambda s: s, decoder=lambda b: b, format="binary")
    return conn


class Pool:
    def __init__(self, dsn: str, size: int):
        self.dsn = dsn
        self.size = size
        self.idle: list[asyncpg.Connection] = []
        self.waiters: collections.deque[asyncio.Future] = collections.deque()

    async def start(self) -> None:
        self.idle = list(await asyncio.gather(*(_connect(self.dsn) for _ in range(self.size))))

    def take(self) -> asyncpg.Connection | None:
        """An idle open connection, or None. Ones that died while idle (database restart) get replaced."""
        idle = self.idle
        while idle:
            conn = idle.pop()
            if not conn.is_closed():
                return conn
            self.discard(conn)
        return None

    async def wait(self) -> asyncpg.Connection:
        """All connections are busy: wait for the next one that is released."""
        fut = asyncio.get_running_loop().create_future()
        self.waiters.append(fut)
        return await fut

    def release(self, conn: asyncpg.Connection) -> None:
        while self.waiters:
            fut = self.waiters.popleft()
            if not fut.done():  # that request was cancelled
                fut.set_result(conn)
                return
        self.idle.append(conn)

    def discard(self, conn: asyncpg.Connection) -> None:
        """The connection is broken: drop it and open a new one."""
        conn.terminate()
        asyncio.ensure_future(self._replace())

    async def _replace(self) -> None:
        delay = 0.05
        while True:
            try:
                self.release(await _connect(self.dsn))
                return
            except Exception as e:  # database restarting, too many connections, etc.
                print(f"db reconnect failed: {e!r}", file=sys.stderr, flush=True)
                await asyncio.sleep(delay)
                delay = min(delay * 2, 2.0)

    async def close(self) -> None:
        await asyncio.gather(*(c.close(timeout=2) for c in self.idle), return_exceptions=True)
