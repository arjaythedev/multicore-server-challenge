# Ruby + Rage + Sequel + YJIT

Front: direct

A port of [`ruby-rails-bottrall`](../ruby-rails-bottrall)'s Rails app to [Rage](https://rage-rb.dev) and
[Sequel](https://sequel.jeremyevans.net). It follows up on `ruby-rage-cloetzi`
([#162](https://github.com/arjaythedev/multicore-server-challenge/pull/162)), the same port on Active Record.

The point is to see how far Ruby on Rage can be pushed while it stays a realistic, tuned app that still feels
like Ruby: no hand-rolled SQL client, no C extensions of my own, no tricks a Ruby team wouldn't ship. It's still
an ORM app as you would run it in production: Sequel models with associations and validations, model datasets in
place of scopes, and Sequel's own prepared statements. There's no hand-written result parsing. The controllers,
routes, serializer, JWT code and request validation are the Active Record version's, changed only where Active
Record's API was used, and the SQL sent to Postgres is the same, statement for statement.

## Versions

| | |
|---|---|
| Ruby | 4.0.9, built from source by `install.sh` with YJIT and jemalloc (same `install.sh` as the Rage and Rails versions) |
| Framework | rage-rb 1.29.0 (standalone mode) |
| Server | rage-iodine 6.4.0 (facil.io, epoll), started by `rage s` |
| ORM | Sequel 5.109.0, with sequel_pg 1.20.0 (Sequel's C extension that builds rows and parses types in C) |
| Postgres driver | pg 1.7.0 |
| bcrypt | bcrypt 3.1.22, cost 10 |
| JWT | jwt 3.3.0 |
| JSON | json 3.1.0 |

Gems are pinned in `Gemfile.lock`, and `build.sh` compiles the native ones from source. Neither Active Record nor
Active Support is loaded.

## How it runs

The same as the Active Record version: `rage s` boots the app in the master, then Iodine forks one worker per
core, each a single thread with an event loop and a fiber per request.

- **Connections.** Sequel's `fiber_concurrency` extension keys the connection pool by fiber rather than thread.
  The pool (`timed_queue`, Sequel's default on Ruby >= 3.2) waits on a `Thread::Queue`, which yields to Rage's
  fiber scheduler, and pg's async API yields while Postgres works. A request holds a connection only while a query
  or transaction runs. Each worker gets `88 / workers` connections, as in the Active Record version.
- **Prepared statements.** Every hot read is built once at boot from model datasets and prepared with
  `Dataset#prepare`, so each one has a name (`article_by_slug`, `feed_page`, `comment_thread`, ...). The viewer,
  slug, limit and offset are `:$placeholders`, and each connection prepares a statement the first time it runs it.
  Writes use Sequel's normal dataset and model methods; model inserts and updates go through the
  `prepared_statements` plugin.
- **Forking.** The master reads the table schemas when it loads the models and then drops its connections
  (`Iodine.on_state(:pre_start) { DB.disconnect }`), so workers never share a socket.
- **Saves.** `Sequel::Model.use_transactions = false`: a single INSERT or UPDATE is atomic anyway, and the
  BEGIN/COMMIT around every save only added two round trips. `Article.publish` opens its own transaction.

## Code

```
app/models/            Sequel models; each one's prepared statements are constants next to the dataset they come from
app/models/article_listing.rb   the list endpoints: a prepared page and a prepared capped count per list
app/controllers/       the Active Record version's controllers, calling the models above
app/concerns/          token auth and request input (no ActiveSupport::Concern)
app/serializers/       ConduitJson, reading record[:column]
config/initializers/sequel.rb   connection, pool, extensions, model defaults
config/routes.rb       nested routes written out with `scope path:` (Rage's fallback inflector makes `articl`)
```

## Rules

- Nothing is cached between requests. Prepared statements cache plans, not data.
- Passwords are bcrypt cost 10 and every login checks the stored hash.
- Every request verifies the token's HS256 signature and `exp` with the jwt gem.
- Writes are committed before the response goes out. Creating an article is one transaction.
- Passes `test/run.sh` (197/197) on the dev seed and the full seed.

## Results on one host

Measured with the challenge's loadgen and search procedure (2-minute probes, then 5-minute holds stepping down 5%),
on a Ryzen AI Max+ 395 with the app and Postgres 18 pinned to the same 8 cores and the load generator on 8 others.
Postgres runs the challenge's settings for an 8-core box. This isn't the benchmark box, and numbers here run well
above the leaderboard's (`ruby-rails-bottrall` is at 10,000 there), so they're only good for comparing these
servers with each other.

| | limit (5-minute hold) | req/s | p99 | app µs / req | Postgres µs / req | app + Postgres cores |
|---|--:|--:|--:|--:|--:|--:|
| Rails + Falcon ([`ruby-rails-bottrall`](../ruby-rails-bottrall)) | 32,000 | 8,356 | 483 ms | 592 | 340 | 7.8 |
| Rage + Active Record ([#162](https://github.com/arjaythedev/multicore-server-challenge/pull/162)) | 42,000 | 11,113 | 69 ms | 369 | 293 | 7.4 |
| **Rage + Sequel (this one)** | **51,000** | 13,454 | 302 ms | 218 | 268 | 6.5 |

Both Rage limits passed their hold twice. Sequel's probes passed at 54,000 and failed at 56,000 (twice each),
and its hold at 54,000 failed (p95 886 ms).

**Where the gain comes from.** At the same load (32,000 users, both passing), Sequel cut the app's CPU per
request from 344 to 186 µs (−46%) against Active Record, and Postgres's stayed the same (237 and 233 µs).
`perf stat` on Postgres agrees: about 1.8 million instructions per request with either ORM, at the same ~5 GHz.
Same statements, same work.

**What limits it.** At 51,000 users the 8 cores still have about 1.5 to spare. The limit is Iodine's spread of
connections: the workers share one listening socket, so keep-alive connections pile up on some workers. With
Sequel the busiest worker does about 2.6x the average, and in the failed 54,000 hold it was using a whole core
while the quietest used 0.07.

## This and #162

[#162](https://github.com/arjaythedev/multicore-server-challenge/pull/162) is the same app on Active Record
(`ruby-rage-cloetzi`): it shows what the framework costs, this one what the ORM costs. I find both approaches
interesting, but I'd understand if only one of them gets merged. If so, #162 can be closed in favor of this one.
