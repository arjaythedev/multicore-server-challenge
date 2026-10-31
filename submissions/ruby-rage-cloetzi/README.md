# Ruby + Rage + Active Record + YJIT

Front: direct

A port of [`ruby-rails-bottrall`](../ruby-rails-bottrall) from Rails + Falcon to [Rage](https://rage-rb.dev),
to see how much of a fairly normal Rails app's cost is the framework. The models, scopes, serializer, JWT code
and SQL are the Rails version's files unchanged. The controllers changed by about 20 lines, mostly because Rage
hands them one plain `params` hash instead of `ActionController::Parameters`. What did change is everything
around them: Rage's controllers and router instead of ActionController and ActionDispatch, and Iodine instead
of Falcon.

## Versions

| | |
|---|---|
| Ruby | 4.0.9, built from source by `install.sh` with YJIT and jemalloc (same `install.sh` as the Rails version) |
| Framework | rage-rb 1.29.0 (standalone mode, not inside Rails) |
| Server | rage-iodine 6.4.0 (facil.io, epoll), started by `rage s` |
| ORM | Active Record 8.1.4, without the rest of Rails |
| Postgres driver | pg 1.7.0 |
| bcrypt | bcrypt 3.1.22 through `has_secure_password`, cost 10 |
| JWT | jwt 3.3.0 |

Gems are pinned in `Gemfile.lock`, and `build.sh` compiles the native ones from source.

## How it runs

`rage s` loads the app once in the master process, then Iodine forks one worker per core. Each worker is a
single thread with an event loop and a fiber per request. Rage installs a fiber scheduler, so when pg waits on
Postgres the fiber yields and the worker serves other requests. Rage also replaces Active Record's connection
pool with a fiber-aware one, and sets Active Support's isolation level to `:fiber`.

Each worker gets `88 / workers` connections (88 on the 8 core box, plus one the master holds from boot).

Iodine respawns crashed workers by default. The challenge doesn't restart a crashed server, so
`config/environments/production.rb` stops the whole server when a worker crashes.

## Code

```
app/models/, app/serializers/   unchanged from the Rails version
app/controllers/                one controller per resource, now RageController::API
app/concerns/                   token auth and request input (Rage's loader collapses app/*, so not under controllers/)
config/routes.rb                Rage's router DSL: resources/resource as in Rails, plus a JSON 404 catch-all
lib/access_tokens.rb            JWT issue and verify (unchanged)
lib/malformed_body.rb           turns Rage's bare 400 for an unparseable body into the API's 422
```

## Differences from the Rails version

- **Malformed bodies.** Rage parses the JSON body before routing, and answers one it can't parse with an empty
  400, outside any controller (`rescue_from` can't see it). A middleware turns that one response into the 422
  the spec wants. Nothing else in the app returns 400.
- **params.** Path, query and JSON body are merged into one symbol-keyed hash. Query parameters that must be
  strings (`limit`, `offset`, `tag`, ...) are type-checked, so `?tag[]=x` is ignored as Rails' `permit` would.
- **Query cache.** Rage turns Active Record's query cache on around every action. It is still never used:
  `query_cache: false` in `database.yml`, and Rage's pool hands out connections whose cache store belongs to
  the boot fiber and is never enabled. A debug-log run confirmed that every request queries Postgres.
- **YJIT and warm-up** are done in `config.ru` (`Process.warmup`, then `RubyVM::YJIT.enable`) before Iodine
  forks. This is what Rails' `config.yjit` and the Rails version's `preload.rb` do.
- **JSON.** Rage's `render json:` calls `to_json`, which Active Support routes through its own encoder (an
  encoder object per call, an `as_json` pass and HTML-entity escaping). `ApplicationController#render` hands
  Rage a string from `JSON.generate` instead: the same JSON values, 2-18x faster to encode, about 1% of a
  request's CPU. The only difference is that `<`, `>` and `&` are written as they are rather than as `\u` escapes.
- **No gzip.** Iodine doesn't compress, so nothing to turn off.
- **bcrypt** still runs on a short-lived thread (see `User#password=`). bcrypt releases the GVL with
  `rb_thread_call_without_gvl`, which Rage's `blocking_operation_pool` can't pick up, so the thread stays. An idle
  login takes about 42 ms, which is the hash itself.

## Rules

- Nothing is cached between requests. Every request reads from Postgres, and the per-request query cache never hits.
- Passwords are bcrypt cost 10 and every login checks the stored hash.
- Every request verifies the token's HS256 signature and `exp` with the jwt gem.
- Writes are committed before the response goes out. Creating an article is one transaction.
- Passes `test/run.sh` (197/197).

## Local results

This was on a Ryzen AI Max+ 395, with Postgres and the app pinned to 8 of its cores and the load generator on
16 other threads. Each probe is a 60 s ramp and then 90 s measured (the scorer measures 60 s), on the full seed.
The 40,000 and 42,000 probes ran just before the JSON change; the other rows are the code as submitted.

| Users | req/s | p95 | p99 | CPU (app + Postgres, of 8) | |
|--:|--:|--:|--:|---|---|
| 40,000 | 10,580 | 8 ms | 18 ms | 3.87 + 2.82 | pass |
| 42,000 | 11,135 | 12 ms | 46 ms | 4.04 + 3.02 | pass |
| 44,000 | 11,617 | 49 ms | 209 ms | 4.28 + 3.34 | pass |
| 46,000 | 11,277 | 3,224 ms | 7,828 ms | 4.43 + 3.32 | fail |
| 44,000 for 5 minutes | 11,180 | 293 ms | 3,883 ms | 4.32 + 3.43 | fail (p99) |
| 42,000 for 5 minutes | 11,113 | 19 ms | 69 ms | 4.11 + 3.25 | pass, 0 errors |

So the scorer's procedure gives 42,000 here: 44,000 passes a probe but not the 5-minute hold.

Under load the app uses about 370 µs of CPU per request and Postgres about 290 µs.

The Rails version, on the same box and setup, passed 32,000 users and failed 33,000, at about 600 µs of app CPU
and 330 µs of Postgres CPU per request. So the same app holds about 30% more users on Rage. The Rails README
guesses 11-13k for the real box; 30% more than that would be somewhere around 14-17k.

Iodine's workers share one listening socket, so keep-alive connections spread unevenly over them (near the limit
the busiest worker did about 1.7x the average). Giving each worker its own `SO_REUSEPORT` socket evened them out,
but cost more CPU per request and didn't raise the limit, so it isn't used.

## Build and run

```bash
sudo bash install.sh   # once: builds Ruby 4.0.9 into /opt/ruby-4.0.9
bash build.sh          # installs gems into ./vendor/bundle
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`WEB_CONCURRENCY` and `DB_POOL` override the worker count and pool size, and `RAGE_LOG_LEVEL=debug` logs every query.
