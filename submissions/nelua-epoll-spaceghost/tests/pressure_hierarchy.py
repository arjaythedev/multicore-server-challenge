#!/usr/bin/env python3
"""Synthetic cgroup hierarchy; never changes the host's quotas or /proc."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='nc-pressure-hierarchy-') as tmp:
 path=Path(tmp)
 for relative in ('proc/self','sys/fs/cgroup/service/worker'):(path/relative).mkdir(parents=True)
 binary=path/'test'
 subprocess.run(shlex.split(os.environ.get('CC','cc'))+['-std=gnu11','-O1','-g','-Wall','-Wextra','-Werror','-DNC_PRESSURE_TESTING','-fsanitize=address,undefined','-fno-omit-frame-pointer','-I'+str(root/'src'),str(root/'src/read_policy.c'),str(root/'tests/pressure_hierarchy.c'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(path)],check=True,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0'})
