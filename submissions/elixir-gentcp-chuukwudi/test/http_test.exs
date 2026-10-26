defmodule Conduit.HTTPTest do
  use ExUnit.Case, async: true
  alias Conduit.HTTP

  test "a request with a body, and what follows it" do
    req =
      "POST /api/users HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nAuthorization: Token abc\r\nContent-Length: 4\r\n\r\nbodyGET /next"

    assert {:ok, "POST", "/api/users", "Token abc", "body", false, "GET /next"} = HTTP.parse(req)
  end

  test "partial requests wait for more" do
    assert :more = HTTP.parse("GET /api/tags HTTP/1.1\r\nHost: x\r\n")
    assert :more = HTTP.parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort")
  end

  test "header names are case-insensitive; Connection: close is honoured" do
    req = "GET /api/user HTTP/1.1\r\nauthorization: Token t\r\nCONNECTION: close\r\n\r\n"
    assert {:ok, "GET", "/api/user", "Token t", "", true, ""} = HTTP.parse(req)
    assert {:ok, _, _, nil, "", true, ""} = HTTP.parse("GET / HTTP/1.0\r\n\r\n")
  end

  test "bad framing" do
    assert {:error, 400} = HTTP.parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
    assert {:error, 400} = HTTP.parse("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n")
    assert {:error, 400} = HTTP.parse("NONSENSE\r\n\r\n")
  end
end
