#!/usr/bin/env bash
# HTTP framing checks against a running server: keep-alive, pipelining, split reads, bad input.
#
#   bash tests/smoke.sh [port]        (needs curl and nc)
set -uo pipefail
PORT="${1:-3100}"
H=127.0.0.1
fail=0
check() {  # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     expected: $2"; echo "     got:      $3"; fail=1; fi
}
# Bodies have no trailing newline, so a pipelined response's status line can start mid-line.
statuses() { grep -aoE 'HTTP/1\.1 [0-9]+' | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//'; }

check "GET /api/tags" "200" "$(curl -s -o /dev/null -w '%{http_code}' http://$H:$PORT/api/tags)"
check "content-type" "application/json" "$(curl -s -o /dev/null -w '%{content_type}' http://$H:$PORT/api/tags)"
check "unknown path" "404" "$(curl -s -o /dev/null -w '%{http_code}' http://$H:$PORT/api/nope)"
check "keep-alive reuse" "1" "$(curl -sv http://$H:$PORT/api/tags http://$H:$PORT/api/tags 2>&1 | grep -c 'Re-using\|Reusing')"

check "pipelined x3" "200 404 200" "$(printf 'GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\nGET /api/x HTTP/1.1\r\nHost: x\r\n\r\nGET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | timeout 3 nc $H $PORT | statuses)"
check "split request line" "200" "$( (printf 'GET /api/ta'; sleep 0.2; printf 'gs HTTP/1.1\r\nHo'; sleep 0.2; printf 'st: x\r\nConnection: close\r\n\r\n') | timeout 3 nc $H $PORT | statuses)"
check "split body + pipelined" "404 200" "$( (printf 'POST /api/tags HTTP/1.1\r\nContent-Length: 10\r\n\r\n01234'; sleep 0.2; printf '56789GET /api/tags HTTP/1.1\r\nConnection: close\r\n\r\n') | timeout 3 nc $H $PORT | statuses)"
check "garbage" "400" "$(printf 'BLAH\r\n\r\n' | timeout 3 nc $H $PORT | statuses)"
check "chunked" "501" "$(printf 'POST /api/users HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n' | timeout 3 nc $H $PORT | statuses)"
check "huge header" "431" "$( (printf 'GET /api/tags HTTP/1.1\r\nX: '; head -c 20000 /dev/zero | tr '\0' a; printf '\r\n\r\n') | timeout 3 nc $H $PORT | statuses)"
check "HTTP/1.0 closes" "Connection: close" "$(printf 'GET /api/tags HTTP/1.0\r\n\r\n' | timeout 3 nc $H $PORT | grep -a '^Connection' | tr -d '\r')"
check "tags body shape" '{"tags":["' "$(curl -s http://$H:$PORT/api/tags | head -c 10)"
check "1000 keep-alive requests on one connection" "1000" "$(curl -s $(for i in $(seq 1000); do echo -n "http://$H:$PORT/api/tags "; done) | grep -o '"tags"' | wc -l | tr -d ' ')"
exit $fail
