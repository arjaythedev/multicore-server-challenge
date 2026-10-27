defmodule Conduit.HttpTest do
  use ExUnit.Case, async: false

  setup do
    pid = start_supervised!({Conduit.Http, host: "127.0.0.1", port: 0, acceptors: 1})
    {:ok, {_ip, port}} = :inet.sockname(:sys.get_state(pid))
    %{port: port}
  end

  test "the complete header limit includes the request line and final CRLF", %{port: port} do
    for {size, status} <- [{16_384, 404}, {16_385, 431}] do
      sock = connect(port)
      :ok = :gen_tcp.send(sock, sized_head(size))
      assert {^status, ""} = response(sock)
      :gen_tcp.close(sock)
    end
  end

  test "many short headers cannot bypass the cumulative limit", %{port: port} do
    sock = connect(port)
    :ok = :gen_tcp.send(sock, ["GET /missing HTTP/1.1\r\n", String.duplicate("X-Noise: a\r\n", 2000), "\r\n"])
    assert {431, ""} = response(sock)
  end

  test "the cumulative limit survives fragmented input", %{port: port} do
    sock = connect(port)
    head = "GET /missing HTTP/1.1\r\n" <> String.duplicate("X-Noise: a\r\n", 2000) <> "\r\n"
    <<first::binary-size(15_000), rest::binary>> = head
    :ok = :gen_tcp.send(sock, first)
    assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 20)
    :ok = :gen_tcp.send(sock, rest)
    assert {431, ""} = response(sock)
  end

  test "oversized request lines and individual headers return 431", %{port: port} do
    requests = [
      ["GET /", String.duplicate("a", 20_000), " HTTP/1.1\r\n\r\n"],
      ["GET /missing HTTP/1.1\r\nX-Long: ", String.duplicate("a", 20_000), "\r\n\r\n"]
    ]

    for request <- requests do
      sock = connect(port)
      :ok = :gen_tcp.send(sock, request)
      assert {431, ""} = response(sock)
      :gen_tcp.close(sock)
    end
  end

  test "valid request fragments are retained across CRLF boundaries", %{port: port} do
    sock = connect(port)

    for fragment <- ["GET /miss", "ing HTTP/1.1\r", "\nHost: local\r", "\n\r"] do
      :ok = :gen_tcp.send(sock, fragment)
      assert {:error, :timeout} = :gen_tcp.recv(sock, 0, 20)
    end

    :ok = :gen_tcp.send(sock, "\n")
    assert {404, ""} = response(sock)
  end

  test "body bytes and a following request are excluded from the header budget", %{port: port} do
    sock = connect(port)
    body = String.duplicate("X-Body: value\r\n\r\n", 8192)
    :ok = :gen_tcp.send(sock, ["POST /missing HTTP/1.1\r\nContent-Length: ", Integer.to_string(byte_size(body)), "\r\n\r\n", body, sized_head(100)])
    assert {404, tail} = response(sock)
    assert {404, ""} = response(sock, tail)
  end

  test "each pipelined request has its own header budget", %{port: port} do
    sock = connect(port)
    :ok = :gen_tcp.send(sock, [sized_head(9000), sized_head(9000)])
    assert {404, tail} = response(sock)
    assert {404, ""} = response(sock, tail)
  end

  test "the body limit still rejects oversized bodies", %{port: port} do
    sock = connect(port)
    :ok = :gen_tcp.send(sock, "POST /missing HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n")
    assert {413, ""} = response(sock)
  end

  defp connect(port) do
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 3000)
    on_exit(fn -> :gen_tcp.close(sock) end)
    sock
  end

  defp sized_head(size) do
    prefix = "GET /missing HTTP/1.1\r\nX-Pad: "
    prefix <> String.duplicate("a", size - byte_size(prefix) - 4) <> "\r\n\r\n"
  end

  defp response(sock, buf \\ "") do
    case :binary.split(buf, "\r\n\r\n") do
      [<<"HTTP/1.1 ", status::binary-size(3), _::binary>> = head, rest] ->
        [_, size] = Regex.run(~r/Content-Length: (\d+)/, head)
        {_body, tail} = body(sock, rest, String.to_integer(size))
        {String.to_integer(status), tail}

      [_] ->
        {:ok, bytes} = :gen_tcp.recv(sock, 0, 3000)
        response(sock, buf <> bytes)
    end
  end

  defp body(_sock, buf, size) when byte_size(buf) >= size do
    <<body::binary-size(^size), tail::binary>> = buf
    {body, tail}
  end

  defp body(sock, buf, size) do
    {:ok, bytes} = :gen_tcp.recv(sock, 0, 3000)
    body(sock, buf <> bytes, size)
  end
end
