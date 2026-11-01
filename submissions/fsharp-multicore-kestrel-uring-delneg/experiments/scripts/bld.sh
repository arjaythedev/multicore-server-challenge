#!/usr/bin/env bash
# bld.sh <label>: install /root/mc/stage/<label> as the submission and build it (queued, so no screen is running)
S=/opt/challenge/subs/fsharp-multicore-kestrel-uring-delneg
rsync -a --delete --exclude bin --exclude obj --exclude out --exclude .built /root/mc/stage/$1/ $S/
chown -R challenge:challenge $S
cd $S && runuser -u challenge -- env -i HOME=/home/challenge PATH=/usr/local/bin:/usr/bin:/bin bash build.sh > /root/mc/build-$1.log 2>&1
rc=$?
if [ $rc = 0 ]; then touch .built; echo "built $1"; else rm -f .built; echo "BUILD FAILED $1"; grep -E " error " /root/mc/build-$1.log | sort -u | head; fi
