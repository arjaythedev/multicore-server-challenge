#!/usr/bin/env bash
# Creates the benchmark target (ccx33: 8 dedicated x86 vCPU) and N load boxes on a private network, and prepares them.
#   bash up.sh [load boxes, default 3]     -> writes hosts.env next to this script
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../.." && pwd)"
N=${1:-3}; LOC=${LOC:-fsn1}; P=mcsc
hcloud ssh-key describe $P >/dev/null 2>&1 || hcloud ssh-key create --name $P --public-key-from-file ~/.ssh/id_ed25519.pub
hcloud network describe $P >/dev/null 2>&1 || { hcloud network create --name $P --ip-range 10.0.0.0/16; hcloud network add-subnet $P --type cloud --network-zone eu-central --ip-range 10.0.0.0/24; }
mk() { hcloud server describe "$1" >/dev/null 2>&1 || hcloud server create --name "$1" --type "$2" --image ubuntu-24.04 --location $LOC --ssh-key $P --network $P --quiet; }
mk $P-target ccx33
for i in $(seq 0 $((N-1))); do mk $P-lg$i ${LG_TYPE:-cx43}; done
TIP=$(hcloud server ip $P-target); TPRIV=$(hcloud server describe $P-target -o json | jq -r '.private_net[0].ip')
{ echo "TARGET=$TIP"; echo "TARGET_PRIV=$TPRIV"; printf 'LGS="'; for i in $(seq 0 $((N-1))); do printf '%s ' "$(hcloud server ip $P-lg$i)"; done; echo '"'; } > "$HERE/hosts.env"
cat "$HERE/hosts.env"; . "$HERE/hosts.env"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
for h in $TARGET $LGS; do until $SSH root@$h true 2>/dev/null; do sleep 3; done; done
# target: the repo, box setup, Postgres sized as the 16 GB box, full seed, our toolchain
rsync -az --delete -e "$SSH" --exclude '.git' --exclude 'seed/data-*' --exclude 'build/' --exclude 'lib/*.jar' "$ROOT/" root@$TARGET:/root/repo/
$SSH root@$TARGET 'bash -s' < "$HERE/target-setup.sh"
# load boxes: sysctls + loadgen binary
(cd "$ROOT/bench" && GOOS=linux GOARCH=amd64 go build -o "$HERE/loadgen" ./cmd/loadgen)
for h in $LGS; do
  scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$ROOT/box/sysctl.conf" root@$h:/etc/sysctl.d/90-challenge.conf
  $SSH root@$h 'sysctl -q --system; printf "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576\n" > /etc/security/limits.d/90-nofile.conf' &
done; wait
echo "up: target $TARGET ($TPRIV), load boxes $LGS"
