#!/usr/bin/env bash
# challenge.service's ExecStart: the launcher owns HOST:PORT and starts the engine's HTTP workers in Postgres.
cd "$(dirname "$0")"
exec ./launcher
