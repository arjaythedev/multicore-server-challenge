#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04. Installs what the server is built and run with, all from
# pinned sources:
#   PHP 8.5 (not thread-safe)  -> /usr/local        php.net tarball, sha256-checked
#   Swoole                     -> PHP's extensions  built from its release tag, commit-checked
#   Composer                   -> /usr/local/bin    composer.phar, sha256-checked
# Safe to run again: a step whose result is already at the pinned version is skipped.
set -euo pipefail

PHP_VERSION=8.5.12
PHP_SHA256=08bc2eba2a588654ade1357174aa646b761556c862dda0678345ee29ed481209

SWOOLE_VERSION=6.2.0
SWOOLE_COMMIT=8cf1673587969bc3a198d202d9cba7aed4f5284f

COMPOSER_VERSION=2.10.3
COMPOSER_SHA256=7a2d379d5b8ffdaa028580ef26494c36d2feef4b178d3dd1473a4dbc5e17c8d6

export DEBIAN_FRONTEND=noninteractive
say() { printf '\n[install %s] %s\n' "$(date +%T)" "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "install.sh must run as root" >&2; exit 1; }

WORK="$(mktemp -d /var/tmp/install.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # url sha256 destination
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet -
}

say "build dependencies"
apt-get update -q
apt-get install -y -q --no-install-recommends -o DPkg::Lock::Timeout=120 \
  build-essential autoconf bison re2c pkg-config git curl ca-certificates unzip xz-utils \
  libxml2-dev libssl-dev zlib1g-dev libonig-dev libpq-dev

# --- PHP ---------------------------------------------------------------------------------------
# The plain build: no thread safety, no embed SAPI.
if [ "$(php -r 'echo PHP_VERSION, PHP_ZTS;' 2>/dev/null || true)" = "${PHP_VERSION}0" ]; then
  say "PHP $PHP_VERSION already installed"
else
  say "PHP $PHP_VERSION"
  fetch "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz" "$PHP_SHA256" "$WORK/php.tar.xz"
  mkdir "$WORK/php" && tar -xJf "$WORK/php.tar.xz" -C "$WORK/php" --strip-components=1
  (
    cd "$WORK/php"
    ./configure --prefix=/usr/local --with-config-file-path=/usr/local/etc/php \
      --with-pgsql --enable-mbstring --with-openssl --with-zlib --enable-sockets \
      --without-sqlite3 --without-pdo-sqlite --disable-cgi --disable-phpdbg >"$WORK/configure.log" 2>&1 \
      || { tail -n 40 "$WORK/configure.log"; exit 1; }
    make -j"$(nproc)" >"$WORK/make.log" 2>&1 || { tail -n 40 "$WORK/make.log"; exit 1; }
    make install >/dev/null
  )
  install -d /usr/local/etc/php
  ldconfig
fi

# --- Swoole ------------------------------------------------------------------------------------
# Loaded from the server's php.ini, not globally.
if [ "$(php -d extension=swoole -r 'echo phpversion("swoole");' 2>/dev/null || true)" = "$SWOOLE_VERSION" ]; then
  say "Swoole $SWOOLE_VERSION already installed"
else
  say "Swoole $SWOOLE_VERSION"
  git clone -q --depth 1 --branch "v$SWOOLE_VERSION" https://github.com/swoole/swoole-src.git "$WORK/swoole"
  [ "$(git -C "$WORK/swoole" rev-parse HEAD)" = "$SWOOLE_COMMIT" ] \
    || { echo "tag v$SWOOLE_VERSION no longer points at $SWOOLE_COMMIT" >&2; exit 1; }
  (
    cd "$WORK/swoole"
    phpize >/dev/null
    ./configure --enable-swoole >"$WORK/swoole-configure.log" 2>&1 \
      || { tail -n 40 "$WORK/swoole-configure.log"; exit 1; }
    make -j"$(nproc)" >"$WORK/swoole-make.log" 2>&1 || { tail -n 40 "$WORK/swoole-make.log"; exit 1; }
    make install >/dev/null
  )
fi

# --- Composer ----------------------------------------------------------------------------------
if [ "$(composer --version 2>/dev/null | awk '{print $3}')" = "$COMPOSER_VERSION" ]; then
  say "Composer $COMPOSER_VERSION already installed"
else
  say "Composer $COMPOSER_VERSION"
  fetch "https://getcomposer.org/download/$COMPOSER_VERSION/composer.phar" "$COMPOSER_SHA256" "$WORK/composer.phar"
  install -m 755 "$WORK/composer.phar" /usr/local/bin/composer
fi

say "versions"
php -v | head -n 1
php -r 'echo "zts=", PHP_ZTS, " extensions=", implode(",", get_loaded_extensions()), PHP_EOL;'
php -d extension=swoole -r 'echo "swoole ", phpversion("swoole"), PHP_EOL;'
COMPOSER_ALLOW_SUPERUSER=1 composer --version
