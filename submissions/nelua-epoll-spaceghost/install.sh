#!/usr/bin/env bash
set -euo pipefail
apt-get update -qq
apt-get install -y -qq build-essential git libpq-dev libssl-dev libcrypt-dev python3
