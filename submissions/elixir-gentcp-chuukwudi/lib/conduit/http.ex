defmodule Conduit.HTTP do
  @moduledoc """
  A small HTTP/1.1 server on gen_tcp, made for tens of thousands of mostly idle keep-alive connections.

  * `acceptors` processes block in accept; one that gets a connection spawns its replacement and then *becomes*
    that connection's process (no ownership hand-off). The listen socket is `active: true`, so accepted sockets
    already deliver data as messages and a request costs no setopts call.
  * A connection is one small process that only frames requests; each request is served (JWT, a Postgres round
    trip, JSON, the send) by a short-lived worker with a preallocated heap (see process/3).
  * Requests are framed by Content-Length (what clients send for JSON bodies). Pipelined requests are served in
    order. Only the three headers the API needs are looked at: Authorization, Content-Length and Connection.

  (OTP's `:socket` NIF was measured as an alternative and cost more CPU per request than the inet driver here.)
  """
  alias Conduit.Handler

  @max_head 16_384
  @max_body 1_048_576

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(%{ip: ip, port: port, acceptors: n, worker_heap: heap}) do
    :persistent_term.put(:conduit_worker_heap, heap)

    opts = [
      :binary,
      packet: :raw,
      active: true,
      reuseaddr: true,
      nodelay: true,
      backlog: 65_535,
      ip: ip,
      send_timeout: 30_000,
      send_timeout_close: true
    ]

    {:ok, lsock} = :gen_tcp.listen(port, opts)
    pid = spawn_link(fn -> hold(lsock) end)
    :ok = :gen_tcp.controlling_process(lsock, pid)
    for _ <- 1..n, do: spawn_acceptor(lsock)
    {:ok, pid}
  end

  defp hold(lsock) do
    receive do
      _ -> hold(lsock)
    end
  end

  defp spawn_acceptor(lsock), do: :erlang.spawn(__MODULE__, :accept, [lsock])

  def accept(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn_acceptor(lsock)
        loop(sock, <<>>, nil)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(lsock)
    end
  end

  # ---------- connection ----------

  def loop(sock, buf, worker) do
    receive do
      {:tcp, ^sock, data} ->
        process(sock, if(buf == <<>>, do: data, else: buf <> data), worker)

      {:tcp_closed, ^sock} ->
        :ok

      {:tcp_error, ^sock, _} ->
        :gen_tcp.close(sock)

      _stray ->
        loop(sock, buf, worker)
    end
  end

  # Each request is served by a fresh worker process whose heap is preallocated large enough for a typical
  # request: it never garbage-collects, and its whole heap is freed in one go when it exits. The connection process
  # itself stays a few hundred words for its whole life and is not involved again until the client's next request. Responses stay in order: a request that arrives while the
  # previous worker is still running (pipelining) waits for it, and `Connection: close` closes after the response.
  defp process(sock, buf, worker) do
    case parse(buf) do
      {:ok, method, target, auth, body, close?, rest} ->
        await(worker)
        args = [sock, method, target, auth, body, close?]
        heap = {:min_heap_size, :persistent_term.get(:conduit_worker_heap)}

        if close? do
          {_, mref} = :erlang.spawn_opt(__MODULE__, :serve, args, [:monitor, heap])

          receive do
            {:DOWN, ^mref, :process, _, _} -> :gen_tcp.close(sock)
          end
        else
          pid = :erlang.spawn_opt(__MODULE__, :serve, args, [heap])
          # Hibernating here is cheap (this process only framed the request; its live data is the socket and the
          # worker pid) and leaves an idle connection at a few hundred bytes of heap.
          if rest == <<>>,
            do: :erlang.hibernate(__MODULE__, :loop, [sock, <<>>, pid]),
            else: process(sock, rest, pid)
        end

      :more ->
        loop(sock, buf, worker)

      {:error, status} ->
        await(worker)
        :gen_tcp.send(sock, response(status, Handler.error_body("bad request"), true))
        :gen_tcp.close(sock)
    end
  end

  defp await(nil), do: :ok

  defp await(pid) do
    if Process.alive?(pid) do
      mref = Process.monitor(pid)

      receive do
        {:DOWN, ^mref, :process, _, _} -> :ok
      end
    end

    :ok
  end

  def serve(sock, method, target, auth, body, close?) do
    {status, resp} = Handler.handle(method, target, auth, body)

    # Straight to the port (Proto.write/2), not gen_tcp.send/2: no socket-module lookup, no monitor, and no waiting
    # for the driver's inet_reply (this process is about to exit; the reply is dropped).
    Conduit.PG.Proto.write(sock, [response(status, resp, close?)])
  rescue
    ArgumentError -> exit(:send_failed)
  end

  # ---------- request parsing ----------

  def parse(buf) do
    case :binary.match(buf, "\r\n\r\n") do
      :nomatch ->
        if byte_size(buf) > @max_head, do: {:error, 431}, else: :more

      {pos, _} when pos > @max_head ->
        {:error, 431}

      {pos, _} ->
        head = binary_part(buf, 0, pos)

        case :binary.split(head, "\r\n", [:global]) do
          [line | headers] ->
            case :binary.split(line, " ", [:global]) do
              [method, target, version] ->
                {auth, clen, close?} = headers(headers, nil, 0, version != "HTTP/1.1")
                start = pos + 4
                avail = byte_size(buf) - start

                cond do
                  clen == :bad or clen > @max_body ->
                    {:error, 400}

                  avail < clen ->
                    :more

                  true ->
                    body = binary_part(buf, start, clen)
                    rest = binary_part(buf, start + clen, avail - clen)
                    {:ok, method, target, auth, body, close?, rest}
                end

              _ ->
                {:error, 400}
            end
        end
    end
  end

  # Canonical spellings first (what clients send); anything starting with a/A/c/C/t/T gets a case-insensitive look.
  defp headers([], auth, clen, close?), do: {auth, clen, close?}
  defp headers(["Authorization: " <> v | t], _, clen, c), do: headers(t, v, clen, c)
  defp headers(["Content-Length: " <> v | t], auth, _, c), do: headers(t, auth, int(v), c)
  defp headers(["Connection: " <> v | t], auth, clen, c), do: headers(t, auth, clen, conn_close(v, c))
  defp headers(["Accept" <> _ | t], auth, clen, c), do: headers(t, auth, clen, c)
  defp headers(["Content-Type: " <> _ | t], auth, clen, c), do: headers(t, auth, clen, c)

  defp headers([<<ch, _::binary>> = h | t], auth, clen, c) when ch in ~c"aAcCtT" do
    case :binary.split(h, ":") do
      [name, v] ->
        v = String.trim(v)

        case lower(name) do
          "authorization" -> headers(t, v, clen, c)
          "content-length" -> headers(t, auth, int(v), c)
          "connection" -> headers(t, auth, clen, conn_close(v, c))
          "transfer-encoding" -> headers(t, auth, :bad, c)
          _ -> headers(t, auth, clen, c)
        end

      _ ->
        headers(t, auth, clen, c)
    end
  end

  defp headers([_ | t], auth, clen, c), do: headers(t, auth, clen, c)

  defp int(v) do
    v = String.trim(v)
    if v != "" and Conduit.JWT.digits?(v) and byte_size(v) < 10, do: String.to_integer(v), else: :bad
  end

  defp conn_close(v, current) do
    case lower(String.trim(v)) do
      "close" -> true
      "keep-alive" -> false
      _ -> current
    end
  end

  defp lower(s), do: for(<<c <- s>>, into: <<>>, do: <<if(c in ?A..?Z, do: c + 32, else: c)>>)

  # ---------- responses ----------

  @lines %{
    200 => "200 OK",
    201 => "201 Created",
    204 => "204 No Content",
    400 => "400 Bad Request",
    401 => "401 Unauthorized",
    403 => "403 Forbidden",
    404 => "404 Not Found",
    422 => "422 Unprocessable Entity",
    431 => "431 Request Header Fields Too Large",
    500 => "500 Internal Server Error",
    503 => "503 Service Unavailable"
  }

  for {code, line} <- @lines do
    defp prefix(unquote(code)),
      do: unquote("HTTP/1.1 #{line}\r\nContent-Type: application/json\r\nContent-Length: ")
  end

  def response(204, _, false), do: "HTTP/1.1 204 No Content\r\n\r\n"
  def response(204, _, true), do: "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"

  def response(status, body, close?) do
    body = IO.iodata_to_binary(body)
    tail = if close?, do: "\r\nConnection: close\r\n\r\n", else: "\r\n\r\n"
    [prefix(status), Integer.to_string(byte_size(body)), tail, body]
  end
end
