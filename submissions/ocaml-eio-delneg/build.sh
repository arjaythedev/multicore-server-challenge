#!/usr/bin/env bash
# Builds bin/conduit as a normal user, with the OCaml switch install.sh put in /opt/ocaml-mc.
set -euo pipefail
cd "$(dirname "$0")"
SW=${OCAML_SWITCH_PREFIX:-/opt/ocaml-mc/mc}
export OPAM_SWITCH_PREFIX="$SW" PATH="$SW/bin:$PATH"
dune build --profile release --root . ./src/main.exe
mkdir -p bin && install -m 755 _build/default/src/main.exe bin/conduit
