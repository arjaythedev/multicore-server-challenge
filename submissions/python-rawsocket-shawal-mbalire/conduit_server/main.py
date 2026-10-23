import os
import sys
from psycopg_pool import ConnectionPool

from conduit_server.adapters.inbound.socket_server import RawSocketHttpServer
from conduit_server.adapters.inbound.router import router
import conduit_server.adapters.inbound.controllers as controllers

from conduit_server.adapters.outbound.pg_repository import PostgresUserRepository
from conduit_server.adapters.outbound.crypto_adapter import JoseBcryptCryptoAdapter


def main():
    database_url = os.getenv("DATABASE_URL")
    port = int(os.getenv("PORT", 3000))
    host = os.getenv("HOST", "0.0.0.0")
    jwt_secret = os.getenv("JWT_SECRET", "default-secret")

    if not database_url:
        print("Error: DATABASE_URL environment variable is required.", file=sys.stderr)
        sys.exit(1)

    print(f"Initializing high-performance Conduit server on {host}:{port}...", flush=True)

    # Bounded connection pool (Postgres max_connections = 100; total across processes <= 95)
    db_pool = ConnectionPool(conninfo=database_url, min_size=5, max_size=30, open=True)

    article_repository = PostgresUserRepository(db_pool)
    crypto_adapter = JoseBcryptCryptoAdapter(secret_key=jwt_secret)

    # Composition root: wire ports into controllers, then start the raw socket server.
    controllers.bootstrap(article_repository, crypto_adapter)

    server = RawSocketHttpServer(host=host, port=port, router=router.dispatch)

    try:
        server.start()
    except KeyboardInterrupt:
        print("\nShutting down server gracefully...")
        db_pool.close()
        sys.exit(0)


if __name__ == "__main__":
    main()
