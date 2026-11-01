#!/usr/bin/env bash
# Runs on the target as root: the official box setup, Postgres tuned as for 16 GB RAM, the full seed, our build.
set -euo pipefail
cd /root/repo
[ -f /root/versions.txt ] || bash box/setup-box.sh > /root/setup.log 2>&1
# pg-conf.sh sizes from MemTotal (32 GB on ccx33): write the 16 GB box's values instead
sed 's/^RAM_GB=.*/RAM_GB=16/' box/pg-conf.sh > /tmp/pg-conf16.sh && bash /tmp/pg-conf16.sh >/dev/null && systemctl restart postgresql@18-main
if ! command -v go >/dev/null; then
  V=$(curl -fsSL 'https://go.dev/dl/?mode=json' | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["version"])')
  curl -fsSL https://go.dev/dl/$V.linux-amd64.tar.gz | tar -C /usr/local -xz; ln -sf /usr/local/go/bin/go /usr/local/bin/go
fi
if [ "$(runuser -u postgres -- psql -tAXc "select count(*) from pg_database where datname='conduit_seed'")" != 1 ]; then
  chown -R postgres /root/repo/seed; chmod o+x /root; chmod -R o+rX /root/repo
  (cd /root/repo && runuser -u postgres -- env HOME=/tmp GOPATH=/tmp/go GOCACHE=/tmp/gocache bash seed/make-seed.sh) > /root/seed.log 2>&1
fi
S=/root/repo/submissions/java-servlet-clickin
bash $S/install.sh > /root/install.log 2>&1
rm -rf /opt/challenge/java-servlet-clickin; cp -r $S /opt/challenge/java-servlet-clickin; chown -R challenge:challenge /opt/challenge
ln -sfn /opt/challenge/java-servlet-clickin /opt/challenge/current
runuser -u challenge -- bash /opt/challenge/current/build.sh > /root/build.log 2>&1
printf 'DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit\nJWT_SECRET=multicore-server-challenge\nHOST=0.0.0.0\nPORT=80\n' > /etc/challenge/env
install -d /opt/conduit-tools; install -m 755 $S/dev/hcloud/switch.sh /opt/conduit-tools/switch.sh; install -m 755 $S/dev/hcloud/monitor.sh /opt/conduit-tools/monitor.sh
systemctl stop nginx; systemctl disable nginx >/dev/null 2>&1 || true
cat /root/versions.txt
