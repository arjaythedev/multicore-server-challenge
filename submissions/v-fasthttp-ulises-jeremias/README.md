# V: veb + libpq

**Front: direct.** This submission uses V's `veb` fasthttp backend (`-d new_veb`), V's `db.pg` libpq bindings, `crypto.bcrypt`, and V crypto primitives for JWT authentication. It opens a fixed set of 64 PostgreSQL connections at startup and leases each connection to one request at a time through a bounded channel. `DB_CONNS` can tune the count from 1 to 90; the challenge-wide connection limit is 95.

Article-list pages and their capped counts come from one SQL statement. Article creation, including tag insertion and linking, is one atomic statement. Page metadata is calculated only for returned articles. There are no response caches; every request authenticates its token and reads committed database state.

Direct mode lets the V server accept keep-alive connections on the benchmark port without Nginx in front. This saves the proxy CPU and avoids an extra request hop. The service unit grants the capability needed to bind port 80 without running the server as root.

`install.sh` builds V at commit `d67ee5500338554f54c7c8ca4cc00df42159577d` and links against the system `libpq` client. `build.sh` compiles the server with `-prod -prealloc -d new_veb`. No generated binaries or vendored dependencies are committed.

## Local load results

On the development host, the full 500,000-article seed passed a five-minute hold at 4,000 VUs with `-think-scale 0.2`: 5,133 req/s, p95 126.1 ms, p99 487.7 ms, and no errors. This ran after a 60-second ramp; the app, PostgreSQL, and load generator shared a 24-thread host. The accelerated think scale and shared host make this a local comparison result, not the official score: the challenge box has 8 vCPUs and its official five-minute hold uses the default workload settings.
