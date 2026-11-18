#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Eclipse Temurin JDK 26.0.2.1+1 (checksum-verified) -> /opt/jdk.
# Gradle comes from the project's own ./gradlew wrapper at build time.
set -euo pipefail
apt-get update -q && apt-get install -y -q curl jq ca-certificates
META="$(curl -fsSL 'https://api.adoptium.net/v3/assets/release_name/eclipse/jdk-26.0.2.1%2B1?architecture=x64&image_type=jdk&os=linux')"
URL="$(jq -r '.binaries[0].package.link' <<<"$META")"; SHA="$(jq -r '.binaries[0].package.checksum' <<<"$META")"
curl -fsSLo /tmp/jdk.tgz "$URL"
echo "$SHA  /tmp/jdk.tgz" | sha256sum -c -
rm -rf /opt/jdk && mkdir -p /opt/jdk && tar -C /opt/jdk --strip-components=1 -xzf /tmp/jdk.tgz && rm /tmp/jdk.tgz
chmod -R a+rX /opt/jdk
/opt/jdk/bin/java -version
