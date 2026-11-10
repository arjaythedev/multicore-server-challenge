#!/usr/bin/env bash
# Builds a pinned OCaml toolchain into ./_opam-root (a few minutes, once), then the server.
set -euo pipefail
cd "$(dirname "$0")"
export OPAMROOT="$PWD/_opam-root" OPAMYES=1 OPAMCOLOR=never OPAMDOWNLOADJOBS=8
OPAM_REPO=git+https://github.com/ocaml/opam-repository.git#a1f0fcbd9384bce190ac51678bf1c2637a6a5cf4
PACKAGES="dune.3.24.2 eio_linux.1.6 yojson.3.0.0 digestif.1.4.1 postgresql.5.4.0 ppx_deriving_yojson.3.10.0"
if [ ! -d "$OPAMROOT/conduit" ]; then
  rm -rf "$OPAMROOT"
  opam init --bare --no-setup --disable-sandboxing default "$OPAM_REPO"
  opam switch create conduit ocaml-base-compiler.5.4.0
fi
if [ "$(cat "$OPAMROOT/.packages" 2>/dev/null)" != "$PACKAGES" ]; then
  opam install --switch=conduit $PACKAGES
  echo "$PACKAGES" > "$OPAMROOT/.packages"
fi
opam exec --switch=conduit -- dune build --release src/main.exe
