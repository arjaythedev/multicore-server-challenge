#!/usr/bin/env bash
# Runs nginx in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# One worker per core; each worker has a thread pool, and each thread one Postgres connection. Three threads per
# worker (24 connections on 8 cores) held more users than 6 or 11: with Postgres on the same cores, fewer busy
# backends means less contention. SQL_THREADS overrides it; the total stays within 95.
set -euo pipefail
cd "$(dirname "$0")"
: "${DATABASE_URL:?}" "${JWT_SECRET:?}" "${HOST:=0.0.0.0}" "${PORT:=80}"
WORKERS=${NGINX_WORKERS:-$(nproc)}
THREADS=${SQL_THREADS:-3}; [ $(( THREADS * WORKERS )) -gt 95 ] && THREADS=$(( 95 / WORKERS ))
BATCH_MAX=${SQL_BATCH_MAX:-128} BATCH_INFLIGHT=${SQL_BATCH_INFLIGHT:-1} BATCH_WAIT=${SQL_BATCH_WAIT:-20ms}

# HMAC-SHA256's two padded keys (RFC 2104) depend only on JWT_SECRET, so they are worked out once here and handed
# to the SQL as hex (sql/_hmac_keys.sql). The HMAC itself is still computed in SQL for every token.
if [ "$(printf %s "$JWT_SECRET" | wc -c)" -gt 64 ]; then
  KEY=$(printf %s "$JWT_SECRET" | sha256sum | cut -c1-64)
else
  KEY=$(printf %s "$JWT_SECRET" | od -An -v -tx1 | tr -d ' \n')
fi
while [ ${#KEY} -lt 128 ]; do KEY="${KEY}00"; done
JWT_HMAC_IPAD="" JWT_HMAC_OPAD=""
for (( i = 0; i < 128; i += 2 )); do
  JWT_HMAC_IPAD+=$(printf %02x $(( 0x${KEY:i:2} ^ 0x36 )))
  JWT_HMAC_OPAD+=$(printf %02x $(( 0x${KEY:i:2} ^ 0x5c )))
done
export JWT_HMAC_IPAD JWT_HMAC_OPAD
# Postgres is on 127.0.0.1. libpq's default sslmode=prefer would put TLS on every connection to a server with
# ssl = on (Ubuntu's default), encrypting every statement and result on both ends of the loopback.
export PGSSLMODE=${PGSSLMODE:-disable}

mkdir -p run
{
  [ "$(id -u)" = 0 ] && echo "user root;"     # started as root, nginx would drop its workers to "nobody"
  sed -e "s|__LISTEN__|$HOST:$PORT|" -e "s|__ROOT__|$PWD|g" -e "s|__WORKERS__|$WORKERS|" -e "s|__THREADS__|$THREADS|" \
      -e "s|__BATCH_MAX__|$BATCH_MAX|" -e "s|__BATCH_INFLIGHT__|$BATCH_INFLIGHT|" \
      -e "s|__BATCH_WAIT__|$BATCH_WAIT|" nginx.conf
} > run/nginx.conf
exec build/nginx/sbin/nginx -p "$PWD/run/" -c "$PWD/run/nginx.conf" -e stderr
