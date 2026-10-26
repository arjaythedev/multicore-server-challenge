#!/usr/bin/env bash
# Reads DATABASE_URL, JWT_SECRET, HOST and PORT; THREADS (worker threads = Postgres connections) is optional.
cd "$(dirname "$0")"
exec ./bin/conduit
