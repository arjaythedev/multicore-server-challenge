#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: opam plus what the OCaml compiler and the C stubs need.
# build.sh builds the pinned compiler and libraries into a local opam root, as a normal user.
set -euo pipefail
apt-get update -q
apt-get install -y -q build-essential m4 pkg-config git unzip rsync curl ca-certificates opam libcrypt-dev libpq-dev
opam --version
