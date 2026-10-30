# Zig / io_uring

Front: direct

| | |
|---|---|
| Language | Zig 0.17.0 (official tarball, pinned by SHA-256 in `install.sh`) |
| Framework | none: our own HTTP/1.1 server on raw io_uring |
| Database driver | none: our own PostgreSQL wire client (SCRAM-SHA-256, prepared statements, binary rows) |
| Database | PostgreSQL 18 |
| Other dependencies | none. JSON, JWT, SHA-256, bcrypt (assembly) and gzip are written here |

```sh
sudo bash install.sh && bash build.sh
DATABASE_URL=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

No caches across requests, no schema or Postgres config changes, no host tuning.

## Where the time goes

```
box CPU at 170k users   ████████████████████████████▌   Postgres 57%
                        ████████████████                server   32%  (mostly kernel TCP)
```

Postgres is the bottleneck, so most of the speed comes from making each request cheaper for Postgres. The rest
comes from sending fewer packets.

## 1. One read queue for the whole box

Most servers batch reads per worker. We batch every worker's reads together in one **drain process** that owns
all the read connections.

```
 typical                                   ours

 worker ─ queue ─ conns ─┐                 worker ─┐
 worker ─ queue ─ conns ─┤                 worker ─┤  lock-free rings     ┌ feeds    (every 80 ms) ┐
 worker ─ queue ─ conns ─┼─► Postgres      worker ─┼─ in shared memory ─► drain  comments (100 ms) ├─► Postgres
 worker ─ queue ─ conns ─┘                 worker ─┘                      └ the rest (80 ms)       ┘
                                                                            8 read connections
 4 small batches                           1 big batch per lane
```

A bigger batch shares more work, so each read costs Postgres less. One shared queue costs about 20% less
Postgres CPU than four separate ones, and the rings add only 1-3 µs per request. Feeds, the most expensive read,
get their own lane so nothing waits behind them.

## 2. One SQL statement for every list and article read

```
 1,400 reads in a drain                       one execution of MEGA
 ┌───────────────────────────┐
 │ list all, page 1          │               ┌──────────────────────────┐
 │ by tag "zig", page 2      │   ────────►   │ each article fetched ONCE │ ──► worker builds every
 │ feed for user 812         │               │ for every read that wants │     response from the rows
 │ article "how-to-x"  × 37  │               │ it, plus per-read ids     │
 │ ...                       │               └──────────────────────────┘
 └───────────────────────────┘
```

Every list, feed and article read in a drain runs as **one execution of one prepared statement**, with arrays as
parameters. An article that many reads in the batch need is read once. That costs about 0.6x the Postgres CPU of
per-request batched SQL. Nothing is kept after the execution.

The feed gets exact shortcuts: authors with 1,000+ articles prove a viewer's count without counting, and a
viewer's walk stops early once a shared followee already fills their page.

## 3. Fewer packets: ACK delay

One CPU handles every incoming packet, and it fills before the rest of the box. So we cut packets.

```
 before                                    after
 client ── request ──►                      client ── request ──►
        ◄── ACK ──────  (a packet alone)           (ACK held back)
        ◄── response ─                            ◄── response + ACK ──  (one packet)
```

After each response the server turns `TCP_QUICKACK` off on that socket, as an io_uring command with no syscall.
The next ACK rides on the response: 27% fewer pure ACKs, 12% less load on the network core.

## 4. Fewer packets: gzip only when it saves a packet

A client ACKs every second segment, so every segment we save is an ACK we don't receive.

```
 response needs ≤ 2 segments?   → send as is
 gzip it                        → fewer segments now?  → send gzipped
                                → same count           → send as is
```

A 10-article list goes from 4 segments to 2. Our encoder (`src/pz.zig`) uses a fixed code table compiled in, so
nothing carries over between responses. It compresses a 5 KB list in about 3 µs, 4.6x faster than libdeflate.

## 5. bcrypt that only uses spare CPU

```
 priority    high ┌ event loops, Postgres, network
                  │ watchdog: takes over any batch held up too long, resumes from its last saved round
             idle └ bcrypt hashers
```

Hashing never takes CPU from anything else. The kernel is our own assembly, hashing several passwords at once with
their rounds interleaved. At startup it tests every variant and keeps the fastest on this CPU: 7.9 ms per hash
against 10.4 ms for Openwall's.

## 6. Writes and the event loop

- **Group commit with no `BEGIN`/`COMMIT`.** Up to 128 writes go out in one round trip and share one disk flush.
  Each is answered only after Postgres confirms it. 38% cheaper than our earlier write path.
- **One io_uring per worker**, multishot accept and receive, one send per response. An idle connection holds no
  buffer.

## Correctness

- At startup every SQL statement is checked against the live database. The server won't start if a column type
  doesn't match what its decoder expects.
- Batched reads were checked byte-for-byte against the same read sent alone, and responses against the Go reference
  server. bcrypt matched reference implementations on 218,496 cases.
- If any process dies, the parent kills the rest, so a crash is never a half-working server.

Ideas borrowed: #47's gather (the drain gap) and #7's array-parameter batching. Test vectors: Openwall, Rust
`bcrypt`, Go `x/crypto/bcrypt`.
