#!/usr/bin/env bash
set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential pkg-config libpq-dev curl git ca-certificates
V_COMMIT=d67ee5500338554f54c7c8ca4cc00df42159577d
V_DIR="/opt/vlang-${V_COMMIT:0:8}"
if [ ! -x "$V_DIR/v" ]; then
	git clone https://github.com/vlang/v.git "$V_DIR"
	git -C "$V_DIR" checkout --detach "$V_COMMIT"
	make -C "$V_DIR"
fi
test "$(git -C "$V_DIR" rev-parse HEAD)" = "$V_COMMIT"
ln -sfn "$V_DIR/v" /usr/local/bin/v
