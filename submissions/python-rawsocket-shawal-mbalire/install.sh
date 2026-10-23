#!/usr/bin/env bash
set -euo pipefail

# Install Python 3.12+ and system build dependencies
apt-get update
apt-get install -y --no-install-recommends python3-pip python3-dev python3-venv build-essential libpq-dev
