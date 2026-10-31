"""JSON codec adapters (ports.outbound.JsonCodecPort), chosen by JSON_CODEC (registry.py). Each one's output for
the domain/models.py dataclasses is byte-identical (scripts/codeccheck.py)."""

import orjson

from conduit_server.ports.outbound import JsonCodecPort


class OrjsonCodec(JsonCodecPort):
    """orjson (Rust): frozen dataclasses natively, straight to UTF-8 bytes; list page 19.3 → 4.7 µs against the
    stdlib C encoder."""

    dumps = staticmethod(orjson.dumps)
    loads = staticmethod(orjson.loads)


class MsgspecCodec(JsonCodecPort):
    """msgspec (C): dataclasses natively too. Needs ALT_ADAPTERS=1 at build."""

    def __init__(self):
        import msgspec

        self.dumps = msgspec.json.Encoder().encode
        self.loads = msgspec.json.Decoder().decode  # DecodeError is a ValueError


class StdlibCodec(JsonCodecPort):
    """The stdlib's C encoder (`_json.make_encoder`, built once), dataclasses through their own `__dict__` (frozen,
    not slots: fields in declaration order). Non-ASCII is kept as UTF-8, like orjson."""

    def __init__(self):
        import json

        enc = json.JSONEncoder(ensure_ascii=False, separators=(",", ":"), default=_fields).encode
        self.dumps = lambda value: enc(value).encode()
        self.loads = json.loads


def _fields(value):
    d = getattr(value, "__dict__", None)
    if d is None:
        raise TypeError(f"{value.__class__.__name__} is not JSON serializable")
    return d


class UjsonCodec(JsonCodecPort):
    """ujson (C). Dataclasses through `default`; no ASCII or slash escaping, like orjson."""

    def __init__(self):
        import ujson

        dumps = ujson.dumps
        self.dumps = lambda value: dumps(value, ensure_ascii=False, escape_forward_slashes=False,
                                         default=_fields).encode()
        self.loads = ujson.loads  # JSONDecodeError is a ValueError


class RapidjsonCodec(JsonCodecPort):
    """python-rapidjson (C++ RapidJSON). Dataclasses through `default`."""

    def __init__(self):
        import rapidjson

        dumps = rapidjson.dumps
        self.dumps = lambda value: dumps(value, ensure_ascii=False, default=_fields).encode()
        self.loads = rapidjson.Decoder()  # JSONDecodeError is a ValueError


class YyjsonCodec(JsonCodecPort):
    """yyjson (C, through the `yyjson` package's Document). Dataclasses through `default`."""

    def __init__(self):
        import yyjson

        dumps = yyjson.dumps
        self.dumps = lambda value: dumps(value, default=_fields).encode()
        self.loads = yyjson.loads


class PydanticCodec(JsonCodecPort):
    """pydantic-core's JSON (Rust, like orjson): dataclasses natively."""

    def __init__(self):
        import pydantic_core

        self.dumps = pydantic_core.to_json
        self.loads = pydantic_core.from_json  # ValueError on invalid input
