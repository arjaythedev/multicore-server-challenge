#!/usr/bin/env python3
"""The native host owns allocation; generated Nelua must stay runtime-free."""
from pathlib import Path
import re
import subprocess

source=Path('build/app.c').read_text()
for pattern in (r'\bnelua_(?:gc|panic|assert|error|abort)',r'\b(?:lua_|GC_)',
                r'\b(?:malloc|calloc|realloc|free|abort|exit)\s*\('):
    if re.search(pattern,source):
        raise SystemExit('unexpected runtime/allocation path in generated Nelua C: '+pattern)
if re.search(r'\bmain\s*\(',source):
    raise SystemExit('unexpected Nelua main; native transport is the sole host entrypoint')
print('audit passed: no Nelua VM, GC, allocator, panic, or initialization entrypoint')
subprocess.run(['size','bin/conduit'],check=True)
