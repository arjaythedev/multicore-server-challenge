#!/usr/bin/env bash
# Runs the official orchestrator from the first load box against the target over the private network.
#   bash search.sh [start users] [max users]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/hosts.env"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
set -- ${1:-20000} ${2:-300000}; LG0=${LGS%% *}
# WEIGHTS="3 5": the share of users per load box, in LGS order (default 8 each)
W=(${WEIGHTS:-}); BOXES=""; k=0; for h in $LGS; do BOXES="$BOXES,root@$h=${W[$k]:-8}"; k=$((k+1)); done; BOXES=${BOXES#,}
$SSH root@$LG0 "test -f ~/.ssh/id_ed25519 || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519; printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n  LogLevel ERROR\n' > ~/.ssh/config; cat ~/.ssh/id_ed25519.pub" > /tmp/lg0.pub
for h in $TARGET $LGS; do $SSH root@$h "cat >> ~/.ssh/authorized_keys" < /tmp/lg0.pub; done
scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$HERE/loadgen" root@$LG0:/root/loadgen
$SSH root@$LG0 "ulimit -n 1048576; cd /root && CONDUIT_JWT_SECRET=multicore-server-challenge ./loadgen search -target-ssh root@$TARGET_PRIV -target-url http://$TARGET_PRIV -lang java-servlet -boxes '$BOXES' -start $1 -max $2 -outdir results/run-\$(date +%H%M) 2>&1 | tail -40"
