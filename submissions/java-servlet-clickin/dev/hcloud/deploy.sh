#!/usr/bin/env bash
# Pushes the current submission to the target, rebuilds it, and sets extra tuning env (args: KEY=VALUE ...).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; . "$HERE/hosts.env"; S="$(cd "$HERE/../.." && pwd)"
SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
rsync -az --delete -e "$SSH" --exclude build/ --exclude 'lib/*.jar' "$S/" root@$TARGET:/opt/challenge/java-servlet-clickin/
$SSH root@$TARGET "chown -R challenge:challenge /opt/challenge && runuser -u challenge -- bash /opt/challenge/current/build.sh >/root/build.log 2>&1 && tail -1 /root/build.log
printf 'DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit\nJWT_SECRET=multicore-server-challenge\nHOST=0.0.0.0\nPORT=80\n' > /etc/challenge/env
for kv in $*; do echo \$kv >> /etc/challenge/env; done; cat /etc/challenge/env | tail -n +5"
