#!/usr/bin/env bash
# Builds as a normal user -> _build/prod/rel/conduit. No Hex dependencies: OTP, Elixir and a C compiler only.
set -euo pipefail
cd "$(dirname "$0")"
export MIX_ENV=prod LANG=C.UTF-8
ERTS_INCLUDE="$(erl -noshell -eval 'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')"
case "$(uname -s)" in Darwin) LINK="-bundle -undefined dynamic_lookup" ;; *) LINK="-shared" ;; esac
mkdir -p priv
# bcrypt NIF: the Openwall core + 2-4 lane interleaving (c_src/README.md)
cc ${CFLAGS:--O3 -std=gnu11} -fPIC -Wall -Wno-unused-function -I"$ERTS_INCLUDE" -Ic_src c_src/bcrypt_nif.c $LINK -o priv/bcrypt_nif.so
mix release conduit --overwrite --quiet
