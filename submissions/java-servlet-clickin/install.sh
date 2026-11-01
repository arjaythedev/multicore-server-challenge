#!/usr/bin/env bash
set -euo pipefail
JDK=jdk-25.0.5+8
if [ -x /opt/jdk/bin/javac ] && /opt/jdk/bin/java -version 2>&1 | grep -q '"25.0.5"'; then
  echo "Temurin $JDK already installed"; exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates
case "$(uname -m)" in
  x86_64)  ARCH=x64;     SHA256=68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb ;;
  aarch64) ARCH=aarch64; SHA256=bb5b2ded252f21c6090cf780b0a408ad0d83bbb557e702955643557f13231880 ;;
  *) echo "unsupported architecture $(uname -m)"; exit 1 ;;
esac
URL="https://github.com/adoptium/temurin25-binaries/releases/download/${JDK/+/%2B}/OpenJDK25U-jdk_${ARCH}_linux_hotspot_25.0.5_8.tar.gz"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp"
echo "$SHA256  $tmp" | sha256sum -c -
rm -rf /opt/jdk
mkdir -p /opt/jdk
tar -xzf "$tmp" -C /opt/jdk --strip-components=1
/opt/jdk/bin/java -version
