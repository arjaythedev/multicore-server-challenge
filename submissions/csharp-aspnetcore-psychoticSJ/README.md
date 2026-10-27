# C# / ASP.NET Core — psychoticSJ

Front: direct

Author: [psychoticSJ](https://github.com/psychoticSJ)

.NET SDK 10.0.402, ASP.NET Core/Kestrel, Npgsql 10.0.3 and PostgreSQL 18. BCrypt.Net-Next 4.0.3 is compiled from vendored source; its pinned commit, modifications and license notices are recorded in Vendor/BCrypt.Net/SOURCE.md.

On Ubuntu 24.04 x86_64:

```bash
sudo bash install.sh
bash build.sh
```

The installer verifies the pinned SDK archive with SHA-512. The build restores locked dependencies and publishes Release output. With the organizer's environment variables:

```bash
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

The server speaks HTTP/1.1 with keep-alive and runs in the foreground. GET /api/tags is its health endpoint. No reverse proxy is required.

The coded defaults use one process, 34 read connections and 61 write connections (95 total), 21 read workers, batches of up to 48 and five dedicated bcrypt workers at cost 10. Two read workers and 512 admission slots are reserved for tags/profiles; nineteen workers and 7,680 slots serve other shapes.

The implementation uses a terminal Kestrel dispatcher, span-based parsing, direct Npgsql, typed positional parameters, prepared commands and reused sessions. Read batches execute fresh SQL; identical global/filtered page inputs and comment detail work are shared only within the current statement. Indexed lookups bound enrichment work, anonymous flags skip impossible lookups, and required ordering and count/comment limits are preserved.

Article/comment JSON bytes may be shared only while encoding the current live batch. Each response owns its own pooled buffer and takes viewer-specific flags from its own SQL row. The per-worker fragment index is bounded at 256 objects and cleared before response handoff and on failure. No result or response fragment is reused by another batch.

Passwords always use fresh cost-10 bcrypt work. HS256 signatures and expiration are verified on every authenticated request. Writes commit before their responses; article creation and tag linking use one atomic transaction. PostgreSQL schema, indexes, server settings and durability remain unchanged. Sessions set only jit=off and max_parallel_workers_per_gather=0. No host scheduling or GC tuning is applied.

Optional READ_METRICS_PATH, WRITE_METRICS_PATH and BCRYPT_METRICS_PATH enable aggregate diagnostic CSVs. Bcrypt metrics distinguish channel/queue wait from bcrypt execution wall time, which includes CPU scheduling. They log no passwords or hashes. With these variables absent, collectors are disabled.

Linux Release correctness passed all 197 official checks and 197 normalized golden responses, concurrent reads/writes, expanded/fresh SQL equivalence, JSON ownership/flag fixtures and reserved-worker isolation. These checks do not claim a throughput or sustained-user score.

Submit this source folder, lockfiles, scripts and vendored licenses. Exclude generated output; the organizer builds from source on the benchmark machine.
