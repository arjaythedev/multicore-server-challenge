#!/bin/sh
# Runs the server in the foreground, configured only by the environment.
cd "$(dirname "$0")"
exec bin/conduit
