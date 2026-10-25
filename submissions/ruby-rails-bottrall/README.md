# Ruby on Rails 8.1 + Falcon + YJIT

Front: direct

I don't expect Rails to get anywhere near the top of this leaderboard. What I wanted to see is how a fairly normal Rails app holds up if you give it YJIT, Falcon and a few modest optimizations, the kind you'd be happy to keep in a codebase you actually have to maintain. It's ActiveRecord models and scopes, resourceful controllers and `has_secure_password`, and the app code is about 600 lines.

## Versions

| | |
|---|---|
| Ruby | 4.0.9, built from source by `install.sh` with YJIT and jemalloc |
| Rails | 8.1.4, API only (ActiveRecord and ActionController) |
| Server | Falcon 0.57.0 |
| Postgres driver | pg 1.7.0 |
| bcrypt | bcrypt 3.1.22 through `has_secure_password`, cost 10 |
| JWT | jwt 3.3.0 |

Gems are pinned in `Gemfile.lock`, and `build.sh` compiles the native ones from source.

## How it runs

Falcon boots Rails once and forks a worker per core, so the workers share the booted app's memory. Each worker is a single thread running an event loop with a fiber per connection. The pg gem hands control back to the event loop while a query is running, so one worker can keep its whole connection pool busy without threads. Rails is set to `isolation_level = :fiber` so per-request state like the leased connection stays with its request.

Each worker gets `90 / workers` database connections, which is 88 on the 8 core box. Falcon is configured not to restart crashed workers.

## Code

```
app/models/                     the models, plus ArticleListing for the five list variants
app/controllers/                one controller per resource
app/controllers/concerns/       token auth and request body validation
app/serializers/conduit_json.rb turns records into the API's JSON
lib/access_tokens.rb            JWT issue and verify
```

The queries are the reference SQL from `SPEC.md` written as ActiveRecord scopes. `Article.presented_for(viewer_id)` is `ARTICLE_LIST_SELECT`, and the list filters chain onto it:

```ruby
listing = ArticleListing.filtered(tag:, author:, favorited:, limit:, offset:)
render json: { articles: listing.articles_for(viewer_id).map { ConduitJson.article(it) },
               articlesCount: listing.total }
```

## Optimizations

All the numbers here are from my machine on the full seed (setup further down).

- YJIT is the biggest win by far. Running the same request mix in process, time per request went from 730 µs to 451 µs, and that includes time spent waiting on Postgres. Rails turns YJIT on after the app boots, so it only compiles code that runs while serving requests, and the forked workers inherit it.
- Every hot query is a prepared statement. ActiveRecord won't prepare a statement that has raw SQL in it, so the subqueries in the article projection go through a small `bound_sql` helper that keeps them preparable.
- The list filters use `= (subquery)` like the reference SQL does. ActiveRecord's `where(author_id: subquery)` generates `IN (subquery)`, and Postgres was planning that as a join that loaded every article by the author before applying the limit. Switching to `where_scalar` took the author list from 1,330 µs to 138 µs of database time per call and the tag list from 587 µs to 255 µs.
- No gzip. Falcon compresses responses by default, which was costing about 10% of each worker's CPU. Compression is optional here so I turned it off.
- bcrypt runs on its own thread. bcrypt releases the GVL, but that doesn't help much when the worker is a single threaded event loop, so a login used to stall every other request on that worker for around 40 ms. Now the hash runs on a short lived thread and only the request that needs it waits. With 16 logins at once on one worker, they finished in 239 ms instead of 748 ms.
- A bigger starting heap. Setting `RUBY_GC_HEAP_*_INIT_SLOTS` in `start.sh` roughly halved the time spent in GC. Going bigger than that didn't help.
- Some small Rails settings. I dropped middleware an API doesn't need (ETag, Runtime, RequestId, RemoteIp and the request logger) and turned off the query cache, since no request runs the same query twice. I also turned off `belongs_to_required_by_default`, because the foreign keys already cover it and otherwise every insert runs extra SELECTs. Computed columns are read with `record[:tag_list]`, because `record.tag_list` goes through `method_missing`.
- jemalloc as the allocator.

A couple of things I tried that didn't help:

- Nginx in front. It made the app slightly cheaper per request, but at 27k users p95 was 202 ms compared to 27 ms serving direct.
- Forcing generic query plans so Postgres stops re-planning the list queries. The generic plan for the global article list took 1.8 seconds.

## Rules

- Nothing is cached between requests. Every request reads from Postgres, and the per-request query cache is off as well.
- Passwords are bcrypt cost 10 and every login checks the stored hash. `has_secure_password` defaults to 12, so the cost is set explicitly.
- Every request verifies the token's HS256 signature and `exp` with the jwt gem.
- Writes are committed before the response goes out. Creating an article is one transaction.

## Local results

This was on a Ryzen 5 7600, with Postgres and the app pinned to 8 of its threads and the load generator on the other 4. Each run is a 60 s ramp and then 60 s measured, same as the scorer's probes.

| Users | req/s | p95 | p99 | CPU (app + Postgres, of 8) | |
|--:|--:|--:|--:|---|---|
| 20,000 | 5,303 | 5 ms | 25 ms | 3.05 + 1.49 | pass |
| 27,000 | 7,156 | 23 ms | 54 ms | 4.48 + 2.30 | pass |
| 29,000 | 7,284 | 557 ms | 738 ms | 5.18 + 2.61 | fail |
| 27,000 for 5 minutes | 7,138 | 46 ms | 123 ms | 4.60 + 2.44 | pass, 0 errors |

Under load the app uses about 600 µs of CPU per request and Postgres about 320 µs.

My machine is a lot faster per core than the benchmark box though. The Go example passes 30k users on my setup and scored 24k on the real box, and its CPU numbers on the leaderboard suggest each request costs roughly 2.5x more CPU there. If that holds for Ruby too, I'd guess this lands somewhere around 11-13k. We'll see.

## Build and run

```bash
sudo bash install.sh   # once: builds Ruby 4.0.9 into /opt/ruby-4.0.9
bash build.sh          # installs gems into ./vendor/bundle
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

`WEB_CONCURRENCY` and `DB_POOL` override the worker count and pool size.
