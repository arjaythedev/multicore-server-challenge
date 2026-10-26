#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 (x86_64 or arm64): Erlang/OTP 29.1.2 (hex.pm's official Ubuntu build,
# sha256-pinned) in /usr/local/otp and Elixir 1.20.4 (official release zip, sha256-pinned) in /usr/local/elixir.
set -euo pipefail
OTP=29.1.2
EX=1.20.4
EX_SHA=7863c546cda13fecc949e562e326042451dacf8fd8698a36783cb71eeb223b46
case "$(uname -m)" in
  x86_64)  ARCH=amd64; OTP_SHA=2cfca446976fc61962585a1c77e5d11ddb6f5fed83e84668a2c4acfaad60d22e ;;
  aarch64) ARCH=arm64; OTP_SHA=5d344f2ef455cfa15ad3112ce3aaecc8fa0d97532b2f106df46bc1701bc02c27 ;;
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

curl -fsSL "https://github.com/elixir-lang/elixir/releases/download/v$EX/elixir-otp-29.zip" -o "$tmp/ex.zip"
echo "$EX_SHA  $tmp/ex.zip" | sha256sum -c -
rm -rf /usr/local/elixir
mkdir -p /usr/local/elixir
unzip -q "$tmp/ex.zip" -d /usr/local/elixir

for b in erl erlc escript epmd run_erl to_erl; do ln -sf "/usr/local/otp/bin/$b" "/usr/local/bin/$b"; done
for b in elixir elixirc iex mix; do ln -sf "/usr/local/elixir/bin/$b" "/usr/local/bin/$b"; done
chmod -R a+rX /usr/local/otp /usr/local/elixir
erl -noshell -eval 'io:format("OTP ~s~n",[erlang:system_info(otp_release)]), halt().'
elixir --version | tail -1
