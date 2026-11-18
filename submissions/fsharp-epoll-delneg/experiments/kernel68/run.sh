#!/usr/bin/env bash
# run.sh <kernel deb url>...: boots each kernel in QEMU (TCG on CPU 23) with t.c as PID 1
cd ~/mc-fs2-work/k68; N=$HOME/mc-fs2/submissions/fsharp-epoll-delneg/native
gcc -O2 -static -o init t.c $N/uring.c -I$N 2>&1 | grep -v warning | head -5
echo init | cpio -o -H newc 2>/dev/null | gzip > ir.gz
for url in "$@"; do
  f=$(basename $url); [ -f $f ] || curl -sSf -o $f $url || { echo "no $url"; continue; }
  d=x-$f; rm -rf $d; mkdir $d; dpkg-deb -x $f $d; v=$(ls $d/boot/vmlinuz-* | head -1)
  echo "=== $f"
  taskset -c 23 timeout 500 qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 1024 -nographic -no-reboot -kernel $v -initrd ir.gz -append "console=ttyS0 panic=-1 quiet" > q-$f.log 2>&1; tr -d "\r" < q-$f.log | grep -a -E "KERNEL|TEST|ring:|accepted|FAIL|RESULT|ur_|res -|client|Kernel panic" | cut -c1-200
  rm -rf $d
done
