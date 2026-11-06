#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo 'install.sh supports Ubuntu 24.04 x86_64 only.' >&2
    exit 1
fi
source /etc/os-release
if [[ $ID != ubuntu || $VERSION_ID != 24.04 || $EUID != 0 ]]; then
    echo 'Run install.sh as root on Ubuntu 24.04.' >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl tar gzip unzip

umask 022
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jdk_url='https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_x64_linux_hotspot_25.0.5_8.tar.gz'
jdk_sha='68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb'
gradle_url='https://services.gradle.org/distributions/gradle-9.8.2-bin.zip'
gradle_sha='21bd5da2de49b642904077f38c0efdc7778e92b3ed0889392dca61b97e389607'

curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' "$jdk_url" -o "$work/jdk.tar.gz"
curl --fail --location --retry 3 --proto '=https' --proto-redir '=https' "$gradle_url" -o "$work/gradle.zip"
printf '%s  %s\n' "$jdk_sha" "$work/jdk.tar.gz" "$gradle_sha" "$work/gradle.zip" | sha256sum --check --strict

mkdir "$work/jdk"
tar -xzf "$work/jdk.tar.gz" -C "$work/jdk" --strip-components=1
unzip -q "$work/gradle.zip" -d "$work"
install -d /opt/conduit-temurin-25.0.5+8 /opt/conduit-gradle-9.8.2
cp -a "$work/jdk/." /opt/conduit-temurin-25.0.5+8/
cp -a "$work/gradle-9.8.2/." /opt/conduit-gradle-9.8.2/
/opt/conduit-temurin-25.0.5+8/bin/java -version
JAVA_HOME=/opt/conduit-temurin-25.0.5+8 /opt/conduit-gradle-9.8.2/bin/gradle --version
echo 'Build requires PostgreSQL 18 host binaries (preferred) or an accessible Docker daemon for Testcontainers.'
