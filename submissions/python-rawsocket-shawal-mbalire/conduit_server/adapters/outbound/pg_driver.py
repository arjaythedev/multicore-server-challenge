"""The libpq database driver (DB_DRIVER=libpq, the default): psycopg's libpq bindings, statements prepared at
connect (pg_repository.py), pipelines in the worker's epoll, and the shared broker process (pg_broker.py)."""

from conduit_server.adapters.outbound.pg_broker import BrokerClient, serve_broker
from conduit_server.adapters.outbound.pg_repository import (
    PgPipeline,
    PostgresUserRepository,
    SingleConnection,
    configure_connection,
)
from conduit_server.ports.outbound import DatabaseDriverPort


class LibpqDriver(DatabaseDriverPort):
    supports_broker = True

    def __init__(self, database_url: str):
        self.database_url = database_url

    def repository(self, threads: int, pool_size: int, codec=None) -> PostgresUserRepository:
        if threads == 0:
            return PostgresUserRepository(SingleConnection(self.database_url))
        from psycopg_pool import ConnectionPool

        return PostgresUserRepository(ConnectionPool(
            conninfo=self.database_url,
            min_size=pool_size,
            max_size=pool_size,
            configure=configure_connection,
            open=True,
        ))

    def pipelines(self, readers: int) -> tuple:
        return tuple(PgPipeline(self.database_url) for _ in range(readers + 1))

    @staticmethod
    def connections_per_worker(threads: int, pool_size: int, readers: int) -> int:
        """Inline with the pipeline: `readers` read pipelines + 1 write pipeline + 1 for the bcrypt helper thread
        (the loop's own SingleConnection is never opened). Inline without it: the loop's connection + the
        helper's. Threaded: its pool."""
        if threads:
            return pool_size
        return (readers + 1 if readers else 1) + 1

    # ---- the shared broker (BROKER=1) ----------------------------------------------------------------------------
    @staticmethod
    def broker_client(sock) -> BrokerClient:
        return BrokerClient(sock)

    def serve_broker(self, socks, readers: int, writers: int, make_bcrypt=None) -> None:
        serve_broker(socks, self.database_url, readers, writers, make_bcrypt)
