defmodule Conduit.Http do
  @moduledoc false
  # A minimal HTTP/1.1 server on :gen_tcp. Every connection is one process: the process that accepted it. It parses
  # with :erlang.decode_packet (a C BIF), runs the handler inline and writes the response. Between requests the
  # process holds only a tiny state, and hibernates once idle (heap above HIB_WORDS, default 0: always), so tens of
  # thousands of idle keep-alive connections stay cheap. Hibernating after every request costs no measurable CPU, and
  # without it the heap allocator kept ~3.5 GB of carriers pinned by idle connections' last responses at 150k users
  # (RSS 4.7 GB -> 0.6-0.8 GB).

  use GenServer
  require Logger

  alias Conduit.Handler

  @max_head 16_384
  @max_body 1_048_576
  @decode_opts [packet_size: @max_head, line_length: @max_head]

  def child_spec(opts),
    do: %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, opts, []]}, type: :worker}

  @impl true
  def init(opts) do
    host = Keyword.fetch!(opts, :host)

    ip =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} ->
          ip

        _ ->
          {:ok, ip} = :inet.getaddr(String.to_charlist(host), :inet)
          ip
      end

    {:ok, lsock} =
      :gen_tcp.listen(Keyword.fetch!(opts, :port), [
        :binary,
        ip: ip,
        packet: :raw,
        active: true,
        reuseaddr: true,
        backlog: 65_535,
        nodelay: true,
        keepalive: true,
        send_timeout: 30_000,
        send_timeout_close: true
      ])

    hib_words =
      case System.get_env("HIB_WORDS", "0") do
        "off" -> :infinity
        v -> String.to_integer(v)
      end

    :persistent_term.put({__MODULE__, :hib_words}, hib_words)

    for _ <- 1..Keyword.fetch!(opts, :acceptors), do: spawn_acceptor(lsock)
    {:ok, lsock}
  end

  defp spawn_acceptor(lsock), do: :erlang.spawn(fn -> accept(lsock) end)

  defp accept(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn_acceptor(lsock)
        serve(sock)

      {:error, :closed} ->
        :ok

      {:error, reason} when reason in [:emfile, :enfile, :enobufs, :enomem] ->
        Process.sleep(50)
        accept(lsock)

      {:error, _} ->
        Process.sleep(50)
        accept(lsock)
    end
  end

  defp serve(sock) do
    hib = :persistent_term.get({__MODULE__, :hib_words})
    loop(sock, <<>>, hib)
  end

  # ------------------------------------------------------------------ connection loop

  def loop(sock, buf, hib) do
    receive do
      {:tcp, ^sock, data} -> data(sock, if(buf == <<>>, do: data, else: buf <> data), hib)
      {:tcp_closed, ^sock} -> :ok
      {:tcp_error, ^sock, _} -> :gen_tcp.close(sock)
    end
  end

  # Avoid a full collection while the next request is already arriving.
  defp wait(sock, buf, hib) do
    if buf == <<>> and hib != :infinity and heap_words() > hib and
         :erlang.process_info(self(), :message_queue_len) == {:message_queue_len, 0} do
      :erlang.hibernate(__MODULE__, :loop, [sock, buf, hib])
    else
      loop(sock, buf, hib)
    end
  end

  defp heap_words do
    {:total_heap_size, w} = :erlang.process_info(self(), :total_heap_size)
    w
  end

  defp data(sock, buf, hib) do
    case parse(buf) do
      :more ->
        wait(sock, buf, hib)

      {:ok, method, target, auth, close?, body, rest} ->
        {path, query} =
          case :binary.split(target, "?") do
            [p, q] -> {p, q}
            [p] -> {p, ""}
          end

        {status, resp} =
          try do
            Handler.handle(path, method, query, auth, body)
          catch
            kind, reason ->
              Logger.error("handler crashed: " <> Exception.format(kind, reason, __STACKTRACE__))
              {500, Conduit.Json.error("internal error")}
          end

        case :gen_tcp.send(sock, response(status, resp, close?)) do
          :ok when close? -> :gen_tcp.close(sock)
          :ok when rest == <<>> -> wait(sock, <<>>, hib)
          :ok -> data(sock, rest, hib)
          {:error, _} -> :gen_tcp.close(sock)
        end

      {:error, status} ->
        _ = :gen_tcp.send(sock, response(status, Conduit.Json.error("bad request"), true))
        :gen_tcp.close(sock)
    end
  end

  # ------------------------------------------------------------------ parsing

  defp parse(buf) do
    case :erlang.decode_packet(:http_bin, buf, @decode_opts) do
      {:ok, {:http_request, method, {:abs_path, target}, vsn}, rest} ->
        headers(
          rest,
          method,
          target,
          %{auth: nil, cl: 0, close: vsn == {1, 0}, chunked: false},
          byte_size(buf) - byte_size(rest)
        )

      {:more, _} when byte_size(buf) > @max_head ->
        {:error, 431}

      {:more, _} ->
        :more

      {:ok, {:http_request, _, _, _}, _} ->
        {:error, 400}

      _ ->
        head_error(buf, 0)
    end
  end

  defp headers(_buf, _method, _target, _acc, used) when used > @max_head, do: {:error, 431}

  defp headers(buf, method, target, acc, used) do
    case :erlang.decode_packet(:httph_bin, buf, @decode_opts) do
      {:ok, {:http_header, _, name, _, value}, rest} ->
        headers(
          rest,
          method,
          target,
          header(name, value, acc),
          used + byte_size(buf) - byte_size(rest)
        )

      {:ok, :http_eoh, rest} ->
        if used + byte_size(buf) - byte_size(rest) > @max_head,
          do: {:error, 431},
          else: body(rest, method, target, acc)

      {:more, _} when used + byte_size(buf) > @max_head ->
        {:error, 431}

      {:more, _} ->
        :more

      _ ->
        head_error(buf, used)
    end
  end

  defp head_error(buf, used) do
    line_size =
      case :binary.match(buf, "\n") do
        {pos, 1} -> pos + 1
        :nomatch -> byte_size(buf)
      end

    if used + line_size > @max_head, do: {:error, 431}, else: {:error, 400}
  end

  # The first Authorization header wins.
  defp header(:Authorization, v, %{auth: nil} = acc), do: %{acc | auth: v}

  defp header(:"Content-Length", v, acc) do
    case Conduit.Util.parse_digits(v) do
      n when is_integer(n) -> %{acc | cl: n}
      _ -> %{acc | cl: -1}
    end
  end

  defp header(:Connection, v, acc) do
    case String.downcase(v) do
      "close" -> %{acc | close: true}
      "keep-alive" -> %{acc | close: false}
      _ -> acc
    end
  end

  defp header(:"Transfer-Encoding", _v, acc), do: %{acc | chunked: true}
  defp header(_name, _v, acc), do: acc

  defp body(_rest, _m, _t, %{cl: cl}) when cl < 0 or cl > @max_body, do: {:error, 413}
  defp body(_rest, _m, _t, %{chunked: true}), do: {:error, 501}

  defp body(rest, method, target, %{cl: cl} = acc) do
    case rest do
      <<body::binary-size(^cl), tail::binary>> ->
        {:ok, method, target, acc.auth, acc.close, body, tail}

      _ ->
        :more
    end
  end

  # ------------------------------------------------------------------ responses

  defp response(204, _body, close?), do: ["HTTP/1.1 204 No Content\r\n", conn(close?), "\r\n"]

  defp response(status, body, close?) do
    [
      status_line(status),
      "Content-Length: ",
      Integer.to_string(:erlang.iolist_size(body)),
      "\r\n",
      conn(close?),
      "\r\n",
      body
    ]
  end

  defp conn(true), do: "Connection: close\r\n"
  defp conn(false), do: ""

  @ct "Content-Type: application/json\r\n"
  defp status_line(200), do: "HTTP/1.1 200 OK\r\n" <> @ct
  defp status_line(201), do: "HTTP/1.1 201 Created\r\n" <> @ct
  defp status_line(400), do: "HTTP/1.1 400 Bad Request\r\n" <> @ct
  defp status_line(401), do: "HTTP/1.1 401 Unauthorized\r\n" <> @ct
  defp status_line(403), do: "HTTP/1.1 403 Forbidden\r\n" <> @ct
  defp status_line(404), do: "HTTP/1.1 404 Not Found\r\n" <> @ct
  defp status_line(413), do: "HTTP/1.1 413 Payload Too Large\r\n" <> @ct
  defp status_line(422), do: "HTTP/1.1 422 Unprocessable Entity\r\n" <> @ct
  defp status_line(431), do: "HTTP/1.1 431 Request Header Fields Too Large\r\n" <> @ct
  defp status_line(500), do: "HTTP/1.1 500 Internal Server Error\r\n" <> @ct
  defp status_line(501), do: "HTTP/1.1 501 Not Implemented\r\n" <> @ct
  defp status_line(503), do: "HTTP/1.1 503 Service Unavailable\r\n" <> @ct
end
