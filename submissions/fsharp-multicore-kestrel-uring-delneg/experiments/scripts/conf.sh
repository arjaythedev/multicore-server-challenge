#!/usr/bin/env bash
# conf.sh <template>: conformance (test/run.sh) on a copy of the installed submission, in the foreground (for the
# queue). Prints the summary; the log is /root/mc/test-<template>.log.
T=${1:-conduit_dev}
systemctl stop challenge 2>/dev/null; pkill -x Server; for i in $(seq 50); do ss -ltn | grep -qE ":(3000|80) " || break; sleep 0.2; done
rsync -a --delete --exclude out --exclude obj --exclude bin /opt/challenge/subs/fsharp-multicore-kestrel-uring-delneg/ /root/mc/sub/
cd /opt/challenge-repo && TEMPLATE=$T PATH=/usr/local/go/bin:$PATH timeout 1200 bash test/run.sh /root/mc/sub > /root/mc/test-$T.log 2>&1
rc=$?
echo "conf $T rc=$rc: $(grep -iE 'passed|failed|[0-9]+/[0-9]+' /root/mc/test-$T.log | tail -2 | tr '\n' ' ')"
