//// Entry point: reads the runtime contract from the environment, opens the Postgres connections, starts the
//// HTTP acceptors and then sleeps forever.

import conduit/bcrypt
import conduit/handler.{Ctx}
import conduit/http
import conduit/pg/conn.{type Config, Config}
import conduit/sql
import conduit/util
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string

@external(erlang, "conduit_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "conduit_ffi", "log")
fn log(msg: String) -> Nil

@external(erlang, "conduit_ffi", "pool_init")
fn pool_init(
  reads: List(process.Subject(conn.Request)),
  writes: List(process.Subject(conn.Request)),
  read_group_weights: List(Int),
) -> Nil

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "conduit_ffi", "stats")
fn stats() -> List(Int)

// STATS=1: log request/batch counters every 10 s (local experiments only).
fn stats_logger(previous: List(Int)) -> Nil {
  process.sleep(10_000)
  let current = stats()
  let delta = list.map2(current, previous, fn(a, b) { a - b })
  log("stats (10s): requests/batches/batched/expired = " <> string.join(list.map(delta, int.to_string), "/"))
  stats_logger(current)
}

fn env(name: String, default: String) -> String {
  case getenv(name) {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn env_int(name: String, default: Int) -> Int {
  case getenv(name) {
    Ok(v) ->
      case int.parse(v) {
        Ok(n) -> n
        Error(_) -> default
      }
    Error(_) -> default
  }
}

pub fn main() {
  let database_url = env("DATABASE_URL", "")
  let secret = env("JWT_SECRET", "")
  let host = env("HOST", "127.0.0.1")
  let port = env_int("PORT", 3000)
  let read_conns = env_int("DB_READ_CONNS", 12)
  let write_conns = env_int("DB_WRITE_CONNS", 8)
  let acceptors = env_int("ACCEPTORS", 16)
  let hibernate_words = env_int("HIB_WORDS", 2500)
  let min_heap_words = env_int("MIN_HEAP", 1598)
  let bcrypt_window = env_int("BCRYPT_BATCH_MS", 250)
  let batch_wait = env_int("BATCH_WAIT_MS", 2)
  case database_url == "" || secret == "" {
    True -> {
      log("DATABASE_URL and JWT_SECRET are required")
      halt(1)
    }
    False -> Nil
  }
  case read_conns + write_conns > 95 {
    True -> {
      log("refusing to open more than 95 Postgres connections")
      halt(1)
    }
    False -> Nil
  }
  let config = parse_database_url(database_url)
  bcrypt.start(bcrypt_window)

  // Read connections hold a batch open for BATCH_WAIT_MS when requests are coming in fast; writes never wait.
  let register = process.new_subject()
  list.each(list.repeat(Nil, read_conns), fn(_) { conn.start(Config(..config, batch_window: batch_wait), register) })
  let reads = list.map(list.repeat(Nil, read_conns), fn(_) { process.receive_forever(register) })
  list.each(list.repeat(Nil, write_conns), fn(_) { conn.start(Config(..config, batch_window: 0), register) })
  let writes = list.map(list.repeat(Nil, write_conns), fn(_) { process.receive_forever(register) })
  pool_init(reads, writes, sql.read_group_weights)

  case http.start(host, port, acceptors, Ctx(util.to_bits(secret), hibernate_words, min_heap_words)) {
    Ok(_) ->
      log(
        "conduit listening on " <> host <> ":" <> int.to_string(port) <> " with " <> int.to_string(read_conns)
        <> " read and " <> int.to_string(write_conns) <> " write connections",
      )
    Error(e) -> {
      log("listen failed: " <> e)
      halt(1)
    }
  }
  case env("STATS", "") {
    "" -> Nil
    _ -> {
      process.spawn_unlinked(fn() { stats_logger(stats()) })
      Nil
    }
  }
  process.sleep_forever()
}

/// postgres://user:password@host:port/database
fn parse_database_url(url: String) -> Config {
  let rest = case string.split_once(url, "://") {
    Ok(#(_, r)) -> r
    Error(_) -> url
  }
  let #(userinfo, hostpart) = case string.split_once(rest, "@") {
    Ok(#(u, h)) -> #(u, h)
    Error(_) -> #("", rest)
  }
  let #(user, password) = case string.split_once(userinfo, ":") {
    Ok(#(u, p)) -> #(u, p)
    Error(_) -> #(userinfo, "")
  }
  let #(hostport, database) = case string.split_once(hostpart, "/") {
    Ok(#(h, d)) -> #(h, d)
    Error(_) -> #(hostpart, "")
  }
  let database = case string.split_once(database, "?") {
    Ok(#(d, _)) -> d
    Error(_) -> database
  }
  let #(host, port) = case string.split_once(hostport, ":") {
    Ok(#(h, p)) ->
      case int.parse(p) {
        Ok(n) -> #(h, n)
        Error(_) -> #(h, 5432)
      }
    Error(_) -> #(hostport, 5432)
  }
  Config(
    host: host,
    port: port,
    user: pct(user),
    password: pct(password),
    database: database,
    options: "-c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off -c plan_cache_mode=force_generic_plan",
    batch_window: 0,
  )
}

fn pct(s: String) -> String {
  util.unsafe_to_string(util.pct_decode(util.to_bits(s), False))
}
