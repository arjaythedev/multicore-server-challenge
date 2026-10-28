#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q  --no-install-recommends \
                                build-essential \
                                cmake            \
                                ninja-build       \
                                g++                \
                                libssl-dev          \
                                libgmp-dev           \
                                libpq-dev             \
                                libcrypt-dev           \
                                ca-certificates         \
                                libjsoncpp-dev           \
                                curl                      \
                                libjemalloc2               \
                                libjemalloc-dev             \
                                libuuid1                     \
                                uuid-dev                      \
                                zlib1g-dev                     \
    && rm -rf /var/lib/apt/lists/*

export CXXFLAGS="-march=native"
export CFLAGS="-march=native"

cd ~
git clone https://github.com/Thalhammer/jwt-cpp.git
mkdir -p /usr/local/include/picojson
cp jwt-cpp/include/picojson/picojson.h /usr/local/include/picojson/
cd jwt-cpp
git submodule update --init --recursive


cd ~
sudo cp -r jwt-cpp/include/jwt-cpp /usr/local/include/

git clone https://github.com/drogonframework/drogon.git && \
    cd drogon &&                     \
    git checkout 360980c9cd7205b94a0728a10eaa8cff19656977 && \
    git submodule update --init --recursive && \
    mkdir build && cd build &&         \
    cmake .. -DCMAKE_BUILD_TYPE=Release \
             -DBUILD_EXAMPLES=OFF        \
             -DBUILD_CTL=OFF              \
             -DBUILD_POSTGRESQL=ON         \
             -DBUILD_MYSQL=OFF              \
             -DBUILD_SQLITE3=OFF             \
             -DUSE_ORM=OFF                    \
             -DBUILD_REDIS=OFF                 \
             -DUSE_BROTLI=OFF                   \
             && make -j6 && make install && ldconfig