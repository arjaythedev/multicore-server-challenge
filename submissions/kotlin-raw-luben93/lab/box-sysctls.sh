#!/usr/bin/env bash
# Applies the benchmark box's kernel settings (box/sysctl.conf) plus what the box leaves at kernel defaults that we
# want to hit like the box does. Run as root.
set -euo pipefail
sysctl -w net.core.somaxconn=65535 net.ipv4.tcp_max_syn_backlog=65535 net.ipv4.ip_local_port_range="1024 65535" \
  net.ipv4.tcp_tw_reuse=1 fs.file-max=2097152 fs.nr_open=1048576
sysctl -w vm.max_map_count=65530        # the box does NOT raise this: keep the default so we hit the same wall
[ -f /proc/sys/net/netfilter/nf_conntrack_max ] && sysctl -w net.netfilter.nf_conntrack_max=1048576 || true
