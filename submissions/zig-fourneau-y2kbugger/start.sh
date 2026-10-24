#!/usr/bin/env bash
# Runs the server in the foreground: DATABASE_URL, JWT_SECRET, HOST, PORT.
exec "$(dirname "$0")/bin/conduit"
