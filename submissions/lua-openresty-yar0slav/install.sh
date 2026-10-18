#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs a pinned OpenResty (nginx + LuaJIT) from the official
# OpenResty apt repository. bcrypt comes from Ubuntu's libcrypt (libxcrypt), already on every Ubuntu box.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
OPENRESTY_VERSION=1.31.1.1-1~noble1

# The openresty package's postinst starts a system-wide OpenResty on port 80. On the benchmark box the box's own
# nginx already holds port 80, so that start fails and dpkg fails the whole install. Tell package scripts not to
# start services while we install (policy-rc.d exit 101), and finish any package an earlier run left half-configured.
if [ ! -e /usr/sbin/policy-rc.d ]; then
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d
  trap 'rm -f /usr/sbin/policy-rc.d' EXIT
fi
dpkg --configure -a

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg libcrypt1

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor --yes -o /etc/apt/keyrings/openresty.gpg
case "$(dpkg --print-architecture)" in
  amd64) repo=https://openresty.org/package/ubuntu ;;
  arm64) repo=https://openresty.org/package/arm64/ubuntu ;;
  *) echo "unsupported architecture"; exit 1 ;;
esac
echo "deb [signed-by=/etc/apt/keyrings/openresty.gpg] $repo noble main" > /etc/apt/sources.list.d/openresty.list
apt-get update
apt-get install -y --no-install-recommends "openresty=$OPENRESTY_VERSION"
apt-mark hold openresty

# start.sh runs its own OpenResty; keep the system-wide one from ever starting at boot
systemctl disable --now openresty 2>/dev/null || true
/usr/local/openresty/bin/openresty -v
