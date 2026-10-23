"""Per-endpoint Python CPU (single thread, real DB) + cProfile top functions.

    PYTHONPATH=. .venv/bin/python scripts/profile.py      # needs the conduit_lg full-seed copy
"""
import cProfile
import pstats
import time
import warnings

from psycopg_pool import ConnectionPool

import conduit_server.adapters.inbound.controllers as controllers
from conduit_server.adapters.inbound.router import router, parse_request
from conduit_server.adapters.outbound.pg_repository import PostgresUserRepository, configure_connection
from conduit_server.adapters.outbound.crypto_adapter import JoseBcryptCryptoAdapter

warnings.filterwarnings("ignore")
pool = ConnectionPool("postgres://conduit:conduit@127.0.0.1:5432/conduit_lg", min_size=1, max_size=1,
                      configure=configure_connection, open=True)
crypto = JoseBcryptCryptoAdapter("dev-secret")
controllers.bootstrap(PostgresUserRepository(pool), crypto)
tok = crypto.issue_token(5)
with pool.connection() as conn:
    slug = conn.execute("SELECT slug FROM articles WHERE id = 499000").fetchone()[0]
auth = f"Authorization: Token {tok}\r\n"
reqs = [f"GET /api/articles/{slug} HTTP/1.1\r\n{auth}\r\n",
        f"GET /api/articles/{slug}/comments HTTP/1.1\r\n{auth}\r\n",
        f"GET /api/articles?limit=10&offset=0 HTTP/1.1\r\n{auth}\r\n",
        f"GET /api/articles/feed?limit=10&offset=0 HTTP/1.1\r\n{auth}\r\n",
        "GET /api/tags HTTP/1.1\r\n\r\n",
        f"GET /api/user HTTP/1.1\r\n{auth}\r\n"]
reqs = [r.encode() for r in reqs]
for r in reqs:
    for _ in range(20):
        router.dispatch_sync(parse_request(r))
for r in reqs:
    t, w = time.process_time(), time.perf_counter()
    for _ in range(300):
        router.dispatch_sync(parse_request(r))
    print(f"{r.split(b' ')[1][:40].decode():42} cpu {(time.process_time() - t) / 300 * 1e6:5.0f}us"
          f"  wall {(time.perf_counter() - w) / 300 * 1e6:5.0f}us")
pr = cProfile.Profile()
pr.enable()
for _ in range(300):
    for r in reqs:
        router.dispatch_sync(parse_request(r))
pr.disable()
pstats.Stats(pr).sort_stats("tottime").print_stats(25)
pool.close()
