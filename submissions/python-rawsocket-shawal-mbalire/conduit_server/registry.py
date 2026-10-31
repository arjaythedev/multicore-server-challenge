"""Adapter registry: which adapter plugs into each port, chosen by environment variable.

Each port has a variable and a table of adapters by name; the first one is the default. An adapter is named by
"module:attribute" and imported only when chosen, so an adapter's dependencies (uvloop, asyncpg, ...) are needed
only by the runs that use it. To add one: write a class implementing the port (ports/), add a line here.
"""

import importlib
import os

ADAPTERS = {
    # inbound: the transport each worker runs (ports.inbound.InboundServer)
    "HTTP_SERVER": {
        "epoll": "conduit_server.adapters.inbound.socket_server:RawSocketHttpServer",
        "uvloop": "conduit_server.adapters.inbound.uvloop_server:UvloopHttpServer",
    },
    # request and response bodies (ports.outbound.JsonCodecPort)
    "JSON_CODEC": {
        "orjson": "conduit_server.adapters.outbound.json_codec:OrjsonCodec",
        "msgspec": "conduit_server.adapters.outbound.json_codec:MsgspecCodec",
        "stdlib": "conduit_server.adapters.outbound.json_codec:StdlibCodec",
        "ujson": "conduit_server.adapters.outbound.json_codec:UjsonCodec",
        "rapidjson": "conduit_server.adapters.outbound.json_codec:RapidjsonCodec",
        "yyjson": "conduit_server.adapters.outbound.json_codec:YyjsonCodec",
        "pydantic": "conduit_server.adapters.outbound.json_codec:PydanticCodec",
    },
    # Postgres: repository, pipelines and broker (ports.outbound.DatabaseDriverPort)
    "DB_DRIVER": {
        "libpq": "conduit_server.adapters.outbound.pg_driver:LibpqDriver",
        "libpq-ctypes": "conduit_server.adapters.outbound.pg_driver_ctypes:LibpqCtypesDriver",
        "libpq-rows": "conduit_server.adapters.outbound.pg_rows_repository:LibpqRowsDriver",
        "asyncpg": "conduit_server.adapters.outbound.asyncpg_driver:AsyncpgDriver",
    },
    # bcrypt (ports.outbound.PasswordHasherPort)
    "PASSWORD_HASHER": {
        "bcrypt": "conduit_server.adapters.outbound.crypto_adapter:BcryptPasswordHasher",
        "libxcrypt": "conduit_server.adapters.outbound.crypto_adapter:LibxcryptPasswordHasher",
        "pyca": "conduit_server.adapters.outbound.crypto_adapter:PycaPasswordHasher",
    },
    # auth tokens (ports.outbound.TokenPort)
    "TOKENS": {
        "hs256": "conduit_server.adapters.outbound.crypto_adapter:Hs256TokenService",
        "hs256-py": "conduit_server.adapters.outbound.crypto_adapter:Hs256PyTokenService",
        "pyjwt": "conduit_server.adapters.outbound.crypto_adapter:PyJwtTokenService",
    },
}


def choice(port: str) -> str:
    """The adapter name chosen for `port`: $PORT_VARIABLE, else the table's first entry."""
    table = ADAPTERS[port]
    name = os.getenv(port) or next(iter(table))
    if name not in table:
        raise SystemExit(f"Error: {port}={name!r}; choose one of: {', '.join(table)}")
    return name


def adapter(port: str):
    """The chosen adapter for `port` (a class or factory), imported now."""
    module, _, attr = ADAPTERS[port][choice(port)].partition(":")
    return getattr(importlib.import_module(module), attr)


def chosen() -> str:
    """One line for the startup log, e.g. "HTTP_SERVER=epoll JSON_CODEC=orjson ..."."""
    return " ".join(f"{port}={choice(port)}" for port in ADAPTERS)
