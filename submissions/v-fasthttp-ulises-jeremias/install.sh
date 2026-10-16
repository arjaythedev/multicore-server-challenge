#!/usr/bin/env bash
set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential pkg-config libpq-dev curl git ca-certificates
V_COMMIT=a8a9a3bec8804d37554826204140e42ae8c8ec4c
V_DIR="/opt/vlang-${V_COMMIT:0:8}"
if [ ! -x "$V_DIR/v" ]; then
	git clone https://github.com/vlang/v.git "$V_DIR"
	git -C "$V_DIR" checkout --detach "$V_COMMIT"
	make -C "$V_DIR"
fi
test "$(git -C "$V_DIR" rev-parse HEAD)" = "$V_COMMIT"
ln -sfn "$V_DIR/v" /usr/local/bin/v
