#!/usr/bin/env bash
# Builds nginx (pinned tarball, checked) with the one module this submission adds, module/ngx_http_sql_module.c.
set -euo pipefail
cd "$(dirname "$0")"
NGINX_VERSION=1.28.0
NGINX_SHA256=c6b5c6b086c0df9d3ca3ff5e084c1d0ef909e6038279c71c1c3e985f576ff76a

rm -rf build && mkdir -p build
curl -fsSL --retry 3 -o build/nginx.tar.gz "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"
echo "$NGINX_SHA256  build/nginx.tar.gz" | sha256sum -c --quiet -
tar -xzf build/nginx.tar.gz -C build
cd "build/nginx-$NGINX_VERSION"
./configure --prefix="$PWD/../nginx" --with-threads --with-cc-opt='-O2' --add-module="$PWD/../../module" \
  --without-http_gzip_module --without-http_ssi_module --without-http_userid_module \
  --without-http_access_module --without-http_auth_basic_module --without-http_mirror_module \
  --without-http_autoindex_module --without-http_geo_module --without-http_map_module \
  --without-http_split_clients_module --without-http_referer_module --without-http_proxy_module \
  --without-http_fastcgi_module --without-http_uwsgi_module --without-http_scgi_module \
  --without-http_grpc_module --without-http_memcached_module --without-http_limit_conn_module \
  --without-http_limit_req_module --without-http_empty_gif_module --without-http_browser_module \
  --without-http_upstream_hash_module --without-http_upstream_ip_hash_module \
  --without-http_upstream_least_conn_module --without-http_upstream_random_module \
  --without-http_upstream_keepalive_module --without-http_upstream_zone_module > ../configure.log
make -j"$(nproc)" > ../make.log
make install > /dev/null
echo "built $(../nginx/sbin/nginx -v 2>&1)"
