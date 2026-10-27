# PHP: Symfony 8.1 on Swoole

**Front: direct.** The PHP workers hold every user's keep-alive connection themselves on `HOST:PORT`; there is no
proxy in front.

All 19 endpoints are implemented using the reference SQL. The official conformance suite passes 197/197
on both the dev and full seeds.

## Aim

A Conduit API in PHP that is fast, and also something that could be run and kept up as a real service: hexagonal
layers with command and query handlers, checked by static analysis, and no tricks that only help a benchmark (nothing is
cached between requests, every token and password is checked in full, writes are committed before the response).

It is not the fastest design possible. Where speed and structure pulled apart, the structure stayed unless the cost
showed in measurements. Known limits: a worker is single-threaded, so any slow work added to a request would delay
that worker's other requests (password hashing runs in task workers for that reason); TLS needs a proxy in front; there
is no metrics endpoint.

| Piece | Version |
|---|---|
| Language | PHP 8.5.12, from the php.net tarball (sha256-checked) |
| Server | Swoole 6.2.0 (a PHP extension), built from its release tag, checked against its commit; one single-threaded event loop per worker process |
| Framework | Symfony 8.1 (`framework-bundle`, `runtime`, `console`), nothing else |
| Postgres driver | `ext-pgsql` (libpq), one connection per worker by default, which the worker's requests wait on without blocking each other, every statement prepared once per connection |
| Tokens | HS256 JSON Web Tokens, signed and verified in `src/Shared/Infrastructure/Security` (no library) |
| Passwords | `password_hash` / `password_verify`, bcrypt cost 10, in Swoole task workers |
| Composer | 2.10.3 |

`install.sh` installs and pins all of it. `build.sh` installs the production dependencies and builds the
production container. `start.sh` runs the server in the foreground.

## Run it

```bash
sudo bash install.sh        # once, on Ubuntu 24.04
bash build.sh
DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit JWT_SECRET=multicore-server-challenge \
  HOST=127.0.0.1 PORT=3000 bash start.sh
```

| Variable | Meaning |
|---|---|
| `DATABASE_URL`, `JWT_SECRET` | Required |
| `HOST`, `PORT` | Listen address (default `127.0.0.1:3000`; `0.0.0.0:80` to serve the internet directly) |
| `PHP_WORKERS` | Worker processes (default: the number of CPUs) |
| `PG_CONNECTIONS` | Postgres connections each worker keeps (default 1) |
| `PHP_TASK_WORKERS` | Processes that hash passwords for the workers (default: the number of CPUs) |

`PHP_WORKERS * PG_CONNECTIONS` is the number of connections the server holds. `start.sh` refuses to start above 90,
which leaves room under the box's limit of 95.

Every user's connection is an open file, so `start.sh` raises the soft limit on open files to the hard limit, and the
server holds as many connections as that allows, up to 200,000. Swoole also gives every connection a 64 KB receive
buffer from the worker's PHP heap, of which a request writes only the first few KB, so `php.ini` sets `memory_limit`
to 2G per worker: a worker holding 10,000 connections counts about 700 MB there and uses about 70 MB. A stop request
(SIGTERM or SIGINT to `start.sh`) is passed on to the server and repeated until it has stopped.

Every worker is a process that accepts connections on the shared port itself (`SO_REUSEPORT`) and stops only with the
server. A request that throws is answered with a JSON 500 and the worker carries on. If a worker dies anyway, the
server stops and `start.sh` exits with 1, instead of Swoole's manager starting a replacement.

## Test it

The tests and analysis tools are a separate Composer project in `tools/`, so that `build.sh` (which installs
without dev dependencies) never removes them. [Task](https://taskfile.dev) wraps the commands:

```bash
task install        # composer install here and in tools/
task seed-dev       # the challenge's 2% seed (conduit_dev); needs Postgres
task ci             # lint, PHPStan (maximum level, with architecture tests and custom rules), PHPMD, tests
task conformance    # the challenge's 197-check suite: ../../test/run.sh
TEMPLATE=conduit_seed task conformance   # the same suite against the full seed
```

`task test` runs unit tests and integration tests. The integration tests run against `conduit_phpunit`, a copy
of the dev seed that `task test-db` creates; each test runs inside a transaction that is rolled back.

Every statement that replaces one of SPEC.md's reference statements has an equivalence test. It runs the
reference statements, word for word from `tests/Support/ReferenceSql.php`, and the repository for the same
viewers, filters, pages and articles, and requires the same result. Set `TEST_DATABASE_URL` to a copy of the
full seed to run the tests against it.

## Development container

`.devcontainer/` builds Ubuntu 24.04 with `install.sh`, PostgreSQL 18 configured with the box's own
settings for 8 vCPU and 16 GB (`box/pg-conf.sh`, the `scram` login on `127.0.0.1`), and the tools the
challenge scripts need. Postgres starts with the container on `127.0.0.1:5432`; its data lives in a named
volume, so the full seed survives rebuilds. `PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres` is set, as
in CI. On a machine with less memory than the box, set `PG_SHARED_BUFFERS` (for example `1GB`) on the host
before opening the container.

## How the code is laid out

Modules under `src/Module/{User,Profile,Article,Comment,Tag}` each have `Domain` (models, views, repository ports),
`Application` (one use case per operation behind a read or write port, thin command and query handlers, results and
their mappers), `Interface/Http` (a controller per action, response objects and their mappers) and
`Infrastructure/Persistence/Pg` (repositories, and the mappers that turn a row into a view or a domain model; there
are no entities, because the SQL returns the shape the API shows). `src/Shared` holds what the modules share: the
caller context and the factory that builds it from the request, the policy attributes, the kernel that dispatches a
request and the responder that turns an exception into the JSON error body, the collection base classes and the
Postgres connection.

Dependencies point inward only, and PHPStan enforces it: `tests/Architecture` states the layer and module
boundaries, and five custom rules in `tests/PHPStan` check that every handler declares its authorization
and reads nothing, that mappers do not pass a maybe through, that a service keeps no state a later
request could read, and that everything translated from something else is built by the mapper named after it:
a result (`ProfileResultMapper::toResult()`), a response (`ProfileEnvelopeResponseMapper::toResponse()`), and the
views and domain models that repositories read from rows (`ArticleViewMapper::toView()`, `UserMapper::toDomain()`),
even a wrapper of one field.

Not used, on purpose: an ORM or query builder (the SQL is written out and prepared), the serializer and validator
components (request bodies are checked by hand, because the spec is exact about 422 against 400), the framework's
event dispatching and argument resolvers, an OpenAPI generator (`SPEC.md` is the contract), sessions, the security
bundle, and a transaction runner (single-statement writes commit directly; creating an article and its tags uses the
connection's transaction helper).

## Optimizations

- **Swoole.** The kernel boots once per worker. Swoole parses the request and writes the response inside the worker,
  so a request costs one pass through the event loop and no hop to another process or thread. Reference cycles are
  collected every 100 requests.
- **Waiting without blocking.** Each request runs in a coroutine. The worker sends a statement on one of its
  connections and waits for the answer on the socket in the event loop, serving its other requests meanwhile. A
  transaction keeps one connection for all of it.
- **Reads that wait share a statement.** A read that finds a connection free runs at once. One that finds them all busy
  joins the reads waiting, and the connection that comes free next serves those of one statement together, up to 32
  in one round trip. The statement is the single request's own, run once per request as a lateral subquery over
  arrays of their parameters, so each request gets exactly its own rows and nothing is shared or kept between
  requests. If a batch fails, its requests run one by one and only the one at fault is told.
- **Hashing off the event loop.** A bcrypt hash takes about 40 ms. Task workers do it, so the worker that received a
  login keeps answering its other requests meanwhile.
- **No TLS to Postgres.** The database is on this machine, so `start.sh` sets `PGSSLMODE=disable`.
- **Tracing JIT.** `opcache.jit = tracing` compiles the hot paths of the framework and of the application.
- **Prepared once.** Every statement is prepared once per connection and executed by name.
- **Planned once.** A connection sets `plan_cache_mode = force_generic_plan` and `jit = off` when it opens, so a
  statement is planned the first time it runs and the plan is kept. The statements are written so that the plan made
  without the parameter values is the right one: every table access is an index lookup.
- **One statement per read.** A list page and its capped count come back together, and so do an article's comments
  and the check that the article exists.
- **Page first, then the articles.** A list statement cuts the page as a list of ids, then reads each article of it
  with a lateral subquery (`OFFSET 0` keeps Postgres from turning that into a join over every article), so the work
  is done for the articles returned, not for the ones an offset skips.
- **Probes, not sets.** Whether the viewer favorited an article, or follows its author, is one primary-key lookup,
  not a read of the viewer's whole set. Tag names are looked up by id, one tag at a time.
- **Little converting.** A timestamp is kept in the text form the API shows it (`Moment`) instead of a date object,
  the whole tag list comes back as one array value, and the arrays Postgres writes without quotes are split at the
  commas.
- **Connections opened at start.** A worker opens its connections when it boots. A lost connection is dropped and
  reopened by the next call; a statement that changes data is not run a second time if its first attempt may have
  taken effect.
- **Authentication.** The token's signature is checked once per request with `hash_hmac` and `hash_equals`, its claims
  are read only after that, and nothing is cached between requests.
- **Its own kernel.** Only `FrameworkBundle`, a compiled container with its factories inlined, and attribute routes
  compiled at build time. `http_kernel` is replaced by `LeanHttpKernel`, which matches the route with the compiled
  matcher, gives each controller the request, the caller and the route's variables it declares, and turns a
  throwable into the JSON error body. The controllers are ordinary Symfony controllers.
- **Fixed response headers.** A response carries `Content-Type` and `Cache-Control: no-cache, private` as they are;
  Swoole adds the `Date`.

## How this was built

Built with Claude Opus 5.5, Claude Sonnet 5.5 and GPT-6.1-Sol, in a mix of manual review and automated trial and error:
changes were tried against the tests, the conformance suite and local load runs, and kept or dropped on the result.
