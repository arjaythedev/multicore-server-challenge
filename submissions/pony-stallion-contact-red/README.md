# Pony: Stallion + libpq

Front: direct

## Current Stack

| Piece | Version |
|-------|---------|
| ponyc | 0.77.0  |
| libpq | system package |
| stallion | becc51753ec076fdda011f7f9d5c73a50e814368 |

## Installation and Testing

`DATABASE_URL` and `JWT_SECRET` are required. `HOST` defaults to `127.0.0.1`; `PORT` defaults to `3000`.

The binary's `--db-worker-count` option defaults the number of detected CPUs to maximum of 8 and accepts values from 1 through 95. This in combination with --ponymaxthreads means you can simulate the number of CPUS, and alter the number of Workers independently for benchmarking.

Production always uses 95 database connections, distributed as evenly as possible across those workers: for example - For 8 cores, you get seven pools of 12 and one of 11.

### Experimental password batching

`BCRYPT_MODE` defaults to `batch`, which sends password work to compute actors and interleaves two to four eligible jobs with cost 10 inside one native call. `scalar` uses the same actor pipeline with the existing scalar implementation. `inline` performs bcrypt in the connection actor. A lone job runs immediately through the scalar implementation; there is no timer or wait to fill a batch. Login still fetches the stored hash before verification. JWT validation does not use bcrypt.

`BCRYPT_WORKERS` defaults to the smaller of `3` and the scheduler count and must be a decimal integer from `1` through the smaller of `8` and the scheduler count. The value is validated in every mode. Each compute actor handles one native call at a time, including scalar fallbacks for other supported costs. These calls occupy Pony scheduler threads; no scheduler is reserved for HTTP or database work.

To run on eight CPUs, with the existing database and JWT environment configured:

```sh
taskset -c 0-7 env BCRYPT_MODE=batch BCRYPT_WORKERS=3 \
  ./bin/conduit --ponymaxthreads=8
```

The command above uses eight database workers sharing 95 connections. In asynchronous modes, a connection defers later application work while a password operation is pending, preserving the order in which pipelined requests submit their first SQL query. Accepted application events run before logical close and recipient cancellation. Database callbacks arriving after physical close are dropped, so dependent query chains may end there.

Pending password jobs, deferred requests and queued database results are unbounded; requests retain their full bodies until settlement or logical close. A selected scalar fallback can delay the other jobs in its call. Batching can increase individual request latency, and native CPU measurements do not establish a server throughput improvement.

## How we use multiple cores

### The Language (Provided for your ease)

Pony is an actor-based language that is designed to be correct and fast. It's main selling point is that it provides a way to safely share data between actors *without* copying, or using locks or semaphores, or other blocking operations. This is all enforced in the compiler - so no "data access" checking happens at runtime. Why? Speed!

Pony actors can't exit themselves and are not allowed to crash, so we never need to check if an actor exists before sending. Why? Speed!

Pony actors don't do synchronous messaging (think Elixir's GenServer.call). Why? synchronous operations are latency. Latency is slow. Speed!

## The Design

As I've mentioned a few times, Latency is the enemy of speed. We need to reduce the number of actors between the user and the data.  Here is our design:

![Connection and database worker architecture](https://raw.githubusercontent.com/contact-red/multicore-server-challenge/refs/heads/feat/pony-stallion-no-stdlib/submissions/pony-stallion-contact-red/connection-architecture.svg)

At startup we create X number of Database Workers, where X is the number of CPUs.  These are going to be the busiest actors in our system. Remember that actors serialize, and serialization is latency and latency kills speed.

If our number of database workers is less than the number of CPUs, we're leaving CPU on the table. Any more is a waste as you can only run X number of actors at an instant in time.

Each Database Actor makes (95/X)ish™ database connections per SPEC.md

A user hits the listener. The listener creates a new Client Connection per user.

On creation, the Client Connection actor is told about a single Database Worker and uses it for all its queries.

A query comes in, the database actor knows the State (Connecting / Authenticating / Idle / Busy etc…) for each connection it is responsible for, so immediately farms the query out right to an idle connection if available.  If all database connections are busy, it queues it.

If a database worker loses a connection, or has a connection error out - it disconnects it and reconnects it.

