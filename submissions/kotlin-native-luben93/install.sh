#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Eclipse Temurin JDK 27+35 (checksum-verified) -> /opt/jdk, which runs
# Gradle and the Kotlin/Native compiler at build time only (the server itself is a native binary, no JVM).
# Gradle 9.8.2 (checksum-pinned in gradle-wrapper.properties) and the Kotlin 2.4.21 toolchain, Kotlin/Native
# included, are downloaded by build.sh.
set -euo pipefail
apt-get update -q && apt-get install -y -q curl jq ca-certificates
META="$(curl -fsSL 'https://api.adoptium.net/v3/assets/release_name/eclipse/jdk-27%2B35?architecture=x64&image_type=jdk&os=linux')"
URL="$(jq -r '.binaries[0].package.link' <<<"$META")"; SHA="$(jq -r '.binaries[0].package.checksum' <<<"$META")"
curl -fsSLo /tmp/jdk.tgz "$URL"
echo "$SHA  /tmp/jdk.tgz" | sha256sum -c -
rm -rf /opt/jdk && mkdir -p /opt/jdk && tar -C /opt/jdk --strip-components=1 -xzf /tmp/jdk.tgz && rm /tmp/jdk.tgz
chmod -R a+rX /opt/jdk
/opt/jdk/bin/java -version
