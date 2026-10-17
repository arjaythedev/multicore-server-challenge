#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 (x86_64 or arm64): Erlang/OTP 28.5.0.8 (hex.pm's official Ubuntu build,
# sha256-pinned) in /usr/local/otp and Elixir 1.19.6 (official release zip, sha256-pinned) in /usr/local/elixir.
set -euo pipefail
OTP=28.5.0.8
EX=1.19.6
EX_SHA=d69db87541e1e5f4fa3f803353c01a30d4ef0e236c6bf53128b2bbed8b0b9b7e
case "$(uname -m)" in
  x86_64)  ARCH=amd64; OTP_SHA=9d1e254f31554bf26595a6a03164f8e38f48c74d5f60c00b589d581b8ad67781 ;;
  aarch64) ARCH=arm64; OTP_SHA=4e19313e9f34ef95caf96b5b7efbfb0d9561fed75d124de6148ab7b4b6a8847c ;;
  *) echo "unsupported arch $(uname -m)"; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends build-essential ca-certificates curl unzip git libssl3 libncurses6 libstdc++6

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://builds.hex.pm/builds/otp/$ARCH/ubuntu-24.04/OTP-$OTP.tar.gz" -o "$tmp/otp.tgz"
echo "$OTP_SHA  $tmp/otp.tgz" | sha256sum -c -
rm -rf /usr/local/otp
mkdir -p /usr/local/otp
tar -xzf "$tmp/otp.tgz" -C /usr/local/otp --strip-components=1
(cd /usr/local/otp && ./Install -minimal /usr/local/otp >/dev/null)

curl -fsSL "https://github.com/elixir-lang/elixir/releases/download/v$EX/elixir-otp-28.zip" -o "$tmp/ex.zip"
echo "$EX_SHA  $tmp/ex.zip" | sha256sum -c -
rm -rf /usr/local/elixir
mkdir -p /usr/local/elixir
unzip -q "$tmp/ex.zip" -d /usr/local/elixir

for b in erl erlc escript epmd run_erl to_erl; do ln -sf "/usr/local/otp/bin/$b" "/usr/local/bin/$b"; done
for b in elixir elixirc iex mix; do ln -sf "/usr/local/elixir/bin/$b" "/usr/local/bin/$b"; done
chmod -R a+rX /usr/local/otp /usr/local/elixir
erl -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]), halt().'
elixir --version | tail -1
