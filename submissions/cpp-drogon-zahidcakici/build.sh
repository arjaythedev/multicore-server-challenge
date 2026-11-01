#!/usr/bin/env bash
# Builds Drogon (and its trantor submodule) from pinned commits into build/deps, then the server into bin/conduit.
set -euo pipefail
cd "$(dirname "$0")"
DROGON_TAG=v1.9.14
DROGON_COMMIT=3aae769cc405cf5abb9d477675c6430924f02c7c
TRANTOR_COMMIT=78e480f5e138acdc05f76c55a2716718cd846364
STAMP="$DROGON_COMMIT-1"
JOBS="$(nproc)"
mkdir -p build bin

if [ "$(cat build/deps/.stamp 2>/dev/null)" != "$STAMP" ]; then
  rm -rf build/drogon build/drogon-build build/deps
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$DROGON_TAG" https://github.com/drogonframework/drogon.git build/drogon
  [ "$(git -C build/drogon rev-parse HEAD)" = "$DROGON_COMMIT" ] || { echo "drogon: unexpected commit"; exit 1; }
  git -C build/drogon submodule update -q --init --depth 1 trantor
  [ "$(git -C build/drogon/trantor rev-parse HEAD)" = "$TRANTOR_COMMIT" ] || { echo "trantor: unexpected commit"; exit 1; }
  # listen backlog SOMAXCONN (4096) -> 65535: the ramp connects tens of thousands of users at once
  sed -i 's/::listen(sockFd_, SOMAXCONN)/::listen(sockFd_, 65535)/' build/drogon/trantor/trantor/net/inner/Socket.cc
  grep -q '::listen(sockFd_, 65535)' build/drogon/trantor/trantor/net/inner/Socket.cc || { echo "trantor: backlog patch failed"; exit 1; }
  cmake -S build/drogon -B build/drogon-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/build/deps" \
    -DCMAKE_C_FLAGS="-O3 -march=native" -DCMAKE_CXX_FLAGS="-O3 -march=native" \
    -DBUILD_CTL=OFF -DBUILD_EXAMPLES=OFF -DBUILD_ORM=OFF -DBUILD_BROTLI=OFF -DBUILD_YAML_CONFIG=OFF \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF -DCMAKE_DISABLE_FIND_PACKAGE_c-ares=ON > /dev/null
  cmake --build build/drogon-build -j"$JOBS" > build/drogon-build.log 2>&1 || { tail -30 build/drogon-build.log; exit 1; }
  cmake --install build/drogon-build > /dev/null
  echo "$STAMP" > build/deps/.stamp
fi

cmake -S . -B build/app -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$PWD/build/deps" > /dev/null
cmake --build build/app -j"$JOBS"
install -m 755 build/app/conduit bin/conduit
echo "built bin/conduit"
