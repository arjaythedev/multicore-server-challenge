#!/usr/bin/env bash
# challenge.service's ExecStart: the launcher owns HOST:PORT and starts the engine's HTTP workers in Postgres.
cd "$(dirname "$0")"
# CI only: no local Postgres server, Postgres in a postgres:18 container (README "CI").
if C=$(bash ci.sh container); then exec bash ci.sh start "$C"; fi
exec ./launcher
