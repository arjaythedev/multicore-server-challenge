#!/usr/bin/env python3
"""Check actual C/Nelua HTTP overload and recovery against an owned DB clone.

Requires a disposable local PG cluster with a conduit_dev template and build
superuser. Creates/drops only its own uniquely named test database.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from shootout_target import owns_listener
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binaries',type=Path,required=True)
parser.add_argument('--pg-port',type=int,default=57536)
parser.add_argument('--port',type=int,default=3358)
args=parser.parse_args()
with socket.socket() as probe:probe.bind(('127.0.0.1',args.port))
db='nc_result_cap_'+str(os.getpid())
def sql(query,database=db):
 return subprocess.check_output(['psql','-XqAt','-h','127.0.0.1','-p',str(args.pg_port),'-U','build','-d',database,'-v','ON_ERROR_STOP=1','-c',query],text=True)
def get(path):
 connection=http.client.HTTPConnection('127.0.0.1',args.port,timeout=10)
 try:
  connection.request('GET',path);response=connection.getresponse()
  return response.status,json.loads(response.read())
 finally:connection.close()
sql('CREATE DATABASE '+db+' TEMPLATE conduit_dev STRATEGY FILE_COPY','postgres')
try:
 slug=sql('SELECT slug FROM articles ORDER BY id LIMIT 1').strip()
 for profile in ('c-host','c-nelibc','nelua-host','nelua-nelibc'):
  for pipeline in ('0','1'):
   sql("UPDATE users SET bio=repeat('x',786432) WHERE id=(SELECT author_id FROM articles ORDER BY id LIMIT 1)")
   server=subprocess.Popen([str(args.binaries/profile)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env={**os.environ,'DATABASE_URL':f'postgres://conduit:conduit@127.0.0.1:{args.pg_port}/{db}','JWT_SECRET':'overload-http-test','HOST':'127.0.0.1','PORT':str(args.port),'READ_PIPELINE':pipeline,'DB_RESULT_MEMORY_MB':'1'})
   try:
    for _ in range(400):
     if server.poll() is not None:raise RuntimeError('application startup failed')
     if owns_listener(server.pid,args.port) and get('/api/tags')[0]==200:break
     time.sleep(.025)
    else:raise RuntimeError('application readiness deadline')
    status,_=get('/api/articles/'+slug);assert status==503,(profile,pipeline,status)
    sql("UPDATE users SET bio='small' WHERE id=(SELECT author_id FROM articles ORDER BY id LIMIT 1)")
    status,body=get('/api/articles/'+slug)
    assert status==200 and body['article']['author']['bio']=='small',(profile,pipeline,status)
    print('PASS:',profile,'pipeline='+pipeline,'oversized result -> HTTP503 -> recovered HTTP200',flush=True)
   finally:
    if server.poll() is None:
     server.terminate()
     try:server.wait(20)
     except subprocess.TimeoutExpired:server.kill();server.wait()
finally:sql('DROP DATABASE IF EXISTS '+db+' WITH (FORCE)','postgres')
