//// bcrypt cost 10 through the vendored OpenBSD implementation in native/, running as dirty-CPU NIFs.
////
//// Hashes are not computed one at a time: a collector process gathers the jobs that arrive within a short
//// window (up to four) and hands them to one NIF call that computes them in lockstep (native/bcrypt_lanes.c),
//// which overlaps the dependent S-box loads of independent hashes. Every hash still runs the full cost-10
//// schedule and produces the reference output; only the throughput changes. At a low rate a batch has one job.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}

@external(erlang, "bcrypt_nif", "gen_salt")
fn gen_salt(rounds: Int) -> BitArray

@external(erlang, "bcrypt_nif", "hashpw_lanes")
fn hashpw_lanes(jobs: List(#(BitArray, BitArray))) -> List(Result(BitArray, Nil))

@external(erlang, "conduit_ffi", "hash_equals")
fn hash_equals(a: BitArray, b: BitArray) -> Bool

@external(erlang, "conduit_ffi", "bcrypt_init")
fn register(collector: Subject(Message)) -> Nil

@external(erlang, "conduit_ffi", "bcrypt_collector")
fn collector() -> Subject(Message)

pub const cost = 10

pub type Message {
  Job(password: BitArray, salt: BitArray, reply: Subject(Result(BitArray, Nil)))
  Flush
}

/// Starts the collector; `window_ms` is how long the first job of a batch waits for company.
pub fn start(window_ms: Int) -> Nil {
  let parent = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(parent, subject)
    loop(subject, window_ms, [], None)
  })
  register(process.receive_forever(parent))
}

fn loop(subject: Subject(Message), window_ms: Int, pending: List(Message), timer: Option(process.Timer)) -> Nil {
  case process.receive_forever(subject) {
    Job(_, _, _) as job -> {
      let pending = [job, ..pending]
      case list.length(pending) >= 4 {
        True -> {
          case timer {
            Some(t) -> {
              process.cancel_timer(t)
              Nil
            }
            None -> Nil
          }
          flush(pending)
          loop(subject, window_ms, [], None)
        }
        False -> {
          let timer = case timer {
            Some(t) -> Some(t)
            None -> Some(process.send_after(subject, window_ms, Flush))
          }
          loop(subject, window_ms, pending, timer)
        }
      }
    }
    Flush -> {
      flush(pending)
      loop(subject, window_ms, [], None)
    }
  }
}

// The NIF call runs in its own process so the collector keeps collecting while a batch hashes.
fn flush(pending: List(Message)) -> Nil {
  case pending {
    [] -> Nil
    _ -> {
      let jobs = list.reverse(pending)
      process.spawn_unlinked(fn() {
        let inputs =
          list.map(jobs, fn(j) {
            let assert Job(password, salt, _) = j
            #(password, salt)
          })
        let results = hashpw_lanes(inputs)
        list.map2(jobs, results, fn(j, r) {
          let assert Job(_, _, reply) = j
          process.send(reply, r)
        })
      })
      Nil
    }
  }
}

fn run(password: BitArray, salt: BitArray) -> Result(BitArray, Nil) {
  let reply = process.new_subject()
  process.send(collector(), Job(password, salt, reply))
  case process.receive(reply, 10_000) {
    Ok(r) -> r
    Error(_) -> Error(Nil)
  }
}

pub fn hash(password: BitArray) -> Result(BitArray, Nil) {
  run(password, gen_salt(cost))
}

/// bcrypt only looks at the first 72 bytes; longer inputs are cut there like the reference implementations.
/// The stored hash is the salt: the computed hash must then equal it.
pub fn verify(password: BitArray, hash: BitArray) -> Bool {
  let password = case password {
    <<head:bytes-size(72), _:bytes>> -> head
    _ -> password
  }
  case run(password, hash) {
    Ok(computed) -> hash_equals(computed, hash)
    Error(_) -> False
  }
}
