#!/usr/bin/env bash
# Deletes every server, the network and the ssh key that up.sh created.
set -euo pipefail
for s in $(hcloud server list -o noheader -o columns=name | grep '^mcsc-' || true); do hcloud server delete "$s" & done; wait
hcloud network delete mcsc 2>/dev/null || true; hcloud ssh-key delete mcsc 2>/dev/null || true
hcloud server list
