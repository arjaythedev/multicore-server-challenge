#!/usr/bin/env bash
# cc.sh <label>: compile check of /root/mc/stage/<label> in /root/mc/cc (does not touch the installed submission)
D=/opt/challenge/cc; rm -rf $D; mkdir -p $D; rsync -a --exclude bin --exclude obj --exclude out /root/mc/stage/$1/ $D/
chown -R challenge:challenge $D
cd $D && runuser -u challenge -- env -i HOME=/home/challenge PATH=/usr/local/bin:/usr/bin:/bin bash build.sh > /root/mc/cc-$1.log 2>&1
rc=$?; if [ $rc = 0 ]; then echo "cc ok $1"; else echo "CC FAILED $1"; grep -E "error|warning FS" /root/mc/cc-$1.log | sort -u | head -30; fi
