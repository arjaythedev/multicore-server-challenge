# Third-party source

Picohttpparser is vendored unmodified from h2o/picohttpparser revision
`465a7ff09fbd3432fe56c673451f5460154d1f07`. The MIT licence and copyright
notices are retained in both source files. It is compiled into the server.

SHA-256:

- picohttpparser.c: `6480689711996bc9a219e26df27ac32ebbb7dce2f24a63a316d041b08f646199`
- picohttpparser.h: `1fc9074dd12418b2b91e55ef3a8279bccf8d3577b790dea6f2f908ab2a157f1c`

libpq is linked from PostgreSQL 18.6. The native development helper builds
the official PostgreSQL distribution inside the workspace. Its licence is
available in that distribution's COPYRIGHT file. No database binary is committed.

The independent bcrypt lane scheduler is adapted from Zig 0.17.0's
`lib/std/crypto/bcrypt.zig`, using the standard library's public Blowfish state.
Its MIT licence is retained in [zig-LICENSE](zig-LICENSE). Each independent lane
retains its own state, salt and complete cost-10 computation. The normal password
path stays on the standard library until the optional lane implementation passes
correctness and Linux performance comparisons.
