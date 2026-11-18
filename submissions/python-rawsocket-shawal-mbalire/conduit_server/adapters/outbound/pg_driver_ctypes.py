"""DB_DRIVER=libpq-ctypes: the libpq driver on psycopg's pure-Python implementation (libpq through ctypes, rows
decoded in Python) instead of psycopg-c, to measure what the C bindings save. Same statements and broker."""

import os
import sys

if "psycopg" in sys.modules:
    raise SystemExit("Error: DB_DRIVER=libpq-ctypes must be imported before psycopg")
os.environ["PSYCOPG_IMPL"] = "python"

from conduit_server.adapters.outbound.pg_driver import LibpqDriver  # noqa: E402

import psycopg  # noqa: E402

assert psycopg.pq.__impl__ == "python", psycopg.pq.__impl__

LibpqCtypesDriver = LibpqDriver
