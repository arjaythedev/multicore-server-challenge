#!/usr/bin/env python3
"""Compare four pool/reservation configurations against one unchanged, hot DB.

Owns the application children only. PostgreSQL must already be running on the
specified disposable fixture. No writes, cache dropping or system tuning.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import statistics
import socket
import subprocess
import time
from urllib.parse import quote
from shootout_target import owns_listener
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binaries',type=Path,required=True)
parser.add_argument('--driver',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--pg-pid',type=int,required=True)
parser.add_argument('--pg-port',type=int,default=57536)
parser.add_argument('--port',type=int,default=3357)
parser.add_argument('--seconds',type=int,default=5)
parser.add_argument('--session-guard',default=None)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=False)
with socket.socket() as probe:probe.bind(('127.0.0.1',args.port))
ticks=os.sysconf('SC_CLK_TCK')
def processes(parent=None,pid=None):
 result={}
 for p in ([Path('/proc',str(pid))] if pid else Path('/proc').iterdir()):
  if not p.name.isdigit():continue
  try:
   fields=(p/'stat').read_text().rsplit(')',1)[1].split()
   if parent is not None and int(p.name)!=parent and int(fields[1])!=parent:continue
   io={k:int(v) for k,v in (line.split(':') for line in (p/'io').read_text().splitlines())}
   result[(int(p.name),int(fields[19]))]=(int(fields[11])+int(fields[12]),io.get('read_bytes',0),int(fields[21])*os.sysconf('SC_PAGESIZE'))
  except (OSError,ValueError,IndexError):continue
 return result

def delta(a,b,index):return sum(max(0,value[index]-a[key][index]) for key,value in b.items() if key in a)
def db_stats():
 raw=subprocess.check_output(['psql','-XqAt','-F',',','-h','127.0.0.1','-p',str(args.pg_port),'-U','build','-d','conduit_seed','-c',"SELECT blks_read,blks_hit FROM pg_stat_database WHERE datname=current_database()"],text=True)
 return tuple(map(int,raw.strip().split(',')))
def get(path):
 connection=http.client.HTTPConnection('127.0.0.1',args.port,timeout=3)
 try:
  connection.request('GET',path);r=connection.getresponse();body=r.read()
  if r.status!=200:raise RuntimeError('hot preflight status '+str(r.status))
  return body
 finally:connection.close()
raw=subprocess.check_output(['psql','-XqAt','-h','127.0.0.1','-p',str(args.pg_port),'-U','build','-d','conduit_seed','-c','SELECT slug FROM articles ORDER BY id LIMIT 32'],text=True)
paths=['/api/articles/'+quote(slug,safe='') for slug in raw.splitlines()]
assert len(paths)==32
variants=['00','10','01','11'];binaries={v:args.binaries/('nelua-nelibc' if v=='00' else 'nelua-nelibc-'+v) for v in variants}
metadata={'scope':__doc__.splitlines()[0],'fixture':'same unchanged full-seed DB; fixed 32 article lookups, no writes','session_guard':args.session_guard,'rounds':4,'duration_s':args.seconds,'clients':64,'compiler_profile':'Nelua/private Nelibc freestanding','binary_sha256':{v:hashlib.sha256(p.read_bytes()).hexdigest() for v,p in binaries.items()},'driver_sha256':hashlib.sha256(args.driver.read_bytes()).hexdigest(),'limits':{name:Path('/sys/fs/cgroup',name).read_text().strip() for name in ('cpu.max','memory.max','cpuset.cpus.effective') if Path('/sys/fs/cgroup',name).exists()},'caveats':['Fixed hot read set is not the challenge mix or a capacity score.','PostgreSQL persists across variants to remove fixture/cache-order differences.','Client and server share the existing container; client CPU and PG task I/O counters are retained.', 'ZFS disk I/O may not be attributed in per-task read_bytes; that counter is not proof of zero storage waits.']}
(args.output/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
targets=None;rows=[]
for round_ in range(4):
 order=variants[round_:]+variants[:round_]
 for variant in order:
  if args.session_guard:subprocess.run(['systemctl','is-active','--quiet',args.session_guard],check=True)
  prefix=args.output/f'r{round_}-{variant}'
  with prefix.with_suffix('.server.log').open('w') as log:
   server=subprocess.Popen([str(binaries[variant])],stdout=log,stderr=subprocess.STDOUT,env={**os.environ,'DATABASE_URL':f'postgres://conduit:conduit@127.0.0.1:{args.pg_port}/conduit_seed','JWT_SECRET':'hot-read-diagnostic','HOST':'127.0.0.1','PORT':str(args.port),'DB_READ_THREADS':'4','DB_WRITE_THREADS':'32','DB_AUTH_THREADS':'8','READ_BATCH_STATS':'1','JSON_SCAN':'nelua-auto'})
   try:
    for _ in range(200):
     if server.poll() is not None:raise RuntimeError('application exited during startup')
     if not owns_listener(server.pid,args.port):time.sleep(.025);continue
     try:get('/api/tags');break
     except OSError:time.sleep(.025)
    else:raise RuntimeError('application startup timed out')
    if targets is None:
     targets=[{'url':f'http://127.0.0.1:{args.port}'+path,'sha256':hashlib.sha256(get(path)).hexdigest()} for path in paths]
     (args.output/'targets.json').write_text(json.dumps(targets,indent=2)+'\n')
    command=[str(args.driver),'--targets',str(args.output/'targets.json'),'--clients','64']
    subprocess.run(command+['--duration','2s'],stdout=subprocess.DEVNULL,check=True,timeout=10)
    stats_a=db_stats();app_a=processes(pid=server.pid);pg_a=processes(parent=args.pg_pid);start=time.monotonic()
    result=json.loads(subprocess.check_output(command+['--duration',str(args.seconds)+'s'],text=True,timeout=args.seconds+10))
    span=time.monotonic()-start;app_b=processes(pid=server.pid);pg_b=processes(parent=args.pg_pid)
    result.update(round=round_,variant=variant,app_cpu_s=delta(app_a,app_b,0)/ticks,postgres_cpu_s=delta(pg_a,pg_b,0)/ticks,postgres_read_bytes_counter=delta(pg_a,pg_b,1),app_rss_end_bytes=next(iter(app_b.values()))[2],resource_window_s=span)
    stats_b=db_stats()
    result.update(postgres_blks_read_delta=max(0,stats_b[0]-stats_a[0]),postgres_blks_hit_delta=max(0,stats_b[1]-stats_a[1]),host_loadavg=Path('/proc/loadavg').read_text().strip())
    result['app_cpu_us_per_response']=result['app_cpu_s']*1e6/result['requests'] if result['requests'] else None
    result['postgres_cpu_us_per_response']=result['postgres_cpu_s']*1e6/result['requests'] if result['requests'] else None
    rows.append(result)
    with (args.output/'samples.jsonl').open('a') as output:output.write(json.dumps(result)+'\n')
    print(json.dumps(result),flush=True)
   finally:
    if server.poll() is None:
     server.terminate()
     try:server.wait(20)
     except subprocess.TimeoutExpired:server.kill();server.wait()
summary=[]
for variant in variants:
 selected=[r for r in rows if r['variant']==variant];assert len(selected)==4
 summary.append({'variant':variant,'errors':sum(r['errors'] for r in selected),'body_mismatches':sum(r['body_mismatches'] for r in selected),**{key:statistics.median(r[key] for r in selected) for key in ('goodput_rps','p99_ms','app_cpu_us_per_response','postgres_cpu_us_per_response','client_cores','postgres_read_bytes_counter','postgres_blks_read_delta')}})
(args.output/'summary.json').write_text(json.dumps({'scope':metadata['scope'],'samples':len(rows),'results':summary},indent=2)+'\n')
