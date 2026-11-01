"""The engine's calling convention, shared by the test harnesses.

One marker statement per endpoint, prepared once per connection and executed with one bytea: the batch's
request count as a u32, then per request each field, an int8 as 8 bytes, a text as a u32 byte length and
its UTF-8 bytes, all little-endian. Each request is a tuple whose leading items are the endpoint's fields
in FIELDS order (any further items are ignored).
"""
import struct
import psycopg2

# endpoint -> its request fields: i = int8, t = text
FIELDS = {
    "article": "it",  # viewer, slug
    "comments": "it",  # viewer, slug
    "profile": "it",  # viewer, username
    "user": "it",  # user id, token
    "tags": "i",  # unread
    "list_all": "iii",  # viewer, limit, offset
    "feed": "iii",  # viewer, limit, offset
    "list_tag": "iiit",  # viewer, limit, offset, tag
    "list_author": "iiit",  # viewer, limit, offset, username
    "list_favorited": "iiit",  # viewer, limit, offset, username
}


# endpoint ids, as shim/pgengine.h numbers them: engine_mega's u8 before each request
KINDS = ["article", "list_all", "list_tag", "list_author", "list_favorited", "feed", "comments", "profile", "user",
         "tags"]


def marker(name):
    return (f"SELECT NULL::int2 AS engine_{name}, NULL::bytea AS body "
            "WHERE current_setting('pgengine.required') IS NOT NULL AND $1::bytea IS NOT NULL")


def fields(name, req):
    out = []
    for kind, v in zip(FIELDS[name], req):
        if kind == "i":
            out.append(struct.pack("<q", v))
        else:
            b = v.encode()
            out.append(struct.pack("<I", len(b)) + b)
    return b"".join(out)


def pack(name, reqs):
    return psycopg2.Binary(struct.pack("<I", len(reqs)) + b"".join(fields(name, r) for r in reqs))


def pack_mega(reqs):
    """engine_mega's parameter for (endpoint name, request) pairs: each request's fields after its endpoint id."""
    return psycopg2.Binary(struct.pack("<I", len(reqs)) +
                           b"".join(bytes([KINDS.index(n)]) + fields(n, r) for n, r in reqs))


def prepare(cur, names=FIELDS):
    for name in names:
        cur.execute(f"PREPARE m_{name}(bytea) AS {marker(name)}")


def execute(cur, name, reqs):
    cur.execute(f"EXECUTE m_{name}(%s)", [pack(name, reqs)])
