# Ruby on Rails

Front: nginx

| | |
|---|---|
| Language | Ruby 4.0.0 (built from the official tarball by `install.sh`) |
| Framework | Rails 8.1 in API mode |
| Server | Puma 8 (clustered: one worker per core, 5 threads each) |
| Postgres driver | pg 1.7 (through Active Record) |

A plain Rails app: controllers, models and Active Record, run behind Nginx. The point of this entry is to see how
far an ordinary Rails app gets on 8 cores, so it isn't tuned yet.

## How it's built

- **Rails API mode**, with the challenge's fixed schema used as-is: no migrations. The models (`User`, `Article`,
  `Tag`, `Follow`, `Favorite`, `Comment`) map straight onto the existing tables, including the composite primary
  keys on `follows` and `favorites`.
- **Simple endpoints use Active Record** (users, profiles, follows, favourites, deletes).
- **Article lists, the feed and comment lists run the spec's reference SQL** through `select_all` with binds
  (`app/queries/article_query.rb`). Each list row needs a favourites count, "favorited" and "following", and the
  paging and 1,000-capped counts have to match the reference exactly, so the reference SQL is the simplest
  correct way to get them.
- **Auth** is the `jwt` gem (HS256 only, `exp` required, checked on every request) and the `bcrypt` gem at cost 10.
  `has_secure_password` isn't used because the column is `password_hash`, not `password_digest`.

## Settings that differ from Rails defaults (and why)

- `wrap_parameters false`: otherwise Rails wraps a bare JSON body under the controller's name, and the
  "missing wrapper" requests would succeed instead of being 422s.
- `config.action_dispatch.perform_deep_munge = false`: Rails turns `[null]` into `[]` by default, and the spec
  needs a `tagList` of `[null]` to be rejected.
- Malformed JSON is a 422 (Rails' default is 400), and unknown routes get a JSON 404 instead of an HTML page.
- Puma's `persistent_timeout` is 65 s, as the spec asks, so Nginx never reuses a connection Puma just closed.
- `force_ssl`/`assume_ssl` are off: the app is behind Nginx on plain HTTP.

## Optimizations

Configuration only so far; the application code is unchanged.

- **One Puma worker per core.** Ruby's global VM lock lets one process run Ruby on only one core at a time, so a
  single Puma process would use about one of the 8 cores. `start.sh` sets `WEB_CONCURRENCY` to the core count.
- **5 threads per worker.** Most of a request is spent waiting on Postgres, which releases the lock, so a few
  threads per worker keep each core busy. 8 workers x 5 threads = 40 Postgres connections, under the 95 limit;
  `config/puma.rb` refuses to start if a setting would go over it.
- **`preload_app!`.** Rails boots once and the workers are forked from it, so they share memory.
- **YJIT.** `install.sh` installs `rustc` so Ruby is built with YJIT, which Rails 8 enables automatically.
- **Log level `warn`.** Request logging at this request rate costs measurable CPU.
