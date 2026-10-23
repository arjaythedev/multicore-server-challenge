#!/usr/bin/env python3
"""Deterministic favorite snapshot race on an owned, disposable test database.

Inputs: DATABASE_URL (target DB), normal PG* superuser credentials, BASE,
JWT_SECRET; optional --out. Never use a seed template directly.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import hashlib
import hmac
import json
import os
import pathlib
import select
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default=os.environ.get('BASE'))
p.add_argument('--secret', default=os.environ.get('JWT_SECRET'))
p.add_argument('--database-url', default=os.environ.get('DATABASE_URL'))
p.add_argument('--out', default='favorite-race-probe.json')
a = p.parse_args()
if not a.base or not a.secret:
    p.error('BASE and JWT_SECRET, or --base and --secret, are required')

pg_env = os.environ.copy()
if a.database_url:
    u = urllib.parse.urlsplit(a.database_url)
    pg_env['PGDATABASE'] = urllib.parse.unquote(u.path.lstrip('/'))
    for k, v in [('PGHOST', u.hostname), ('PGPORT', str(u.port or 5432)),
                 ('PGUSER', urllib.parse.unquote(u.username or '')),
                 ('PGPASSWORD', urllib.parse.unquote(u.password or ''))]:
        if v and k not in pg_env:
            pg_env[k] = v
dbname = pg_env.get('PGDATABASE', '')
if not dbname or dbname in {'postgres', 'template0', 'template1', 'conduit_seed', 'conduit_dev'}:
    p.error('requires a disposable database clone, never a seed or system database')

cmd = ['psql', '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-d', dbname]
record = {'scope': 'deterministic two-transaction favorite count correctness probe',
          'base': a.base, 'database': dbname, 'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
          'pass': False, 'events': []}
nonce = 'favorite_probe_' + uuid.uuid4().hex
fixture_ids = None
t1 = None

def event(name, **kwargs):
    record['events'].append({'event': name, 'at_monotonic': time.monotonic(), **kwargs})

def sql(text):
    r = subprocess.run(cmd + ['-c', text], env=pg_env, text=True, capture_output=True, timeout=15)
    if r.returncode:
        raise RuntimeError('psql failed: ' + r.stderr.strip())
    return r.stdout.strip()

def send(text):
    t1.stdin.write(text + '\n')
    t1.stdin.flush()

def marker(want, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if t1.poll() is not None:
            raise RuntimeError('transaction process exited: ' + t1.stderr.read())
        ready, _, _ = select.select([t1.stdout], [], [], min(0.1, max(0, deadline-time.monotonic())))
        if ready:
            line = t1.stdout.readline().strip()
            if line == want:
                return
    raise TimeoutError('no transaction marker ' + want)

def enc(b):
    return base64.urlsafe_b64encode(b).decode().rstrip('=')

def jwt(uid):
    now = int(time.time())
    b = '.'.join(enc(json.dumps(x, separators=(',', ':')).encode()) for x in
                 [{'alg': 'HS256', 'typ': 'JWT'}, {'sub': str(uid), 'iat': now, 'exp': now + 600}])
    return b + '.' + enc(hmac.digest(a.secret.encode(), b.encode(), 'sha256'))

def api(method, path, tok):
    req = urllib.request.Request(a.base.rstrip('/') + path,
                                 data=b'' if method == 'POST' else None,
                                 method=method, headers={'Authorization': 'Token ' + tok})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            status, body = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    return {'status': status, 'body': json.loads(body)}

try:
    # Fresh fixture gives an exact expected count, independent of the seed's favorites.
    # This bcrypt hash is the public cost-10 seed fixture, never an authentication shortcut.
    rows = sql("BEGIN; "
        "INSERT INTO users(username,email,password_hash) VALUES "
        f"('{nonce}_a','{nonce}_a@example.com','$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq'),"
        f"('{nonce}_b','{nonce}_b@example.com','$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq'); "
        "INSERT INTO articles(slug,author_id,title,description,body) "
        f"SELECT '{nonce}',id,'race probe','dedicated test fixture','probe body' FROM users WHERE username='{nonce}_a'; "
        f"SELECT (SELECT id FROM users WHERE username='{nonce}_a'),"
        f"(SELECT id FROM users WHERE username='{nonce}_b'),"
        f"(SELECT id FROM articles WHERE slug='{nonce}'); COMMIT;")
    uid_a, uid_b, aid = [int(v) for v in rows.splitlines()[-1].split('|')]
    fixture_ids = (uid_a, uid_b, aid)
    tok = jwt(uid_a)
    record['fixture'] = {'user_a': uid_a, 'user_b': uid_b, 'article': aid, 'slug': nonce}
    before = api('GET', '/api/articles/' + nonce, tok)
    assert before['status'] == 200 and before['body']['article']['favoritesCount'] == 0, before
    event('fresh fixture visible', count=0)

    t1 = subprocess.Popen(cmd, env=pg_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, bufsize=1)
    send(f"BEGIN; INSERT INTO favorites(user_id,article_id) VALUES ({uid_a},{aid}),({uid_b},{aid}); SELECT 'LOCK_HELD';")
    marker('LOCK_HELD')
    event('transaction T1 inserted two favorites without committing')
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(api, 'POST', '/api/articles/' + nonce + '/favorite', tok)
        # Witness the API backend actually waiting on T1's unique-key conflict.
        # A sleep alone cannot establish that the request took its snapshot before COMMIT.
        deadline = time.monotonic() + 10
        witness = None
        while time.monotonic() < deadline:
            waiting = sql("SELECT json_agg(json_build_object('pid',pid,'wait_event_type',wait_event_type,"
                          "'wait_event',wait_event,'query',query)) FROM pg_stat_activity "
                          "WHERE datname=current_database() AND pid<>pg_backend_pid() "
                          "AND wait_event_type='Lock' AND query ILIKE '%favorites%'")
            if waiting and waiting != 'null':
                witness = json.loads(waiting)
                break
            if future.done():
                raise AssertionError('API returned before blocked-write witness: ' + repr(future.result()))
            time.sleep(0.03)
        if witness is None:
            raise TimeoutError('API did not show the expected blocked INSERT')
        event('API backend blocked on T1', witness=witness)
        send("COMMIT; SELECT 'COMMITTED';")
        marker('COMMITTED')
        event('transaction T1 committed')
        response = future.result(timeout=10)
    record['favorite_response'] = response
    committed = int(sql(f'SELECT count(*) FROM favorites WHERE article_id={aid}'))
    immediate = api('GET', '/api/articles/' + nonce, tok)
    record['committed_count'] = committed
    record['immediate_get'] = immediate
    record['pass'] = (committed == 2 and response['status'] == 200
                      and response['body']['article']['favoritesCount'] == committed
                      and response['body']['article']['favorited'] is True
                      and immediate['status'] == 200
                      and immediate['body']['article']['favoritesCount'] == committed
                      and immediate['body']['article']['favorited'] is True)
    event('comparison complete', response_count=response['body'].get('article', {}).get('favoritesCount'),
          committed_count=committed, passed=record['pass'])
except BaseException as e:
    record['error'] = type(e).__name__ + ': ' + str(e)
finally:
    if t1 is not None:
        with contextlib.suppress(Exception):
            send('ROLLBACK;')
            t1.stdin.close()
            t1.wait(timeout=3)
        if t1.poll() is None:
            t1.terminate()
            t1.wait(timeout=3)
        record['transaction_stderr'] = t1.stderr.read()
    if fixture_ids:
        uid_a, uid_b, aid = fixture_ids
        try:
            sql(f'BEGIN; DELETE FROM articles WHERE id={aid}; DELETE FROM users WHERE id IN ({uid_a},{uid_b}); COMMIT;')
            record['fixture_cleaned'] = True
        except Exception as e:
            record['fixture_cleaned'] = False
            record['cleanup_error'] = str(e)
            record['pass'] = False
    pathlib.Path(a.out).write_text(json.dumps(record, indent=2) + '\n')

print(json.dumps({k: record.get(k) for k in ['pass', 'committed_count', 'fixture_cleaned', 'error']}))
raise SystemExit(0 if record['pass'] else 1)
