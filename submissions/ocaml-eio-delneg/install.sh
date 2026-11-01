#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: OCaml 5.5.2 and the pinned OCaml packages, in /opt/ocaml-mc.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential pkg-config m4 unzip patch git curl ca-certificates rsync bubblewrap libcrypt-dev

OPAM_VERSION=2.5.0
OPAM_SHA256=7aae51da01a66666c8733130852c2c00546eff486effb0999b78145cb75aee74
OPAM_REPO_COMMIT=2ffc3518756432a5bea7cda8ae467ea8b4e0362a   # ocaml/opam-repository, 2026-10-31
curl -fsSL -o /usr/local/bin/opam "https://github.com/ocaml/opam/releases/download/$OPAM_VERSION/opam-$OPAM_VERSION-x86_64-linux"
echo "$OPAM_SHA256  /usr/local/bin/opam" | sha256sum -c -
chmod 755 /usr/local/bin/opam

export OPAMROOT=/opt/ocaml-mc OPAMYES=1 OPAMCONFIRMLEVEL=unsafe-yes
opam init --bare --disable-sandboxing --no-setup default "git+https://github.com/ocaml/opam-repository#$OPAM_REPO_COMMIT"
opam switch create mc ocaml-base-compiler.5.5.2
opam install -y --switch=mc dune.3.24.2 eio.1.6 eio_linux.1.6 eio_main.1.6 uring.2.15.0 digestif.1.4.1 yojson.3.0.0 eqaf.0.10
chmod -R a+rX /opt/ocaml-mc
/opt/ocaml-mc/mc/bin/ocamlopt -version
