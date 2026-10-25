#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs a pinned JDK (Eclipse Temurin) and the sbt launcher under
# /opt/scala-netty. sbt itself, Scala and the libraries are pinned in the build and fetched by build.sh.
set -euo pipefail
JDK_VERSION=25.0.4.1+1
SBT_VERSION=1.13.0
SBT_SHA256=06806805ffd26232727326216766ed4793b549f8c1e6ffeef2e610db7245b698
case "$(uname -m)" in
  x86_64)  ARCH=x64;     JDK_SHA256=dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e ;;
  aarch64) ARCH=aarch64; JDK_SHA256=69df11a02cfa3ef7d7ca645e03edce6778ec090e100f6ae2b42097865730ac52 ;;
  *) echo "unsupported architecture: $(uname -m)"; exit 1 ;;
esac
OPT=/opt/scala-netty

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
jdk_file="OpenJDK25U-jdk_${ARCH}_linux_hotspot_${JDK_VERSION/+/_}.tar.gz"
curl -fsSL -o "$tmp/jdk.tar.gz" "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-${JDK_VERSION/+/%2B}/$jdk_file"
echo "$JDK_SHA256  $tmp/jdk.tar.gz" | sha256sum -c -
curl -fsSL -o "$tmp/sbt.tgz" "https://github.com/sbt/sbt/releases/download/v$SBT_VERSION/sbt-$SBT_VERSION.tgz"
echo "$SBT_SHA256  $tmp/sbt.tgz" | sha256sum -c -

rm -rf "$OPT" && mkdir -p "$OPT/jdk"
tar -xzf "$tmp/jdk.tar.gz" -C "$OPT/jdk" --strip-components=1
tar -xzf "$tmp/sbt.tgz" -C "$OPT"   # unpacks to $OPT/sbt
chmod -R a+rX "$OPT"
"$OPT/jdk/bin/java" -version
