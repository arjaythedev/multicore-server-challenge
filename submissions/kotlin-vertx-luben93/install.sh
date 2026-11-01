#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Eclipse Temurin JDK 27+35 and Gradle 9.8.2 (both checksum-verified),
# plus Ubuntu's gcc, with which build.sh compiles the vendored C bcrypt core (native/, source only) into build/jvm.
# The Kotlin 2.4.21 toolchain is downloaded by Gradle at build time.
set -euo pipefail
apt-get update -q && apt-get install -y -q curl jq ca-certificates gcc libc6-dev unzip
META="$(curl -fsSL 'https://api.adoptium.net/v3/assets/release_name/eclipse/jdk-27%2B35?architecture=x64&image_type=jdk&os=linux')"
URL="$(jq -r '.binaries[0].package.link' <<<"$META")"; SHA="$(jq -r '.binaries[0].package.checksum' <<<"$META")"
curl -fsSLo /tmp/jdk.tgz "$URL"
echo "$SHA  /tmp/jdk.tgz" | sha256sum -c -
rm -rf /opt/jdk && mkdir -p /opt/jdk && tar -C /opt/jdk --strip-components=1 -xzf /tmp/jdk.tgz && rm /tmp/jdk.tgz
chmod -R a+rX /opt/jdk
export JAVA_HOME=/opt/jdk
export PATH="$JAVA_HOME/bin:$PATH"
"$JAVA_HOME/bin/java" -version

GRADLE_VERSION=9.8.2
GRADLE_SHA256=21bd5da2de49b642904077f38c0efdc7778e92b3ed0889392dca61b97e389607
curl -fsSLo /tmp/gradle.zip "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
echo "$GRADLE_SHA256  /tmp/gradle.zip" | sha256sum -c -
rm -rf "/opt/gradle/gradle-${GRADLE_VERSION}"
mkdir -p /opt/gradle
unzip -q /tmp/gradle.zip -d /opt/gradle
rm /tmp/gradle.zip
ln -sfn "/opt/gradle/gradle-${GRADLE_VERSION}/bin/gradle" /usr/local/bin/gradle
gradle --version
