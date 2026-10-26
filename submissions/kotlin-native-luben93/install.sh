#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Eclipse Temurin JDK 27+35 and Gradle 9.8.2 (both checksum-verified),
# used only at build time; the server itself is a native binary with no JVM runtime. Gradle downloads the Kotlin
# 2.4.21/Kotlin-Native toolchain during build.sh.
set -euo pipefail
apt-get update -q && apt-get install -y -q curl jq ca-certificates unzip
META="$(curl -fsSL 'https://api.adoptium.net/v3/assets/release_name/eclipse/jdk-27%2B35?architecture=x64&image_type=jdk&os=linux')"
URL="$(jq -r '.binaries[0].package.link' <<<"$META")"; SHA="$(jq -r '.binaries[0].package.checksum' <<<"$META")"
curl -fsSLo /tmp/jdk.tgz "$URL"
echo "$SHA  /tmp/jdk.tgz" | sha256sum -c -
rm -rf /opt/jdk && mkdir -p /opt/jdk && tar -C /opt/jdk --strip-components=1 -xzf /tmp/jdk.tgz && rm /tmp/jdk.tgz
chmod -R a+rX /opt/jdk
if [ ! -x /opt/jdk/bin/java ]; then
    echo "install.sh: the downloaded JDK is missing at /opt/jdk" >&2
    exit 1
fi
export JAVA_HOME=/opt/jdk
export PATH="/opt/jdk/bin:$PATH"
/opt/jdk/bin/java -version

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
