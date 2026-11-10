#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs GraalVM JDK 25 and Apache Maven.
# Both tarballs are pinned and verified against their official published checksums.
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/java-netty-neeraj06152k}"

# Pinned official URLs and cryptographic checksums
GRAALVM_URL="https://download.oracle.com/graalvm/25/latest/graalvm-jdk-25_linux-x64_bin.tar.gz"
GRAALVM_SHA256="76007c309f821aaf435bce63162ea0395587fc77350801c81643fe7feea37276"

MAVEN_URL="https://archive.apache.org/dist/maven/maven-3/3.9.11/binaries/apache-maven-3.9.11-bin.tar.gz"
MAVEN_SHA512="bcfe4fe305c962ace56ac7b5fc7a08b87d5abd8b7e89027ab251069faebee516b0ded8961445d6d91ec1985dfe30f8153268843c89aa392733d1a3ec956c9978"

if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ca-certificates curl tar gzip libc6-dev jq
fi

download_and_verify() {
  local url="$1"
  local cmd="$2"
  local hash="$3"
  local dest="$4"
  local tmp
  tmp="$(mktemp -d)"
  echo "Downloading $url..."
  curl -fsSL -o "$tmp/archive.tar.gz" "$url"
  echo "$hash  $tmp/archive.tar.gz" | "$cmd" -c -
  rm -rf "$dest"
  mkdir -p "$dest"
  tar -xzf "$tmp/archive.tar.gz" -C "$dest" --strip-components=1
  rm -rf "$tmp"
}

if [ -x "$PREFIX/graalvm/bin/java" ] && "$PREFIX/graalvm/bin/java" -version 2>&1 | grep -q '25'; then
  echo "Java 25 already installed at $PREFIX/graalvm"
else
  download_and_verify "$GRAALVM_URL" sha256sum "$GRAALVM_SHA256" "$PREFIX/graalvm"
fi

if [ -x "$PREFIX/maven/bin/mvn" ] && JAVA_HOME="$PREFIX/graalvm" "$PREFIX/maven/bin/mvn" -v 2>/dev/null | grep -q "3.9.11"; then
  echo "Maven already installed at $PREFIX/maven"
else
  download_and_verify "$MAVEN_URL" sha512sum "$MAVEN_SHA512" "$PREFIX/maven"
fi

# Ensure all users can read and execute Java and Maven binaries
chmod -R a+rX "$PREFIX"

# Create standard symlinks in /usr/local/bin for system PATH discovery if writable
if [ -w /usr/local/bin ]; then
  mkdir -p /usr/local/bin
  ln -sf "$PREFIX/graalvm/bin/java" /usr/local/bin/java
  ln -sf "$PREFIX/graalvm/bin/javac" /usr/local/bin/javac
  ln -sf "$PREFIX/maven/bin/mvn" /usr/local/bin/mvn
fi

# Symlink $PREFIX/jdk -> $PREFIX/graalvm for convention compatibility
ln -sfn "$PREFIX/graalvm" "$PREFIX/jdk"

# Also symlink /usr/local/conduit -> $PREFIX if not present for cross-submission compatibility
if [ "$PREFIX" != "/usr/local/conduit" ] && [ ! -e /usr/local/conduit ] && [ -w /usr/local ]; then
  ln -sfn "$PREFIX" /usr/local/conduit
fi

# Ensure environment variables are persisted in /etc/profile.d/conduit.sh if writable
if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  cat << EOF > /etc/profile.d/conduit.sh
export JAVA_HOME=$PREFIX/graalvm
export PATH=$PREFIX/graalvm/bin:$PREFIX/maven/bin:\$PATH
EOF
  chmod 644 /etc/profile.d/conduit.sh
fi

"$PREFIX/graalvm/bin/java" -version
JAVA_HOME="$PREFIX/graalvm" "$PREFIX/maven/bin/mvn" -version
