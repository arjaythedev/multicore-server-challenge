#!/usr/bin/env bash
# What Arjay's CI does, in a clean ubuntu:24.04 container: tools, install.sh as root, test/run.sh as a normal user
# against Postgres 18 with the dev seed (our side cluster on 5433). usage: ci-docker.sh <repo dir> <submission dir>
set -u
REPO=$1; SUB=$2
docker run --rm --network host --cpuset-cpus=20-23 -v "$REPO":/src:ro -v $HOME/go-sdk:/go-sdk:ro ubuntu:24.04 bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq postgresql-client curl jq sudo ca-certificates >/dev/null
useradd -m runner
cp -r /src /home/runner/repo && chown -R runner /home/runner/repo
bash /home/runner/repo/$SUB/install.sh > /tmp/install.log 2>&1 || { tail -20 /tmp/install.log; exit 1; }
echo INSTALL_OK
su runner -c 'cd ~/repo && export PATH=/go-sdk/bin:\$PATH PGHOST=127.0.0.1 PGPORT=5433 PGUSER=delneg PGPASSWORD=delneg PORT=999 GOCACHE=/tmp/gocache; bash test/run.sh $SUB'
"
