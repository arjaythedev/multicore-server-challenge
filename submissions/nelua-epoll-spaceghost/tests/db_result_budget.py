#!/usr/bin/env python3
"""Bound actual libpq results against a disposable PostgreSQL test server."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--sanitize',action='store_true')
parser.add_argument('--memory',choices=('host','nelibc'),default='host')
args=parser.parse_args()
url=os.environ.get('DATABASE_URL')
if not url:parser.error('DATABASE_URL must select a PostgreSQL test server')
include=subprocess.check_output(['pg_config','--includedir'],text=True).strip()
flags=['-std=gnu11','-O1','-g','-Wall','-Wextra','-Werror','-ffunction-sections','-fdata-sections','-Wl,--gc-sections','-I'+str(root/'src'),'-I'+include]
libraries=['-pthread','-lpq']
if args.memory=='nelibc':
 flags+=['-DNC_MEMORY_NELIBC']
 libraries+=['-Wl,--exclude-libs,nelibc-private.a',str(root/'build/nelibc-private.a'),'-ldl','-lm']
if args.sanitize:flags+=['-fsanitize=address,undefined','-fno-omit-frame-pointer']
with tempfile.TemporaryDirectory(prefix='nc-db-budget-') as tmp:
 binary=Path(tmp)/'test'
 subprocess.run(shlex.split(os.environ.get('CC','cc'))+flags+[str(root/'src/db.c'),str(root/'tests/db_result_budget.c'),*libraries,'-o',str(binary)],check=True)
 try:
  result=subprocess.run([str(binary),url],timeout=60,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0'})
 except subprocess.TimeoutExpired:parser.exit(1,'FAIL: result budget test timed out\n')
 if result.returncode:parser.exit(1,'FAIL: result budget test failed\n')
