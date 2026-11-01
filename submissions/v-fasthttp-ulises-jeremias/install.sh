#!/usr/bin/env bash
set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential pkg-config libpq-dev curl git ca-certificates
V_COMMIT=c36172591e766668cf8aa7cc307f05764b6a0d49
V_DIR="/opt/vlang-${V_COMMIT:0:8}"
if [ ! -x "$V_DIR/v" ]; then
	git clone https://github.com/vlang/v.git "$V_DIR"
	git -C "$V_DIR" checkout --detach "$V_COMMIT"
	make -C "$V_DIR"
fi
test "$(git -C "$V_DIR" rev-parse HEAD)" = "$V_COMMIT"
ln -sfn "$V_DIR/v" /usr/local/bin/v
