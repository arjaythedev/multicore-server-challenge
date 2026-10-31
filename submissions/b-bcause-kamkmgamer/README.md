# B / BCause, kamkmgamer

Front: direct

This submission uses the B programming language for the process entrypoint.
`main.b` calls the C ABI support runtime because B has no maintained
PostgreSQL, io_uring, JWT, or bcrypt libraries. The support runtime is the
hand-written Conduit server in `src/`, while B owns the executable entry and
build path.

BCause is vendored under `bcause/` and compiles B to x86-64 assembly. The
support runtime provides direct HTTP/1.1 handling, PostgreSQL wire-protocol
access, prepared statements, JSON serialization, HS256 JWT checks, and
cost-10 bcrypt. It keeps the challenge's no-cache and durable-write rules.

`build.sh` compiles the B entrypoint, compiles the C support objects, and links
both with liburing, libxcrypt, pthreads, and the BCause standard library.
`start.sh` runs the resulting direct server. Runtime configuration comes from
`DATABASE_URL`, `JWT_SECRET`, `HOST`, and `PORT`; the support runtime also
accepts its normal tuning variables such as `THREADS`, `DB_CONNS`, and
`BCRYPT_THREADS`.

```sh
sudo bash install.sh
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit \
JWT_SECRET=multicore-server-challenge HOST=0.0.0.0 PORT=80 bash start.sh
```

The BCause compiler is MIT licensed. The Conduit support runtime and its
native bcrypt implementation retain their original MIT attribution.

## Attribution and changes

This submission is derived from [PR #10](https://github.com/arjaythedev/multicore-server-challenge/pull/10) by [@tigokraft](https://github.com/tigokraft), using the submissions/c-iouring-tigokraft C runtime as its support implementation. The src/ files retained from that entry are api.c, bcrypt.c, bf_pi.h, conduit.h, json.c, pg.c, server.c, stats.c, and util.c; credit for that implementation belongs to tigokraft.

Our changes in this folder are:

- add a B process entrypoint and a B-written request router. Every request's decoded API segments pass through B's
  b_route classifier before C authenticates or executes the endpoint;
- keep the endpoint authorization matrix in B as well, so route selection and optional/required token policy share one
  language-owned dispatch layer;
- vendor and build the BCause compiler and B standard library;
- adapt the install, build, and start scripts for the hybrid B/C entry;
- keep the challenge contract and runtime tuning behavior while linking the existing C server.
- reserve a zeroed machine-word tail in each parsed request so B's word-at-a-time static-token checks remain bounded
  even when the final path segment is short.
- keep the B-to-host-C startup alignment fix scoped to the generated main frame, so helper functions retain their own
  stack frames.

The C runtime remains derived from #10, but B now owns process entry and the static route classifier on every request;
this is a distinct B/C hot-path variant rather than an uncredited copy.
