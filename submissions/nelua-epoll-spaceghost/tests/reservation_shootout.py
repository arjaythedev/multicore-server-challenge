#!/usr/bin/env python3
"""Balanced C/Nelua JSON request-lifetime comparison; run on the Nelibc build host.

Unlike the reusable-buffer writer microbenchmark, each timed string owns a
fresh request and releases it after the consumed output. Context pooling is on
for every variant; this isolates the additional output reservation change.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys

root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--loops',type=int,default=50000)
parser.add_argument('--rounds',type=int,default=8)
args=parser.parse_args()
if args.rounds<8 or args.rounds%8 or not 1000<=args.loops<=1000000:
    parser.error('use complete eight-round rotations and 1000..1000000 loops')
args.output.mkdir(parents=True,exist_ok=False)
variants=list(itertools.product(('c','nelua'),('host','nelibc'),(0,1)))
binaries={}
meta={'scope':__doc__.splitlines()[0],'loops':args.loops,'rounds':args.rounds,
      'context_pool':1,'lifetimes':True,'sources':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
          for p in [root/'src/request.c',root/'src/serialize_c.c',root/'src/serialize.nelua',root/'tests/serialize_scan.c']},
      'binaries':[]}
for app,memory,reserve in variants:
    binary=args.output/f'{app}-{memory}-r{reserve}'
    command=[sys.executable,str(root/'tests/serialize_scan.py'),'--implementation',app,'--memory',memory,
             '--reserve',str(reserve),'--benchmark',str(args.loops),'--compile-only',str(binary)]
    subprocess.run(command,check=True)
    binaries[app,memory,reserve]=binary
    meta['binaries'].append({'app':app,'memory':memory,'reserve':reserve,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'command':command})
(args.output/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
checksums={}
samples={}
with (args.output/'samples.jsonl').open('w') as output:
    for round_ in range(args.rounds):
        offset=round_%len(variants)
        order=variants[offset:]+variants[:offset]
        for app,memory,reserve in order:
            p=subprocess.run([str(binaries[app,memory,reserve]),str(args.loops)],capture_output=True,text=True,check=True,
                env={**os.environ,'NC_WRITER_LIFETIMES':'1','JSON_SCAN':app+'-auto'},timeout=120)
            checksum=re.fullmatch(r'checksum=(\d+)\s*',p.stderr)
            if not checksum or checksums.setdefault('all',checksum[1])!=checksum[1]:
                raise RuntimeError('consumed writer output differs between configurations')
            found={}
            for line in p.stdout.splitlines():
                match=re.match(r'BENCH kind=(\d+) length=(\d+) loops=(\d+) cpu_seconds=[\d.]+ ns_per_string=([\d.]+)',line)
                if not match: continue
                kind,length,loops,ns=match.groups();key=int(kind),int(length)
                if key in found or int(loops)!=args.loops:raise RuntimeError('duplicate or invalid sample')
                found[key]=float(ns)
            if set(found)!=set(itertools.product(range(3),(12,64,128,1024,4096))):
                raise RuntimeError('incomplete writer matrix')
            for (kind,length),ns in found.items():
                record=dict(app=app,memory=memory,reserve=reserve,round=round_,kind=kind,length=length,ns_per_request=ns)
                output.write(json.dumps(record)+'\n');output.flush()
                samples.setdefault((app,memory,reserve,kind,length),[]).append(ns)
rows=[]
for key,values in sorted(samples.items()):
    if len(values)!=args.rounds:raise RuntimeError('incomplete repetitions')
    rows.append(dict(zip(('app','memory','reserve','kind','length'),key),median_ns=statistics.median(values),min_ns=min(values),max_ns=max(values)))
(args.output/'summary.json').write_text(json.dumps({'scope':meta['scope'],'samples':len(rows)*args.rounds,'results':rows},indent=2)+'\n')
print('PASS:',len(rows)*args.rounds,'balanced complete writer lifetime samples; identical consumed output')
