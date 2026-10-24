#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 (x86_64 or arm64): Erlang/OTP 28.5.0.8 (hex.pm's official Ubuntu
# build, sha256-pinned) in /usr/local/otp, Gleam 1.19.2 (official release tarball, sha256-pinned) in
# /usr/local/gleam, and a C compiler for the bcrypt NIF.
set -euo pipefail
OTP=28.5.0.8
GLEAM=1.19.2
case "$(uname -m)" in
  x86_64)
    OTP_ARCH=amd64; OTP_SHA=9d1e254f31554bf26595a6a03164f8e38f48c74d5f60c00b589d581b8ad67781
    GLEAM_ARCH=x86_64; GLEAM_SHA=2ba2afb66ca9f6dcc01a4a6e9169b6942963bad6483bec9571ddc078cfe6f41f ;;
  aarch64)
    OTP_ARCH=arm64; OTP_SHA=4e19313e9f34ef95caf96b5b7efbfb0d9561fed75d124de6148ab7b4b6a8847c
    GLEAM_ARCH=aarch64; GLEAM_SHA=d1d1a9d53f6b317c0563a4806873c8ccace54291ead023373728af379402d4f1 ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends build-essential ca-certificates curl libssl3 libncurses6 libstdc++6

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://builds.hex.pm/builds/otp/$OTP_ARCH/ubuntu-24.04/OTP-$OTP.tar.gz" -o "$tmp/otp.tgz"
echo "$OTP_SHA  $tmp/otp.tgz" | sha256sum -c -
rm -rf /usr/local/otp
mkdir -p /usr/local/otp
tar -xzf "$tmp/otp.tgz" -C /usr/local/otp --strip-components=1
(cd /usr/local/otp && ./Install -minimal /usr/local/otp >/dev/null)
for b in erl erlc escript; do ln -sf "/usr/local/otp/bin/$b" "/usr/local/bin/$b"; done

curl -fsSL "https://github.com/gleam-lang/gleam/releases/download/v$GLEAM/gleam-v$GLEAM-$GLEAM_ARCH-unknown-linux-musl.tar.gz" -o "$tmp/gleam.tgz"
echo "$GLEAM_SHA  $tmp/gleam.tgz" | sha256sum -c -
rm -rf /usr/local/gleam
mkdir -p /usr/local/gleam/bin
tar -xzf "$tmp/gleam.tgz" -C /usr/local/gleam/bin
ln -sf /usr/local/gleam/bin/gleam /usr/local/bin/gleam
chmod -R a+rX /usr/local/otp /usr/local/gleam

erl -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]), halt().'
gleam --version
