#!/usr/bin/env python3
"""Deterministic update snapshot and favorite/rename races on a disposable DB.

No server, compiler or Docker process is started. The caller owns setup and scheduling.
--expect-stale is a baseline reproduction mode, not a correctness pass.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import hmac
import json
import os
from pathlib import Path
import select
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default=os.environ.get('BASE'))
p.add_argument('--database-url', default=os.environ.get('DATABASE_URL'))
p.add_argument('--secret', default=os.environ.get('JWT_SECRET'))
p.add_argument('--case', choices=['all','update','favorite-rename'], default='all')
p.add_argument('--expect-stale', action='store_true')
p.add_argument('--out', type=Path, required=True)
a = p.parse_args()
if not a.base or not a.database_url or not a.secret:
    p.error('BASE, DATABASE_URL and JWT_SECRET are required')
assert not a.out.exists(), 'preserve prior attempts: choose a new output'
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
record = {'scope':'Disposable correctness fixtures only; no schema/config changes',
          'database':pg['PGDATABASE'],'base':a.base,'expectation':'baseline-stale' if a.expect_stale else 'fresh',
          'started_unix_s':time.time(),'cases':[],'pass':False,'implementation_correct':False}
a.out.parent.mkdir(parents=True,exist_ok=True)
a.out.write_text(json.dumps(record,indent=2)+'\n')

def quote(value):
    return "'"+value.replace("'","''")+"'"

def sql(text):
    result = subprocess.run(cmd+['-c',text],env=pg,text=True,capture_output=True,timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()

def token(uid):
    now = int(time.time())
    enc = lambda x:base64.urlsafe_b64encode(json.dumps(x,separators=(',',':')).encode()).decode().rstrip('=')
    text = enc({'alg':'HS256','typ':'JWT'})+'.'+enc({'sub':str(uid),'iat':now,'exp':now+600})
    return text+'.'+base64.urlsafe_b64encode(hmac.digest(a.secret.encode(),text.encode(),'sha256')).decode().rstrip('=')

def api(method,path,auth,body=None):
    req = urllib.request.Request(a.base.rstrip('/')+path,
        data=json.dumps(body).encode() if body is not None else (b'' if method=='POST' else None),
        method=method,headers={'Authorization':'Token '+auth,'Content-Type':'application/json'})
    start = time.monotonic()
    try:
        response = urllib.request.urlopen(req,timeout=25)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return {'status':response.code,'body':json.loads(response.read()),
                'start_monotonic':start,'complete_monotonic':time.monotonic()}

def marker(proc,want,timeout=10):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        if proc.poll() is not None:
            raise RuntimeError('transaction exited: '+proc.stderr.read())
        ready,_,_ = select.select([proc.stdout],[],[],min(.1,max(.001,deadline-time.monotonic())))
        if ready and proc.stdout.readline().strip()==want:
            return
    raise TimeoutError('missing transaction marker '+want)

def transaction_send(proc,text):
    proc.stdin.write(text+'\n')
    proc.stdin.flush()

def run_case(kind):
    nonce = 'article_race_'+uuid.uuid4().hex
    state = {'case':kind,'nonce':nonce,'events':[],'pass':False}
    record['cases'].append(state)
    proc = None
    ids = None
    try:
        text = sql("BEGIN; INSERT INTO users(username,email,password_hash) VALUES ("+
            quote(nonce)+','+quote(nonce+'@example.com')+","+
            quote('$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq')+") RETURNING id; "+
            "INSERT INTO articles(slug,author_id,title,description,body) SELECT "+quote(nonce)+",id,'before','fixture','before body' FROM users WHERE username="+quote(nonce)+"; "+
            "SELECT u.id,a.id FROM users u JOIN articles a ON a.author_id=u.id WHERE u.username="+quote(nonce)+"; COMMIT;")
        uid,aid = [int(x) for x in text.splitlines()[-1].split('|')]
        ids = uid,aid
        auth = token(uid)
        old_path = '/api/articles/'+urllib.parse.quote(nonce,safe='')
        before = api('GET',old_path,auth)
        assert before['status']==200 and before['body']['article']['favoritesCount']==0
        proc = subprocess.Popen(cmd,env=pg,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,text=True,bufsize=1)
        if kind=='update':
            transaction_send(proc,f"BEGIN; DO $gate$ BEGIN PERFORM 1 FROM articles WHERE id={aid} FOR UPDATE; END $gate$; "+
                             f"INSERT INTO favorites(user_id,article_id) VALUES({uid},{aid}); SELECT 'LOCK_HELD';")
            request = ('PUT',old_path,auth,{'article':{'title':nonce+' updated','body':'updated body — Unicode'}})
            query_match = '%UPDATE articles%'
        else:
            renamed = nonce+'-renamed'
            transaction_send(proc,f"BEGIN; INSERT INTO favorites(user_id,article_id) VALUES({uid},{aid}); "+
                'UPDATE articles SET slug='+quote(renamed)+",title='renamed concurrently',updated_at=now() WHERE id="+str(aid)+"; SELECT 'LOCK_HELD';")
            request = ('POST',old_path+'/favorite',auth,None)
            query_match = '%INSERT INTO favorites%'
        marker(proc,'LOCK_HELD')
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(api,*request)
            deadline = time.monotonic()+12
            witness = None
            while time.monotonic()<deadline:
                text = sql("SELECT json_agg(json_build_object('pid',pid,'wait_type',wait_event_type,'wait',wait_event,'query',query)) "+
                    "FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() "+
                    "AND wait_event_type='Lock' AND query ILIKE "+quote(query_match))
                if text and text!='null':
                    witness = json.loads(text)
                    break
                assert not future.done(), 'API returned before its blocked mutation was witnessed'
                time.sleep(.03)
            assert witness, 'no blocked API mutation was witnessed'
            state['events'].append({'event':'API blocked on uncommitted transaction','witness':witness})
            transaction_send(proc,"COMMIT; SELECT 'COMMITTED';")
            marker(proc,'COMMITTED')
            state['events'].append({'event':'fixture favorite/rename committed','monotonic':time.monotonic()})
            response = future.result(timeout=15)
        committed = int(sql(f'SELECT count(*) FROM favorites WHERE article_id={aid}'))
        current_slug = sql(f'SELECT slug FROM articles WHERE id={aid}')
        immediate = api('GET','/api/articles/'+urllib.parse.quote(current_slug,safe=''),auth)
        assert committed==1 and immediate['status']==200
        assert immediate['body']['article']['favoritesCount']==1 and immediate['body']['article']['favorited'] is True
        state.update(response=response,committed_count=committed,current_slug=current_slug,immediate_get=immediate)
        fresh = response['status']==200 and response['body'].get('article')==immediate['body']['article']
        if kind=='update':
            assert immediate['body']['article']['title']==nonce+' updated'
            assert immediate['body']['article']['body']=='updated body — Unicode'
            assert current_slug!=nonce and current_slug.endswith('-'+str(aid))
            stale = response['status']==200 and response['body']['article']['favoritesCount']==0 and response['body']['article']['favorited'] is False
        else:
            assert current_slug==renamed
            stale = response['status']==404
        state.update(implementation_correct=fresh,baseline_bug_observed=stale,
                     pass_expected_behavior=stale if a.expect_stale else fresh)
        assert state['pass_expected_behavior'], 'response did not match selected baseline/fixed expectation'
        state['pass'] = True
    except BaseException as error:
        state['error'] = type(error).__name__+': '+str(error)
    finally:
        if proc is not None:
            with contextlib.suppress(Exception):
                transaction_send(proc,'ROLLBACK;')
                proc.stdin.close()
                proc.wait(timeout=3)
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=3)
            state['transaction_stderr'] = proc.stderr.read()
        if ids:
            try:
                uid,aid = ids
                sql(f'BEGIN; DELETE FROM articles WHERE id={aid}; DELETE FROM users WHERE id={uid}; COMMIT;')
                assert sql(f'SELECT count(*) FROM articles WHERE id={aid}')=='0'
                assert sql(f'SELECT count(*) FROM users WHERE id={uid}')=='0'
                state['fixture_cleaned'] = True
            except Exception as error:
                state.update({'pass':False,'cleanup_error':type(error).__name__+': '+str(error)})
        a.out.write_text(json.dumps(record,indent=2)+'\n')

for kind in (['update','favorite-rename'] if a.case=='all' else [a.case]):
    run_case(kind)
record['pass'] = all(c['pass'] for c in record['cases'])
record['implementation_correct'] = all(c.get('implementation_correct') for c in record['cases'])
record['finished_unix_s'] = time.time()
a.out.write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'pass':record['pass'],'expectation':record['expectation'],
                  'implementation_correct':record['implementation_correct'],
                  'cases':[{k:c.get(k) for k in ['case','pass','baseline_bug_observed','fixture_cleaned','error']}
                           for c in record['cases']]}))
raise SystemExit(0 if record['pass'] else 1)
