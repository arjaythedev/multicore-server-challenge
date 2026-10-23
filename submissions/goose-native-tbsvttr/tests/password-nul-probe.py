#!/usr/bin/env python3
"""Legal embedded-NUL password interoperability on a disposable test database.

Baseline --expect-rejected reproduces the inherited422 input bug. Fixed mode
requires a trusted Go/x-crypto helper and proves both hash directions at cost10.
No server, compiler or Docker process is started by this script itself.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default=os.environ.get('BASE'))
p.add_argument('--database-url', default=os.environ.get('DATABASE_URL'))
p.add_argument('--expect-rejected', action='store_true')
p.add_argument('--go-helper', nargs='+')
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
if not a.base or not a.database_url:
    p.error('BASE and DATABASE_URL are required')
if not a.expect_rejected and not a.go_helper:
    p.error('fixed-mode interop requires --go-helper EXECUTABLE [ARG...]')
assert not a.out.exists(), 'preserve previous attempts'
pg = os.environ.copy()
url = urllib.parse.urlsplit(a.database_url)
pg['PGDATABASE'] = urllib.parse.unquote(url.path.lstrip('/'))
for key,value in [('PGHOST',url.hostname),('PGPORT',str(url.port or 5432)),
                  ('PGUSER',urllib.parse.unquote(url.username or '')),
                  ('PGPASSWORD',urllib.parse.unquote(url.password or ''))]:
    if value and key not in pg:
        pg[key] = value
if not pg['PGDATABASE'].startswith('mc_pair_'):
    p.error('requires a dedicated owned mc_pair_ database clone')
cmd = ['psql','-X','-A','-t','-q','-v','ON_ERROR_STOP=1','-d',pg['PGDATABASE']]
nonce = 'nul_password_'+uuid.uuid4().hex
record = {'scope':'Disposable password-input correctness and trusted bcrypt interoperability',
          'database':pg['PGDATABASE'],'base':a.base,'nonce':nonce,
          'expectation':'baseline-rejection' if a.expect_rejected else 'accepted-full-bcrypt',
          'started_unix_s':time.time(),'pass':False,'implementation_correct':False,'cases':[]}
a.out.parent.mkdir(parents=True,exist_ok=True)
a.out.write_text(json.dumps(record,indent=2)+'\n')

def quote(value):
    assert '\0' not in value
    return "'"+value.replace("'","''")+"'"

def sql(text):
    r = subprocess.run(cmd+['-c',text],env=pg,text=True,capture_output=True,timeout=20)
    if r.returncode:
        raise RuntimeError(r.stderr)
    return r.stdout.strip()

def api(path,body):
    req = urllib.request.Request(a.base.rstrip('/')+path,data=json.dumps(body).encode(),
                                 method='POST',headers={'Content-Type':'application/json'})
    try:
        response = urllib.request.urlopen(req,timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return {'status':response.code,'body':json.loads(response.read())}

passwords = ['prefix\0suffix','é\0🙂','é'*35+'\0x']
assert [len(p.encode()) for p in passwords]==[13,7,72]
try:
    items = []
    for i,password in enumerate(passwords):
        name,email = nonce+'_'+str(i),nonce+'_'+str(i)+'@example.com'
        result = api('/api/users',{'user':{'username':name,'email':email,'password':password}})
        case = {'index':i,'password_bytes':len(password.encode()),'register_status':result['status']}
        record['cases'].append(case)
        if a.expect_rejected:
            assert result['status']==422, result
            assert sql('SELECT count(*) FROM users WHERE username='+quote(name))=='0'
            case['baseline_bug_observed'] = True
            continue
        assert result['status']==201, result
        stored = sql('SELECT password_hash FROM users WHERE username='+quote(name))
        assert stored.startswith('$2b$10$') and len(stored)==60, stored
        full = api('/api/users/login',{'user':{'email':email,'password':password}})
        prefix = password.split('\0',1)[0]
        bad = api('/api/users/login',{'user':{'email':email,'password':prefix}})
        assert full['status']==200 and full['body']['user']['email']==email, full
        assert bad['status']==401, bad
        case.update(full_login_status=full['status'],prefix_login_status=bad['status'],stored_hash=stored)
        items.append({'password':password,'prefix':prefix,'hash':stored})
    if not a.expect_rejected:
        trusted = subprocess.run(a.go_helper,input=json.dumps({'items':items}),text=True,
                                 capture_output=True,timeout=180)
        record['trusted_helper'] = {'command':a.go_helper,'exit':trusted.returncode,'stderr':trusted.stderr}
        assert trusted.returncode==0, trusted.stderr
        checked = json.loads(trusted.stdout)
        assert len(checked)==len(items)
        for i,(case,proof,password) in enumerate(zip(record['cases'],checked,passwords)):
            assert proof['stored_cost']==10 and proof['full_verify'] is True and proof['prefix_verify'] is False, proof
            generated = proof['generated_hash']
            assert generated.startswith('$2a$10$') or generated.startswith('$2b$10$')
            name,email = nonce+'_go_'+str(i),nonce+'_go_'+str(i)+'@example.com'
            sql('INSERT INTO users(username,email,password_hash) VALUES ('+quote(name)+','+quote(email)+','+quote(generated)+')')
            full = api('/api/users/login',{'user':{'email':email,'password':password}})
            bad = api('/api/users/login',{'user':{'email':email,'password':password.split('\0',1)[0]}})
            assert full['status']==200 and full['body']['user']['email']==email
            assert bad['status']==401
            case.update(trusted_go=proof,go_hash_full_login_status=full['status'],go_hash_prefix_login_status=bad['status'])
        # NUL remains invalid in PostgreSQL text fields; the relaxation is only
        # for plaintext passwords, which never enter those columns.
        text_checks = []
        for user in [{'username':'bad\0name','email':nonce+'_badname@example.com','password':'ordinary'},
                     {'username':nonce+'_bademail','email':'bad\0@example.com','password':'ordinary'},
                     {'username':nonce+'_long','email':nonce+'_long@example.com','password':'p'*73}]:
            result = api('/api/users',{'user':user})
            assert result['status']==422, result
            text_checks.append(result['status'])
        record['unchanged_text_and_length_guards'] = text_checks
    record['pass'] = True
    record['implementation_correct'] = not a.expect_rejected
except BaseException as error:
    record['error'] = type(error).__name__+': '+str(error)
finally:
    try:
        sql('DELETE FROM users WHERE left(username,'+str(len(nonce))+')='+quote(nonce))
        assert sql('SELECT count(*) FROM users WHERE left(username,'+str(len(nonce))+')='+quote(nonce))=='0'
        record['fixtures_cleaned'] = True
    except Exception as error:
        record.update({'pass':False,'cleanup_error':type(error).__name__+': '+str(error)})
    record['finished_unix_s'] = time.time()
    a.out.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:record.get(k) for k in ['pass','expectation','implementation_correct','fixtures_cleaned','error']}))
raise SystemExit(0 if record['pass'] else 1)
