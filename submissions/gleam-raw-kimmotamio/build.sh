#!/usr/bin/env bash
# Builds the NIFs and the Gleam release as a normal user. Dependencies are pinned by manifest.toml.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/usr/local/gleam/bin:/usr/local/otp/bin:$PATH"
ERTS_INCLUDE="$(erl -noshell -eval 'io:format("~s/usr/include", [code:root_dir()]), halt().')"
mkdir -p priv
CC="${CC:-cc}"
case "$(uname -s)" in
  Darwin) LDFLAGS_EXTRA="-undefined dynamic_lookup" ;;
  *) LDFLAGS_EXTRA="" ;;
esac
"$CC" -O3 -fPIC -shared -std=c99 -Wall -I"$ERTS_INCLUDE" $LDFLAGS_EXTRA \
  -o priv/bcrypt_nif.so native/bcrypt_nif.c native/bcrypt_lanes.c native/blowfish.c
"$CC" -O3 -fPIC -shared -std=c99 -Wall -I"$ERTS_INCLUDE" $LDFLAGS_EXTRA \
  -o priv/conduit_nif.so native/conduit_nif.c
gleam deps download
gleam build --target erlang
gleam export erlang-shipment
# The NIFs live next to the app's ebin in the shipment.
mkdir -p build/erlang-shipment/conduit/priv
cp priv/bcrypt_nif.so priv/conduit_nif.so build/erlang-shipment/conduit/priv/
echo "built build/erlang-shipment ($(gleam --version), OTP $(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().'))"
