#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs build tools and dependencies.
set -euo pipefail
apt-get update -q && apt-get install -y -q build-essential liburing-dev libpq-dev libcrypt-dev
