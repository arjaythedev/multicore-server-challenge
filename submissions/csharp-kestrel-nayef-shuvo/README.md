# C#: Kestrel + Npgsql (Native AOT)

**Front: nginx**

A plain, unoptimized baseline: a hand-written router on Kestrel's request delegate (no MVC, no minimal-API routing),
Npgsql with the reference SQL from `SPEC.md` verbatim, no caching. Optimizations come later.

| Piece | Version |
|---|---|
| .NET | 10, compiled with Native AOT to one native executable (`install.sh` installs SDK 10.0.402, clang and zlib1g-dev) |
| HTTP | ASP.NET Core Kestrel, one `app.Run` request delegate, manual routing |
| JSON | `System.Text.Json` (`Utf8JsonWriter` out, `JsonDocument` in) |
| Postgres | `Npgsql` 10.0.3, one `NpgsqlDataSource`, `MaxPoolSize = DB_POOL_SIZE` |
| JWT | `Microsoft.IdentityModel.JsonWebTokens` 8.23.0 (HS256 only, `exp` required) |
| bcrypt | `BCrypt.Net-Next` 4.2.0, cost 10 |

Environment: `DATABASE_URL`, `JWT_SECRET` (required), `DB_POOL_SIZE` (10 per core, max 90),
`HOST` (127.0.0.1), `PORT` (3000).

## Build and run

`build.sh` publishes with Native AOT (about 40 s) into `bin/conduit`; `start.sh` runs it. Where clang is missing it falls back to gcc.

```bash
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=conduit-dev-secret PORT=3000 bash start.sh
```
