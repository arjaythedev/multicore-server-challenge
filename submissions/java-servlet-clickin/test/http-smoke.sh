#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
port="${PORT:-3000}"
host="${HOST:-127.0.0.1}"
base="http://${host}:${port}"
command -v nc >/dev/null || { echo 'nc is required' >&2; exit 1; }
body=$(curl -fsS "$base/api/tags")
[[ "$body" == '{"tags":[]}' ]]
async=$(curl -fsS -o /dev/null -w '%{http_code}' "$base/__async")
[[ "$async" == 200 ]]
dispatched=$(curl -fsS "$base/__async?dispatch")
[[ "$dispatched" == dispatched ]]
pipeline=$(printf 'GET /api/tags HTTP/1.1\r\nHost: localhost\r\n\r\nGET /api/tags HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' | timeout 10 nc "$host" "$port")
[[ $(printf '%s' "$pipeline" | grep -c 'HTTP/1.1 200 OK') == 2 ]]
[[ $(printf '%s' "$pipeline" | grep -o '{"tags":\[\]}' | wc -l | tr -d ' ') == 2 ]]
chunked=$(printf 'POST /__echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n' | timeout 10 nc "$host" "$port")
[[ "$chunked" == *'Wikipedia' ]]
[[ "$chunked" == *'Connection: close'* ]]
[[ "$chunked" == *"X-Remote: 127.0.0.1 $port"* ]]
head=$(printf 'HEAD /api/tags HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' | timeout 10 nc "$host" "$port")
[[ "$head" == *'Content-Length: 11'* ]]
[[ "$head" != *'{'* ]]
not_allowed=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$base/api/tags")
[[ "$not_allowed" == 405 ]]
echo 'HTTP smoke test passed'
