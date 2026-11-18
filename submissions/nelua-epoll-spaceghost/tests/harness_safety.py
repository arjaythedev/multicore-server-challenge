#!/usr/bin/env python3
"""Exercise listener identity, zero-response analysis and root artifact attacks."""
import importlib.util
import json
import os
from pathlib import Path
import pwd
import socket
import subprocess
import sys
import tempfile
root=Path(__file__).resolve().parents[1]
def module(name):
 spec=importlib.util.spec_from_file_location(name,root/'tools'/f'{name}.py')
 result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
runner=module('shootout_run');target=module('shootout_target')
with tempfile.TemporaryDirectory(prefix='nc-harness-safety-') as temp:
 base=Path(temp)
 with socket.socket() as listener:
  listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
  assert target.owns_listener(os.getpid(),port)
  with subprocess.Popen(['sleep','5']) as other:
   try:assert not target.owns_listener(other.pid,port)
   finally:other.terminate()
  fixture=base/'fixture';fixture.mkdir()
  p=subprocess.run([sys.executable,str(root/'tools/shootout_target.py'),'--postgres',str(fixture),'--binary','/bin/sleep','--output',str(base/'occupied'),'--port',str(port),'--pg-ctl','/not-invoked','--adaptive','0','--scan','c-auto'],capture_output=True,text=True)
  assert p.returncode and 'Address already in use' in p.stderr and '/not-invoked' not in p.stderr
  listener.setblocking(False)
  try:listener.accept();raise AssertionError('unrelated server received a connection')
  except BlockingIOError:pass
 case=base/'zero';(case/'target').mkdir(parents=True)
 (base/'cases.json').write_text(json.dumps([{'name':'zero','binary':'/bin/test'}]))
 (case/'idle-latency.json').write_text(json.dumps({'samples_ms':[1]*50}))
 (case/'merged.json').write_text(json.dumps({'start_at_ms':0,'ramp_s':0,'measure_s':30,'overall':{'rps':0,'p50_ms':0,'p95_ms':0,'p99_ms':0,'error_rate':1},'verdict':{'pass':False}}))
 (case/'target/metadata.json').write_text(json.dumps({'clock_ticks':100,'binary_sha256':'0'*64,'ancestor_limits':{}}))
 (case/'target/resources.jsonl').write_text(''.join(json.dumps({'time_ns':t*10**9,'monotonic_ns':t*10**9,'cpu.stat':f'usage_usec {t*1000}\n','memory.current':'1234','processes':[]})+'\n' for t in (1,2)))
 subprocess.run([sys.executable,str(root/'tools/shootout_analyze.py'),str(base),'--output',str(base/'summary.json')],check=True)
 assert json.loads((base/'summary.json').read_text())['cases'][0]['app_cpu_us_per_response'] is None
 if os.geteuid()==0:
  owner=pwd.getpwnam('build');base.chmod(0o755)
  victim=base/'root-owned';victim.write_text('preserve');victim.chmod(0o600)
  writable=base/'target-writable';writable.mkdir();os.chown(writable,owner.pw_uid,owner.pw_gid)
  bait=writable/'loadgen.log'
  with runner.artifact_user(owner):os.symlink(victim,bait)
  try:runner.artifact_write(bait,'truncate',owner);raise AssertionError('symlink accepted')
  except FileExistsError:pass
  try:runner.artifact_read(victim,owner);raise AssertionError('root permissions leaked')
  except PermissionError:pass
  assert os.geteuid()==0 and victim.read_text()=='preserve'
  runner.artifact_write(writable/'safe.log','safe',owner)
  assert (writable/'safe.log').stat().st_uid==owner.pw_uid
  print('PASS: root launcher refuses target symlinks, opens artifacts without root permissions and restores its identity')
print('PASS: occupied listener fails before PG start or HTTP traffic; child fd ownership verified; zero-response matrix analyzed')
