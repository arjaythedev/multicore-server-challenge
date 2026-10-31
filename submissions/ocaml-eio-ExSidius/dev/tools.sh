#!/usr/bin/env bash
# Runs a command with the local tooling on PATH: Go (conformance, loadgen, seedgen), Postgres 18, and libxcrypt and
# libpq for Nix's gcc wrapper, which doesn't see /usr/include. The benchmark box gets those from install.sh instead.
#   dev/tools.sh psql --version
#
# Store paths are resolved first and the command then runs without nix in its ancestry: nix's crash handler
# inherits stdout and outlives nix, so a pipeline reading `nix shell -c ...` output would never finish.
set -euo pipefail
. "$(dirname "$0")/env.sh"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
store_path() { nix build --no-link --print-out-paths "$1" </dev/null >"$out" 2>/dev/null; head -1 "$out"; }
go=$(store_path nixpkgs#go_1_27)
postgres=$(store_path nixpkgs#postgresql_18.out)
pg_config=$(store_path nixpkgs#postgresql_18.pg_config)
curl=$(store_path nixpkgs#curl.bin)
jq=$(store_path nixpkgs#jq.bin)
xcrypt=$(store_path nixpkgs#libxcrypt.out)
libpq=$(store_path nixpkgs#postgresql_18.lib)
libpq_dev=$(store_path nixpkgs#postgresql_18.dev)
rm -f "$out"
trap - EXIT
export PATH="$go/bin:$postgres/bin:$pg_config/bin:$curl/bin:$jq/bin:$PATH"
export PKG_CONFIG_PATH="$libpq_dev/lib/pkgconfig:$libpq/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export OPAMASSUMEDEPEXTS=1
flags="-I$xcrypt/include -I$libpq_dev/include"
ldflags="-L$xcrypt/lib -rpath $xcrypt/lib -L$libpq/lib -rpath $libpq/lib"
export NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1 NIX_BINTOOLS_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu=1
export NIX_CFLAGS_COMPILE="$flags ${NIX_CFLAGS_COMPILE:-}" NIX_CFLAGS_COMPILE_x86_64_unknown_linux_gnu="$flags"
export NIX_LDFLAGS="$ldflags" NIX_LDFLAGS_x86_64_unknown_linux_gnu="$ldflags"
exec "$@"
