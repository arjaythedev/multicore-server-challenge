//// An HTTP response: the status and the JSON body as iodata, framed with its `Content-Length`. Used by the
//// connection process that writes a response itself and by the Postgres connection process that writes one on
//// its behalf (see `conn.Render`).

import gleam/int
import gleam/string_tree.{type StringTree}

/// A client socket (`gen_tcp`). Any process may write to it; only its owner receives from it.
pub type Socket

pub type Response =
  #(Int, StringTree)

pub type SendResult {
  Sent
  /// The socket still holds an earlier response the client has not read: nothing was written, so the socket's
  /// owner can take over with a blocking write.
  Busy
  Gone
}

/// Writes, blocking on a slow client.
@external(erlang, "conduit_ffi", "send")
pub fn send(sock: Socket, data: StringTree) -> Result(Nil, Nil)

/// Writes unless the socket would make the caller wait.
@external(erlang, "conduit_ffi", "send_nosuspend")
pub fn send_nosuspend(sock: Socket, data: StringTree) -> SendResult

/// The same bytes as one binary (cheap to hand to another process).
@external(erlang, "erlang", "iolist_to_binary")
pub fn flatten(data: StringTree) -> StringTree

pub fn render(status: Int, body: StringTree) -> StringTree {
  case status {
    204 -> string_tree.from_string("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
    _ ->
      string_tree.from_strings([
        status_line(status),
        "Content-Type: application/json\r\nContent-Length: ",
        int.to_string(string_tree.byte_size(body)),
        "\r\n\r\n",
      ])
      |> string_tree.append_tree(body)
  }
}

fn status_line(status: Int) -> String {
  case status {
    200 -> "HTTP/1.1 200 OK\r\n"
    201 -> "HTTP/1.1 201 Created\r\n"
    400 -> "HTTP/1.1 400 Bad Request\r\n"
    401 -> "HTTP/1.1 401 Unauthorized\r\n"
    403 -> "HTTP/1.1 403 Forbidden\r\n"
    404 -> "HTTP/1.1 404 Not Found\r\n"
    422 -> "HTTP/1.1 422 Unprocessable Entity\r\n"
    503 -> "HTTP/1.1 503 Service Unavailable\r\n"
    _ -> "HTTP/1.1 500 Internal Server Error\r\n"
  }
}
