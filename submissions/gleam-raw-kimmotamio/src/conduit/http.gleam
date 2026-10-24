//// A minimal HTTP/1.1 server on gen_tcp. Every connection is one process: the process that accepted it. It
//// parses with erlang:decode_packet (a C BIF) and runs the handler inline. For most requests the response is
//// rendered and written by the Postgres connection process that ran the query (`conn.Render`), so this process
//// never holds the rows or the JSON and its heap stays small; it writes the response itself only when there was
//// no query, on errors, or when the socket was busy. Between requests the process holds only the socket, and
//// hibernates if the last request grew its heap, so tens of thousands of idle keep-alive connections stay cheap.

import conduit/handler.{type Ctx}
import conduit/response.{type Socket}
import gleam/bit_array
import gleam/erlang/process
import gleam/string_tree

pub type Listener

pub type Parsed {
  Request(method: String, target: String, auth: String, body: BitArray, rest: BitArray, close: Bool)
  More
  Bad
}

@external(erlang, "conduit_ffi", "listen")
fn listen(host: String, port: Int) -> Result(Listener, String)

@external(erlang, "conduit_ffi", "accept")
fn accept(listener: Listener) -> Result(Socket, String)

@external(erlang, "conduit_ffi", "recv")
fn recv(sock: Socket) -> Result(BitArray, Nil)

@external(erlang, "conduit_ffi", "close")
fn close(sock: Socket) -> Nil

@external(erlang, "conduit_ffi", "parse_request")
fn parse_request(buf: BitArray) -> Parsed

@external(erlang, "conduit_ffi", "hibernate_http")
fn hibernate(sock: Socket, buf: BitArray, ctx: Ctx) -> Nil

@external(erlang, "conduit_ffi", "heap_words")
fn heap_words() -> Int

@external(erlang, "conduit_ffi", "mailbox_len")
fn mailbox_len() -> Int

@external(erlang, "conduit_ffi", "safe")
fn safe(f: fn() -> a) -> Result(a, Nil)

@external(erlang, "conduit_ffi", "sleep")
fn sleep(ms: Int) -> Nil

pub fn start(host: String, port: Int, acceptors: Int, ctx: Ctx) -> Result(Nil, String) {
  case listen(host, port) {
    Error(e) -> Error(e)
    Ok(listener) -> {
      spawn_acceptors(listener, acceptors, ctx)
      Ok(Nil)
    }
  }
}

fn spawn_acceptors(listener: Listener, n: Int, ctx: Ctx) -> Nil {
  case n {
    0 -> Nil
    _ -> {
      process.spawn_unlinked(fn() { acceptor(listener, ctx) })
      spawn_acceptors(listener, n - 1, ctx)
    }
  }
}

// The acceptor that gets a connection spawns its replacement and becomes the connection process.
fn acceptor(listener: Listener, ctx: Ctx) -> Nil {
  case accept(listener) {
    Ok(sock) -> {
      process.spawn_unlinked(fn() { acceptor(listener, ctx) })
      loop(sock, <<>>, ctx)
    }
    Error(_) -> {
      sleep(50)
      acceptor(listener, ctx)
    }
  }
}

/// Waits for the next socket message. Exported because the hibernate call re-enters here.
pub fn loop(sock: Socket, buf: BitArray, ctx: Ctx) -> Nil {
  case recv(sock) {
    Ok(data) ->
      case buf {
        <<>> -> handle(sock, data, ctx)
        _ -> handle(sock, bit_array.append(buf, data), ctx)
      }
    Error(_) -> close(sock)
  }
}

fn handle(sock: Socket, buf: BitArray, ctx: Ctx) -> Nil {
  case parse_request(buf) {
    More -> wait(sock, buf, ctx)
    Bad -> {
      let _ = response.send(sock, response.render(400, string_tree.from_string("{\"errors\":{\"body\":[\"bad request\"]}}")))
      close(sock)
    }
    Request(method, target, auth, body, rest, close_after) -> {
      let outcome = case safe(fn() { handler.handle(ctx, sock, method, target, auth, body) }) {
        Ok(outcome) -> outcome
        Error(_) -> handler.Reply(#(500, string_tree.from_string("{\"errors\":{\"body\":[\"internal error\"]}}")))
      }
      let written = case outcome {
        handler.Reply(#(status, body)) -> response.send(sock, response.render(status, body))
        handler.Prepared(data) -> response.send(sock, data)
        handler.Done -> Ok(Nil)
        handler.Broken -> Error(Nil)
        handler.ReplyAndClose(#(status, body)) -> {
          let _ = response.send(sock, response.render(status, body))
          Error(Nil)
        }
      }
      case written {
        Error(_) -> close(sock)
        Ok(_) ->
          case close_after {
            True -> close(sock)
            False -> handle(sock, rest, ctx)
          }
      }
    }
  }
}

// Avoid a full collection while the next request is already arriving.
fn wait(sock: Socket, buf: BitArray, ctx: Ctx) -> Nil {
  case buf == <<>> && heap_words() > ctx.hibernate_words && mailbox_len() == 0 {
    True -> hibernate(sock, buf, ctx)
    False -> loop(sock, buf, ctx)
  }
}
