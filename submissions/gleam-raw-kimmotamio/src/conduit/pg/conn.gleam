//// One Postgres connection = one BEAM process owning one socket. It serves requests from its mailbox one Sync
//// group at a time: every statement of a request is sent as Bind/Execute, then one Sync, so a multi-statement
//// request is one implicit transaction with one commit. Every statement in `sql.all()` is prepared once when
//// the connection opens. If the socket breaks the process reconnects and keeps serving.
////
//// A `Render` request ends here too: the rows are decoded, rendered to JSON and written to the client socket by
//// this process, so the response never crosses a process boundary and the connection process that asked keeps
//// a tiny heap.
////
//// Reads of one kind that are waiting here at the same moment go to Postgres as one batched statement (`sql`).
//// The read connections are grouped by statement kind so that what waits on one connection is mostly of one
//// kind, and when requests are arriving fast (the previous one came within two windows) a connection holds the
//// batch open for up to `batch_window` ms before sending it: most of a cheap statement's backend cost is
//// per-statement overhead, so a batch of four costs Postgres about half of four single statements.

import conduit/pg/proto.{type Param, type Row}
import conduit/response.{type Response}
import conduit/sql
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/string_tree.{type StringTree}

pub type Socket

pub type PgError {
  /// `code` is the SQLSTATE; "08000" stands for a lost connection.
  PgError(code: String, message: String)
}

pub type Reply =
  Result(List(List(Row)), PgError)

pub type Request {
  /// The results go back to `reply`. `deadline` is a monotonic millisecond timestamp: a request still queued past
  /// it is dropped with an error instead of being executed for a client that has already given up (the handler
  /// waits 10 s).
  Exec(deadline: Int, statements: List(#(Int, List(Param))), reply: Subject(Reply))
  /// The connection process renders the results with `render` and writes the HTTP response to the client socket
  /// itself; `notify` only hears how that went. It never blocks on the client (a busy socket hands the bytes
  /// back to the owner) and never writes past the deadline.
  Render(
    deadline: Int,
    statements: List(#(Int, List(Param))),
    render: fn(List(List(Row))) -> Response,
    sock: response.Socket,
    notify: Subject(Rendered),
  )
}

/// How a `Render` request ended.
pub type Rendered {
  Written
  /// The client socket was busy: here is the framed response for its owner to write.
  Busy(data: StringTree)
  /// The client socket failed.
  Gone
  /// `render` raised; the owner answers 500.
  Crashed
  /// The results arrived after the deadline, so nothing was written.
  Expired
  Failed(error: PgError)
}

pub type Config {
  Config(
    host: String,
    port: Int,
    user: String,
    password: String,
    database: String,
    options: String,
    /// How long (ms) to hold a batch open for company when requests are arriving fast; 0 never waits.
    batch_window: Int,
  )
}

@external(erlang, "conduit_ffi", "connect")
fn connect(host: String, port: Int, timeout: Int) -> Result(Socket, String)

@external(erlang, "conduit_ffi", "recv_timeout")
fn recv(sock: Socket, timeout: Int) -> Result(BitArray, Nil)

@external(erlang, "conduit_ffi", "send")
fn send(sock: Socket, data: BitArray) -> Result(Nil, Nil)

@external(erlang, "conduit_ffi", "close")
fn close(sock: Socket) -> Nil

@external(erlang, "conduit_ffi", "log")
fn log(msg: String) -> Nil

@external(erlang, "conduit_ffi", "sleep")
fn sleep(ms: Int) -> Nil

@external(erlang, "conduit_ffi", "stat_add")
fn stat_add(index: Int, n: Int) -> Nil

@external(erlang, "conduit_ffi", "monotonic_ms")
fn monotonic_ms() -> Int

@external(erlang, "conduit_ffi", "safe")
fn safe(f: fn() -> a) -> Result(a, Nil)

@external(erlang, "conduit_ffi", "hmac_sha256")
fn hmac(key: BitArray, data: BitArray) -> BitArray

@external(erlang, "conduit_ffi", "sha256")
fn sha256(data: BitArray) -> BitArray

@external(erlang, "conduit_ffi", "md5_hex")
fn md5_hex(data: BitArray) -> BitArray

@external(erlang, "conduit_ffi", "pbkdf2_sha256")
fn pbkdf2(password: BitArray, salt: BitArray, iterations: Int) -> BitArray

@external(erlang, "conduit_ffi", "random_bytes")
fn random_bytes(n: Int) -> BitArray

@external(erlang, "conduit_ffi", "xor_bytes")
fn xor_bytes(a: BitArray, b: BitArray) -> BitArray

/// Spawns the connection process; it sends its request subject to `register` once, before connecting.
pub fn start(config: Config, register: Subject(Subject(Request))) -> Nil {
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(register, subject)
    serve(config, subject, [], 0)
  })
  Nil
}

fn serve(config: Config, subject: Subject(Request), queue: List(Request), failures: Int) -> Nil {
  case open(config) {
    Ok(sock) -> loop(config, subject, sock, queue, 0)
    Error(reason) -> {
      case failures < 3 || failures % 20 == 0 {
        True -> log("postgres: " <> reason)
        False -> Nil
      }
      sleep(500)
      serve(config, subject, queue, failures + 1)
    }
  }
}

fn statement_name(index: Int) -> String {
  "s" <> int.to_string(index)
}

/// Requests drained from the mailbox beyond the one being served wait in `queue`, oldest first.
const drain_limit = 64

/// A batch this big is sent without waiting for more company.
const target_batch = 8

/// `last` is when the previous cycle started: a request arriving within two windows of it counts as fast traffic.
fn loop(config: Config, subject: Subject(Request), sock: Socket, queue: List(Request), last: Int) -> Nil {
  let #(first, queue) = case queue {
    [] -> #(process.receive_forever(subject), [])
    [head, ..rest] -> #(head, rest)
  }
  let now = monotonic_ms()
  let queue = drain(subject, queue, drain_limit - list.length(queue))
  let queue = case
    config.batch_window > 0
    && now - last <= 2 * config.batch_window
    && batch_key(first) != None
    && list.length(queue) < target_batch - 1
  {
    True -> collect(subject, queue, now + config.batch_window, target_batch - 1 - list.length(queue))
    False -> queue
  }
  case first.deadline < monotonic_ms() {
    True -> {
      stat_add(4, 1)
      complete(first, Error(PgError("57014", "queued too long")))
      loop(config, subject, sock, queue, now)
    }
    False -> serve_first(config, subject, sock, first, queue, now)
  }
}

fn serve_first(config: Config, subject: Subject(Request), sock: Socket, first: Request, queue: List(Request), now: Int) -> Nil {
  case batch_key(first) {
    // Not batched: a write or a multi-statement request is never retried, since its commit state would be
    // unknown; a read that has no batched form (the feed, the probes, the user lookups) is.
    None -> {
      stat_add(1, 1)
      let reads = list.all(first.statements, fn(s) { sql.read_only(s.0) })
      case run(sock, first.statements, [first], reads) {
        True -> loop(config, subject, sock, queue, now)
        False ->
          case reads {
            True -> reconnect(config, subject, sock, [first, ..queue])
            False -> reconnect(config, subject, sock, queue)
          }
      }
    }
    // Reads are retried on the reopened connection when this one turns out to be dead.
    Some(index) -> {
      let #(same, others) = list.partition(queue, fn(r) { batch_key(r) == Some(index) })
      let batch = [first, ..same]
      let ok = case same {
        [] -> {
          stat_add(1, 1)
          run(sock, first.statements, [first], True)
        }
        _ -> {
          stat_add(1, list.length(batch))
          stat_add(2, 1)
          stat_add(3, list.length(batch))
          let params =
            list.map(batch, fn(r) {
              case r.statements {
                [#(_, p)] -> p
                _ -> []
              }
            })
          run(sock, [#(index + sql.batch_offset, sql.batch_params(index, params))], batch, True)
        }
      }
      case ok {
        True -> loop(config, subject, sock, others, now)
        False -> reconnect(config, subject, sock, list.append(batch, others))
      }
    }
  }
}

fn reconnect(config: Config, subject: Subject(Request), sock: Socket, queue: List(Request)) -> Nil {
  close(sock)
  serve(config, subject, queue, 0)
}

/// The statement index when a request is a single batchable read.
fn batch_key(r: Request) -> Option(Int) {
  case r.statements {
    [#(index, _)] ->
      case sql.batchable(index) {
        True -> Some(index)
        False -> None
      }
    _ -> None
  }
}

fn drain(subject: Subject(Request), queue: List(Request), room: Int) -> List(Request) {
  case room <= 0 {
    True -> queue
    False ->
      case process.receive(subject, 0) {
        Ok(r) -> drain(subject, list.append(queue, [r]), room - 1)
        Error(_) -> queue
      }
  }
}

/// Waits for more requests until `until` (a monotonic ms) or `room` more have arrived.
fn collect(subject: Subject(Request), queue: List(Request), until: Int, room: Int) -> List(Request) {
  let remaining = until - monotonic_ms()
  case room <= 0 || remaining <= 0 {
    True -> queue
    False ->
      case process.receive(subject, remaining) {
        Ok(r) -> collect(subject, list.append(queue, [r]), until, room - 1)
        Error(_) -> queue
      }
  }
}

/// Sends one Sync group and completes the requests with the results. With several requests the statement is a
/// batched variant whose rows carry the request ordinal in their first column. Returns False when the connection
/// is gone; the requests are then answered with an error unless `retry` says the caller will run them again.
fn run(sock: Socket, statements: List(#(Int, List(Param))), requests: List(Request), retry: Bool) -> Bool {
  let message =
    list.map(statements, fn(s) {
      let #(index, params) = s
      <<proto.bind(statement_name(index), params):bits, proto.execute:bits>>
    })
    |> list.append([proto.sync])
    |> bit_array.concat
  let lost = fn() {
    case retry {
      True -> Nil
      False -> complete_all(requests, Error(PgError("08000", "connection lost")))
    }
    False
  }
  case send(sock, message) {
    Error(_) -> lost()
    Ok(_) ->
      case read_results(sock, <<>>, [], [], None) {
        Disconnected -> lost()
        Done(_, Some(error)) -> {
          complete_all(requests, Error(error))
          True
        }
        Done(results, None) -> {
          case requests {
            [r] -> complete(r, Ok(results))
            _ -> demux(results, requests)
          }
          True
        }
      }
  }
}

fn complete_all(requests: List(Request), result: Reply) -> Nil {
  list.each(requests, fn(r) { complete(r, result) })
}

/// Hands a request its result: to the requester for `Exec`; rendered and written to the client for `Render`.
fn complete(r: Request, result: Reply) -> Nil {
  case r {
    Exec(_, _, reply) -> process.send(reply, result)
    Render(deadline, _, render, sock, notify) ->
      case result {
        Error(e) -> process.send(notify, Failed(e))
        Ok(results) ->
          case safe(fn() { render(results) }) {
            Error(_) -> process.send(notify, Crashed)
            Ok(#(status, body)) ->
              case monotonic_ms() > deadline {
                True -> process.send(notify, Expired)
                False -> {
                  let data = response.render(status, body)
                  case response.send_nosuspend(sock, data) {
                    response.Sent -> process.send(notify, Written)
                    response.Busy -> process.send(notify, Busy(response.flatten(data)))
                    response.Gone -> process.send(notify, Gone)
                  }
                }
              }
          }
      }
  }
}

// Rows of a batched statement are grouped by their ordinal column, in order; a request with no rows gets [].
fn demux(results: List(List(Row)), requests: List(Request)) -> Nil {
  let rows = case results {
    [rows] -> rows
    _ -> []
  }
  let groups =
    list.fold(rows, dict.new(), fn(acc, row) {
      case row {
        [ordinal, ..rest] -> {
          let i = proto.col_int(ordinal)
          dict.upsert(acc, i, fn(existing) {
            case existing {
              Some(list) -> [rest, ..list]
              None -> [rest]
            }
          })
        }
        _ -> acc
      }
    })
  list.index_map(requests, fn(r, k) {
    let own = case dict.get(groups, k + 1) {
      Ok(list) -> list.reverse(list)
      Error(_) -> []
    }
    complete(r, Ok([own]))
  })
  Nil
}

type Outcome {
  Done(results: List(List(Row)), error: Option(PgError))
  Disconnected
}

/// Reads backend messages until ReadyForQuery. DataRows accumulate per statement; CommandComplete closes one.
fn read_results(
  sock: Socket,
  buf: BitArray,
  current: List(Row),
  results: List(List(Row)),
  error: Option(PgError),
) -> Outcome {
  case proto.next_message(buf) {
    Error(_) ->
      case recv(sock, 60_000) {
        Ok(data) -> read_results(sock, <<buf:bits, data:bits>>, current, results, error)
        Error(_) -> Disconnected
      }
    Ok(#(tag, payload, rest)) ->
      case tag {
        // 'D' DataRow
        68 -> read_results(sock, rest, [proto.data_row(payload), ..current], results, error)
        // 'C' CommandComplete
        67 -> read_results(sock, rest, [], [list.reverse(current), ..results], error)
        // 'E' ErrorResponse: the rest of the Sync group is skipped by the backend
        69 -> {
          let #(code, msg) = proto.error_fields(payload)
          read_results(sock, rest, [], results, Some(PgError(code, msg)))
        }
        // 'Z' ReadyForQuery
        90 -> Done(list.reverse(results), error)
        // '1' ParseComplete, '2' BindComplete, 'N' Notice, 's' PortalSuspended, 'n' NoData, 'I' EmptyQuery, 'S'/'K'
        _ -> read_results(sock, rest, current, results, error)
      }
  }
}

// ---------------------------------------------------------------- startup

fn open(config: Config) -> Result(Socket, String) {
  case connect(config.host, config.port, 5000) {
    Error(e) -> Error("connect: " <> e)
    Ok(sock) -> {
      let result = {
        case send(sock, proto.startup(config.user, config.database, config.options)) {
          Error(_) -> Error("startup: send failed")
          Ok(_) ->
            case authenticate(sock, config, <<>>, None) {
              Error(e) -> Error(e)
              Ok(_) -> prepare_all(sock)
            }
        }
      }
      case result {
        Ok(_) -> Ok(sock)
        Error(e) -> {
          close(sock)
          Error(e)
        }
      }
    }
  }
}

type Scram {
  Scram(nonce: BitArray, client_first_bare: BitArray)
}

/// Drives authentication (trust, cleartext, md5, SCRAM-SHA-256) until the first ReadyForQuery.
fn authenticate(
  sock: Socket,
  config: Config,
  buf: BitArray,
  scram: Option(Scram),
) -> Result(Nil, String) {
  case proto.next_message(buf) {
    Error(_) ->
      case recv(sock, 10_000) {
        Ok(data) -> authenticate(sock, config, <<buf:bits, data:bits>>, scram)
        Error(_) -> Error("auth: connection closed")
      }
    Ok(#(tag, payload, rest)) ->
      case tag {
        // 'R' Authentication*
        82 ->
          case payload {
            <<0:size(32)>> -> authenticate(sock, config, rest, scram)
            <<3:size(32)>> -> {
              let _ = send(sock, proto.password_message(<<config.password:utf8>>))
              authenticate(sock, config, rest, scram)
            }
            <<5:size(32), salt:bytes-size(4)>> -> {
              let inner = md5_hex(<<config.password:utf8, config.user:utf8>>)
              let outer = md5_hex(<<inner:bits, salt:bits>>)
              let _ = send(sock, proto.password_message(<<"md5":utf8, outer:bits>>))
              authenticate(sock, config, rest, scram)
            }
            <<10:size(32), mechanisms:bytes>> -> {
              case string.contains(bit_array.to_string(mechanisms) |> unwrap_or(""), "SCRAM-SHA-256") {
                False -> Error("auth: unsupported SASL mechanisms")
                True -> {
                  let nonce = bit_array.base64_encode(random_bytes(18), False)
                  let bare = <<"n=,r=":utf8, nonce:utf8>>
                  let _ = send(sock, proto.sasl_initial("SCRAM-SHA-256", <<"n,,":utf8, bare:bits>>))
                  authenticate(sock, config, rest, Some(Scram(<<nonce:utf8>>, bare)))
                }
              }
            }
            <<11:size(32), server_first:bytes>> ->
              case scram {
                None -> Error("auth: unexpected SASL continue")
                Some(Scram(nonce, bare)) ->
                  case scram_final(config.password, nonce, bare, server_first) {
                    Error(e) -> Error(e)
                    Ok(final) -> {
                      let _ = send(sock, proto.sasl_response(final))
                      authenticate(sock, config, rest, scram)
                    }
                  }
              }
            <<12:size(32), _:bytes>> -> authenticate(sock, config, rest, scram)
            _ -> Error("auth: unsupported authentication method")
          }
        // 'E'
        69 -> {
          let #(code, msg) = proto.error_fields(payload)
          Error("auth: " <> code <> " " <> msg)
        }
        // 'Z'
        90 -> Ok(Nil)
        _ -> authenticate(sock, config, rest, scram)
      }
  }
}

fn scram_final(
  password: String,
  nonce: BitArray,
  bare: BitArray,
  server_first: BitArray,
) -> Result(BitArray, String) {
  let text = bit_array.to_string(server_first) |> unwrap_or("")
  let fields = string.split(text, ",")
  let get = fn(prefix: String) -> Result(String, Nil) {
    list.find_map(fields, fn(f) {
      case string.starts_with(f, prefix) {
        True -> Ok(string.drop_start(f, string.length(prefix)))
        False -> Error(Nil)
      }
    })
  }
  case get("r="), get("s="), get("i=") {
    Ok(combined), Ok(salt_b64), Ok(iters) ->
      case bit_array.starts_with(<<combined:utf8>>, nonce), bit_array.base64_decode(salt_b64), int.parse(iters) {
        True, Ok(salt), Ok(iterations) -> {
          let salted = pbkdf2(<<password:utf8>>, salt, iterations)
          let client_key = hmac(salted, <<"Client Key":utf8>>)
          let stored_key = sha256(client_key)
          let without_proof = <<"c=biws,r=":utf8, combined:utf8>>
          let auth_message = <<bare:bits, ",":utf8, server_first:bits, ",":utf8, without_proof:bits>>
          let signature = hmac(stored_key, auth_message)
          let proof = xor_bytes(client_key, signature)
          Ok(<<without_proof:bits, ",p=":utf8, bit_array.base64_encode(proof, True):utf8>>)
        }
        _, _, _ -> Error("auth: bad SCRAM server-first message")
      }
    _, _, _ -> Error("auth: bad SCRAM server-first message")
  }
}

fn prepare_all(sock: Socket) -> Result(Nil, String) {
  let message =
    list.map(list.append(sql.all(), sql.batched()), fn(s) { proto.parse(statement_name(s.index), s.query, s.params) })
    |> list.append([proto.sync])
    |> bit_array.concat
  case send(sock, message) {
    Error(_) -> Error("prepare: send failed")
    Ok(_) ->
      case read_results(sock, <<>>, [], [], None) {
        Disconnected -> Error("prepare: connection closed")
        Done(_, Some(PgError(code, msg))) -> Error("prepare: " <> code <> " " <> msg)
        Done(_, None) -> Ok(Nil)
      }
  }
}

fn unwrap_or(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}
