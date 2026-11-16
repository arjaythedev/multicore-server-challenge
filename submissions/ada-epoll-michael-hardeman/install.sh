#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: GNAT 15.2 and gprbuild 25.0 from Alire's GNAT-FSF-builds
# (the toolchain `alr` installs), sha256-pinned, into /opt. build.sh finds them there.
set -euo pipefail
apt-get update -q
apt-get install -y -q curl ca-certificates binutils libc6-dev
GNAT=gnat-x86_64-linux-15.2.0-1
GPR=gprbuild-x86_64-linux-25.0.0-1
BASE=https://github.com/alire-project/GNAT-FSF-builds/releases/download
fetch() {  # tarball, release tag, sha256
  curl -fsSLo "/tmp/$1.tar.gz" "$BASE/$2/$1.tar.gz"
  echo "$3  /tmp/$1.tar.gz" | sha256sum -c -
  rm -rf "/opt/$1" && tar -C /opt -xzf "/tmp/$1.tar.gz" && rm "/tmp/$1.tar.gz"
}
fetch "$GNAT" gnat-15.2.0-1 4640d4b369833947ab1a156753f4db0ecd44b0f14410b5b2bc2a14df496604bb
fetch "$GPR" gprbuild-25.0.0-1 9a2e6cfb9c4add85c7c411e95533c46728aae7de19a9a0b056abf53bd9795b0d
"/opt/$GNAT/bin/gnat" --version | head -1
"/opt/$GPR/bin/gprbuild" --version | head -1
