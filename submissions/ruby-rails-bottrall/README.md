# Conduit API: Ruby on Rails 8.1 + Falcon + YJIT

**Front: direct.** Falcon serves port 80 itself: one forked worker per core, each an event loop with a fiber per connection.

This is not an attempt to win. It's an answer to a different question: how far does a Rails app get if it is written the way you'd want to maintain it (models, scopes, resourceful controllers, `has_secure_password`, about 600 lines of app code) and then given the handful of optimizations a production Rails team would reasonably make? Every optimization below is a config setting, a scope written like the reference SQL, or a few lines with a comment saying why, and each one was measured before it went in.

## Versions

| Piece | Version |
|---|---|
| Ruby | CRuby 4.0.9, built from source by `install.sh` with YJIT and jemalloc |
| Rails | 8.1.4: Active Record and Action Controller (`api_only`) only |
| Server | Falcon 0.57.0 (async 2.46, protocol-http1 0.41) |
| Postgres driver | pg 1.7.0 (compiled against libpq, fiber-scheduler aware) |
| bcrypt | bcrypt 3.1.22 via `has_secure_password`, cost 10 |
| JWT | jwt 3.3.0, HS256 |

Every gem is pinned in `Gemfile.lock` (platform `ruby`), and `build.sh` compiles native extensions from source (`force_ruby_platform`).

## How it uses the cores

- `falcon host falcon.rb` boots Rails once in the parent (`config/preload.rb`, then `Process.warmup`) and forks `nproc` workers, so they share the booted heap copy-on-write. Crashed workers are not restarted (`restart: false`).
- Each worker is one thread running an event loop. Every connection is a fiber, and the pg gem yields to the fiber scheduler while a query is in flight. One worker can therefore keep its whole Active Record pool busy without threads or the GVL getting involved. `config.active_support.isolation_level = :fiber` makes Rails' per-request state (the leased connection, `CurrentAttributes`) fiber-local.
- Each worker has a pool of `90 / workers` connections (88 in total on 8 cores, within the 95 budget). A request leases one connection for its duration.

## Layout

```
app/models/          User, Article, Comment, Tag, ArticleTag, Favorite, Follow: associations and scopes
app/models/article_listing.rb   the five list variants (global, tag, author, favorited, feed) as page + count
app/controllers/     one resourceful controller per resource (users, sessions, current_users, profiles,
                     follows, articles, favorites, comments, tags)
app/controllers/concerns/       Authentication (token auth, `allow_anonymous`) and RequestInput (strict 422s)
app/serializers/conduit_json.rb pure functions from records to the API's JSON
lib/access_tokens.rb            JWT issue/verify, built once at boot and injected through config
```

The SQL is the reference SQL from `SPEC.md`, expressed as Active Record scopes. `Article.presented_for(viewer_id)` is the shared `ARTICLE_LIST_SELECT`, and the list filters compose onto it:

```ruby
listing = ArticleListing.filtered(tag:, author:, favorited:, limit:, offset:)
render json: { articles: listing.articles_for(viewer_id).map { ConduitJson.article(it) },
               articlesCount: listing.total }
```

## Optimizations, with what each one bought

Measured on the full seed. See "Local numbers" below for the setup.

1. **YJIT.** Same app, same requests, in process: **730 → 451 µs per request** (−38%, and that figure includes time spent waiting on Postgres). Rails turns YJIT on after boot (`config.yjit`, spelled out in `config/application.rb`), so it compiles only code that runs while serving requests. Forked workers inherit it.
2. **Every hot query is a prepared statement.** Active Record declines to prepare any statement that contains a raw SQL string, in case values were interpolated into it. The projection's subqueries go through `ApplicationRecord.bound_sql`, constant fragments that take values only as `?` binds, so they stay prepared and Postgres skips the parse on every request.
3. **Scalar subqueries, as in the reference SQL.** `where(author_id: User.where(username:).select(:id))` writes `IN (subquery)`. Postgres plans that as a join, fetches *every* article by that author, and runs the per-row subqueries on all of them before applying `LIMIT 5`. `where_scalar` writes `= (subquery)` instead, which walks `articles_author_idx` and stops. The author list went from **1,330 to 138 µs** of Postgres time per call (it had been 27% of all database time), and the tag list from 587 to 255 µs. Postgres CPU per request dropped 19%.
4. **No gzip.** Falcon's default middleware compresses any response the client accepts gzip for, which was **~10% of a worker's CPU**. Compression is optional in this API, so `falcon.rb` serves the Rack app without that layer.
5. **bcrypt off the event loop.** bcrypt releases the GVL, but a worker is a single-threaded event loop, so a ~40 ms hash still stalled every other request on it. `User#password=` and `#authenticate_password` hash on a short-lived thread instead, and under the fiber scheduler only the request that needs the hash waits for it. With 16 concurrent logins on one worker, the logins took 748 → 239 ms and the worst `/api/tags` latency alongside them went from 360 → 100 ms.
6. **GC heap pre-sizing.** `RUBY_GC_HEAP_{0,1,2}_INIT_SLOTS` in `start.sh` start each worker with a heap sized for the request mix, which **halves the time spent in GC**. Larger heaps, malloc limits and old-object factors measured as no better.
7. **Small Rails trims, each a line of config:**
   - Drop the middleware an API doesn't use (ETag, which hashes every body; Runtime; RequestId; RemoteIp; the request logger).
   - Turn off the per-request query cache, since no request repeats a SELECT.
   - Set `belongs_to_required_by_default = false`. The foreign keys already enforce it, and otherwise every `create!` runs a SELECT per association.
   - Plain `Time` instead of `TimeWithZone`.
   - Read computed columns as `record[:tag_list]`. Active Record only defines reader methods for table columns, so `record.tag_list` goes through `method_missing`, which was 7.5% of CPU.
8. **jemalloc** as Ruby's allocator (`--with-jemalloc`), as in Rails' own production Dockerfile.

Tried and rejected:

- **Nginx in front.** It saves the app ~7% CPU per request (fewer connection fibers for the GC to scan) and costs ~70 µs/request of its own. At 27k users locally it lost: p95 202 ms vs 27 ms direct.
- **`plan_cache_mode = force_generic_plan`.** The list queries' parameterized `LIMIT`/`OFFSET` make Postgres re-plan them on every execution, but the generic plan for the global list took 1.8 s per call.

## Rules

- No caching across requests: every request reads Postgres, and there is no response cache, no query-result cache (the per-request query cache is off too), and no memoized token or bcrypt results.
- Passwords are bcrypt cost 10 (`BCrypt::Engine.cost = 10`; `has_secure_password` would otherwise use 12). Every login verifies against the stored hash.
- Every request verifies the token's HS256 signature and `exp` (the `jwt` gem with `algorithm: "HS256"` and `required_claims: %w[exp sub]`). `sub` must be a decimal string.
- Writes commit before the response. Article creation is one transaction.

## Local numbers

These numbers come from an AMD Ryzen 5 7600 (6 cores / 12 threads). Postgres 18 (with the box's pgtune settings) and the app were pinned to 8 hardware threads, and the load generator (`loadgen run`, two processes on separate loopback addresses) ran on the other 4. Each run is the scorer's probe: 60 s ramp + 60 s measured, full seed.

| Users | req/s | p95 | p99 | CPU: app + Postgres (of 8) | Result |
|--:|--:|--:|--:|---|---|
| 20,000 | 5,303 | 5 ms | 25 ms | 3.05 + 1.49 | pass |
| 27,000 | 7,156 | 23 ms | 54 ms | 4.48 + 2.30 | pass |
| 29,000 | 7,284 | 557 ms | 738 ms | 5.18 + 2.61 | fail (CPU saturated) |
| 27,000, 5-minute hold | 7,138 | 46 ms | 123 ms | 4.60 + 2.44 | pass (2.1M requests, 0 errors, app RSS 3.5 GB) |

Under load the app spends ~600 µs of CPU per request and Postgres ~320 µs.

For calibration, the Go example (24,000 on the leaderboard) passed 30,000 users on this same setup at 143 µs app + 217 µs Postgres per request. Its leaderboard CPU split implies requests cost ~2.5× more CPU on the benchmark box than here, so expect this server to land around **11–13k users** there. That's an estimate, not a measurement.

## Build and run

```bash
sudo bash install.sh   # once: Ruby 4.0.9 + YJIT + jemalloc into /opt/ruby-4.0.9, plus libpq/tzdata
bash build.sh          # gems into ./vendor/bundle
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`WEB_CONCURRENCY` (default `nproc`) and `DB_POOL` (default `90 / WEB_CONCURRENCY`) override the worker and pool sizes.
