#!/usr/bin/env python3
"""Black-box runtime correctness probe against an owned disposable DB clone.

Run only against a dedicated correctness server, e.g. WORKERS=1 WRITE_BATCH_US=50000.
Inputs BASE, DATABASE_URL, JWT_SECRET, normal administrative PG* credentials.
No compiler/server/Docker is started. A temporary deferred test trigger blocks
one commit on an advisory lock; it and all uniquely named fixtures are removed.
V2 retains registration evidence before statistics checks and accommodates PG18
backend-local statistics flushing (10-second idle callback).
These fixture conditions are deliberately not performance-measurement conditions.
"""
import argparse
import base64
import concurrent.futures
import contextlib
import hmac
import json
import os
import pathlib
import select
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default=os.environ.get('BASE') or os.environ.get('BASE_URL'))
p.add_argument('--database-url', default=os.environ.get('PROBE_DATABASE_URL') or os.environ.get('DATABASE_URL'))
p.add_argument('--secret', default=os.environ.get('JWT_SECRET'))
p.add_argument('--parallel', type=int, default=16)
p.add_argument('--out', default='runtime-write-probe.json')
a = p.parse_args()
if not a.base or not a.secret:
    p.error('BASE and JWT_SECRET are required')
if a.parallel < 8 or a.parallel > 64 or a.parallel % 2:
    p.error('--parallel must be even, between8 and64')
pg_env = os.environ.copy()
if a.database_url:
    u = urllib.parse.urlsplit(a.database_url)
    pg_env['PGDATABASE'] = urllib.parse.unquote(u.path.lstrip('/'))
    for key, value in [('PGHOST', u.hostname), ('PGPORT', str(u.port or 5432)),
                       ('PGUSER', urllib.parse.unquote(u.username or '')),
                       ('PGPASSWORD', urllib.parse.unquote(u.password or ''))]:
        if value and key not in pg_env:
            pg_env[key] = value
name = pg_env.get('PGDATABASE', '')
if not name or name in {'postgres', 'template0', 'template1', 'conduit_seed', 'conduit_dev'}:
    p.error('requires an owned disposable DB clone, never a seed/system DB')
cmd = ['psql', '-X', '-q', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-d', name]
nonce = 'rtprobe_' + uuid.uuid4().hex
function = nonce + '_commit_gate'
trigger = nonce + '_deferred'
gate_user = nonce + '_commit'
lock_a = int(uuid.uuid4().hex[:7], 16) + 1
lock_b = int(uuid.uuid4().hex[:7], 16) + 1
record = {'scope': 'Correctness only: quiet writer deadline, grouped rollback and commit-before-response',
          'base': a.base, 'database': name, 'nonce': nonce,
          'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
          'pass': False, 'events': [], 'cleanup': {}}
lock_process = None
fixture_created = False
trigger_created = False
record_lock = threading.Lock()

def event(what, **data):
    with record_lock:
        record['events'].append({'event': what, 'monotonic_s': time.monotonic(), **data})

def sql(query, timeout=15):
    r = subprocess.run(cmd + ['-c', query], env=pg_env, text=True,
                       capture_output=True, timeout=timeout)
    if r.returncode:
        raise RuntimeError('psql failed: ' + r.stderr.strip())
    return r.stdout.strip()

def quote(value):
    return "'" + value.replace("'", "''") + "'"

def token(uid):
    now = int(time.time())
    enc = lambda value: base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).decode().rstrip('=')
    text = enc({'alg': 'HS256', 'typ': 'JWT'}) + '.' + enc({'sub': str(uid), 'iat': now, 'exp': now + 600})
    return text + '.' + base64.urlsafe_b64encode(hmac.digest(a.secret.encode(), text.encode(), 'sha256')).decode().rstrip('=')

def api(method, path, body=None, auth=None, headers_seen=None):
    req_headers = {'Content-Type': 'application/json'}
    if auth:
        req_headers['Authorization'] = 'Token ' + auth
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(a.base.rstrip('/') + path, data=data,
                                 headers=req_headers, method=method)
    started = time.monotonic()
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        headers_at = time.monotonic()
        if headers_seen is not None:
            headers_seen.set()
        payload = response.read()
        result = json.loads(payload) if payload else None
        return {'status': response.code, 'body': result, 'started_s': started,
                'headers_s': headers_at, 'completed_s': time.monotonic()}

def committed_user(username, expected_email):
    # A new libpq connection cannot see another transaction's uncommitted insert.
    text = sql('SELECT id,email FROM users WHERE username=' + quote(username))
    assert text, '201 response had no immediately committed user: ' + username
    uid, email = text.split('|')
    assert email == expected_email, (email, expected_email)
    return int(uid)

def rollback_count():
    # This clears only the observer snapshot; it cannot flush another backend's counters.
    return int(sql("SET stats_fetch_consistency='none'; SELECT pg_stat_clear_snapshot(); "
                   "SELECT xact_rollback FROM pg_stat_database WHERE datname=current_database()"))

def session_send(query):
    lock_process.stdin.write(query + '\n')
    lock_process.stdin.flush()

def session_marker(want, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if lock_process.poll() is not None:
            raise RuntimeError('advisory-lock session exited: ' + lock_process.stderr.read())
        ready, _, _ = select.select([lock_process.stdout], [], [], min(.1, deadline-time.monotonic()))
        if ready and lock_process.stdout.readline().strip() == want:
            return
    raise TimeoutError('missing lock-session marker ' + want)

def release_lock():
    global lock_process
    if lock_process is None:
        return
    if lock_process.poll() is None:
        try:
            session_send(f'DO $$ BEGIN PERFORM pg_advisory_unlock({lock_a},{lock_b}); END $$; SELECT \'UNLOCKED\';')
            session_marker('UNLOCKED', timeout=3)
        except Exception:
            # Closing the session also releases its advisory locks.
            lock_process.terminate()
        with contextlib.suppress(Exception):
            lock_process.stdin.close()
        try:
            lock_process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            lock_process.kill()
            lock_process.wait(timeout=3)
    lock_process = None

try:
    role = sql("SELECT current_user, current_database(), pg_is_in_recovery()")
    record['pg_context'] = role
    assert role.endswith('|f'), 'requires a writable primary'
    owner = nonce + '_owner'
    owner_email = owner + '@example.com'
    # Public seed fixture hash, not an authentication shortcut: the API still verifies JWTs.
    uid = int(sql('INSERT INTO users(username,email,password_hash) VALUES (' +
                  quote(owner) + ',' + quote(owner_email) + ',' +
                  quote('$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq') + ') RETURNING id'))
    fixture_created = True
    auth = token(uid)

    # No following HTTP request is sent to wake the worker: only its writer timer can flush.
    quiet = api('POST', '/api/articles', {'article': {'title': nonce + ' quiet',
                'description': 'quiet writer timer fixture', 'body': 'runtime probe', 'tagList': []}}, auth)
    assert quiet['status'] == 201, {'quiet_status': quiet['status'], 'body': quiet['body']}
    slug = quiet['body']['article']['slug']
    assert sql('SELECT count(*) FROM articles WHERE slug=' + quote(slug)) == '1'
    event('quiet write completed and immediately committed', elapsed_s=quiet['completed_s']-quiet['started_s'], slug=slug)
    record['quiet_write'] = {'status': 201, 'elapsed_s': quiet['completed_s']-quiet['started_s'],
                             'committed_read_after_response': True}

    # Half collide on username, half are independent peers which must survive any group rollback.
    before_rollbacks = rollback_count()
    barrier = threading.Barrier(a.parallel)
    shared = nonce + '_shared'
    def registration(index):
        username = shared if index % 2 == 0 else nonce + '_peer_' + str(index)
        email = nonce + '_' + str(index) + '@example.com'
        barrier.wait(timeout=10)
        response = api('POST', '/api/users', {'user': {'username': username, 'email': email,
                       'password': 'runtime probe password ' + str(index)}})
        out = {'index': index, 'username': username, 'email': email, 'status': response['status'],
               'elapsed_s': response['completed_s']-response['started_s']}
        if response['status'] == 201:
            ident = committed_user(username, email)
            # Also check the real authenticated read path, immediately after the DB witness.
            current = api('GET', '/api/user', auth=response['body']['user']['token'])
            assert current['status'] == 200 and current['body']['user']['email'] == email, current['status']
            out.update({'id': ident, 'immediately_committed': True, 'authenticated_read_pass': True})
        elif response['status'] != 422:
            raise AssertionError({'unexpected_registration_status': response['status'], 'index': index})
        return out
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.parallel) as executor:
        registered = list(executor.map(registration, range(a.parallel)))
    collisions = [r for r in registered if r['index'] % 2 == 0]
    peers = [r for r in registered if r['index'] % 2]
    assert sum(r['status'] == 201 for r in collisions) == 1, collisions
    assert all(r['status'] == 201 for r in peers), peers
    assert sql('SELECT count(*) FROM users WHERE username=' + quote(shared)) == '1'
    record['grouped_error_probe'] = {'registrations': registered,
        'duplicate_successes': 1, 'independent_successes': len(peers),
        'xact_rollback_before': before_rollbacks,
        'limitation': 'Concurrent peer outcomes and DB rollback counters verify the error path; exact membership of each Sync group is not instrumented.'}
    # PG18 pgstat.c: non-forced updates are limited to one per second; its idle
    # callback is10s. A fresh observer cannot force the application writer to flush.
    # With the required WORKERS=1, this benign committed update wakes that same sole
    # writer after the minimum interval. It cannot itself create a rollback.
    time.sleep(1.1)
    pulse_bio = nonce + ' statistics flush witness'
    pulse = api('PUT', '/api/user', {'user': {'bio': pulse_bio}}, auth)
    assert pulse['status'] == 200, {'statistics_pulse_status': pulse['status']}
    assert sql('SELECT bio FROM users WHERE id=' + str(uid)) == pulse_bio
    record['grouped_error_probe']['statistics_flush_assistance'] = {
        'wait_before_benign_writer_update_s': 1.1, 'update_status': pulse['status'],
        'update_committed': True, 'observer_consistency': 'none, clear snapshot, fresh connection',
        'wait_after_update_limit_s': 12,
        'pg18_source': 'https://raw.githubusercontent.com/postgres/postgres/REL_18_STABLE/src/backend/utils/activity/pgstat.c',
        'documentation': 'https://www.postgresql.org/docs/18/monitoring-stats.html#MONITORING-STATS-VIEWS'}
    after_rollbacks = before_rollbacks
    deadline = time.monotonic() + 12
    readings = []
    while time.monotonic() < deadline:
        after_rollbacks = rollback_count()
        readings.append({'monotonic_s': time.monotonic(), 'xact_rollback': after_rollbacks})
        if after_rollbacks > before_rollbacks:
            break
        time.sleep(.2)
    record['grouped_error_probe'].update(xact_rollback_after=after_rollbacks,
        rollback_delta=after_rollbacks-before_rollbacks, statistics_readings=readings)
    assert after_rollbacks > before_rollbacks, 'no PostgreSQL rollback counter increase after writer wake and idle-flush allowance'
    event('duplicate/independent registration peers passed', successes=len(peers)+1,
          expected_422=len(collisions)-1, rollback_delta=after_rollbacks-before_rollbacks)

    # A DEFERRED trigger executes at COMMIT, after INSERT RETURNING. It blocks only our gate fixture.
    # An implementation that responds to INSERT completion before Sync/commit will fail headers_seen.
    trigger_created = True  # cleanup also covers a partially failed multi-statement DDL call
    sql(f'''CREATE FUNCTION {function}() RETURNS trigger LANGUAGE plpgsql AS $probe$
            BEGIN IF NEW.username={quote(gate_user)} THEN
            PERFORM pg_advisory_xact_lock({lock_a},{lock_b}); END IF; RETURN NEW; END $probe$;
            CREATE CONSTRAINT TRIGGER {trigger} AFTER INSERT ON users
            DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION {function}();''')
    lock_process = subprocess.Popen(cmd, env=pg_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, bufsize=1)
    session_send(f'DO $$ BEGIN PERFORM pg_advisory_lock({lock_a},{lock_b}); END $$; SELECT \'LOCK_HELD\';')
    session_marker('LOCK_HELD')
    headers_seen = threading.Event()
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(api, 'POST', '/api/users', {'user': {'username': gate_user,
                                 'email': gate_user+'@example.com', 'password': 'deferred commit fixture'}},
                                 None, headers_seen)
        try:
            deadline = time.monotonic() + 15
            witness = ''
            while time.monotonic() < deadline:
                witness = sql(f'''SELECT l.pid,a.wait_event_type,a.wait_event
                    FROM pg_locks l JOIN pg_stat_activity a ON a.pid=l.pid
                    WHERE l.locktype='advisory' AND NOT l.granted
                    AND l.classid={lock_a}::oid AND l.objid={lock_b}::oid
                    AND a.datname=current_database()''')
                if witness:
                    break
                assert not headers_seen.is_set(), 'HTTP headers arrived before reaching blocked COMMIT'
                time.sleep(.02)
            assert witness, 'did not observe the deferred COMMIT actually blocked on our advisory lock'
            assert sql('SELECT count(*) FROM users WHERE username=' + quote(gate_user)) == '0'
            assert not headers_seen.wait(.2), 'HTTP headers arrived while COMMIT was blocked'
            event('commit blocked, no response headers and no committed row', pg_lock_witness=witness)
            released_at = time.monotonic()
            release_lock()
            response = future.result(timeout=20)
            assert response['status'] == 201, response['status']
            assert response['headers_s'] >= released_at, 'HTTP headers predated commit release'
            ident = committed_user(gate_user, gate_user+'@example.com')
            record['commit_gate'] = {'status': 201, 'id': ident, 'pg_lock_witness': witness,
                'row_invisible_while_commit_blocked': True, 'no_http_headers_while_commit_blocked': True,
                'headers_after_release': True, 'immediately_committed_after_response': True}
        finally:
            release_lock()
    record['pass'] = True
except Exception as error:
    record['error'] = type(error).__name__ + ': ' + str(error)
finally:
    release_lock()
    try:
        if trigger_created:
            sql(f'DROP TRIGGER IF EXISTS {trigger} ON users; DROP FUNCTION IF EXISTS {function}();')
            record['cleanup']['deferred_trigger_removed'] = True
        if fixture_created:
            sql('DELETE FROM users WHERE left(username,' + str(len(nonce)) + ')=' + quote(nonce))
            record['cleanup']['fixture_users_and_cascaded_data_removed'] = True
        assert sql('SELECT count(*) FROM pg_trigger WHERE tgname=' + quote(trigger)) == '0'
        assert sql('SELECT count(*) FROM users WHERE left(username,' + str(len(nonce)) + ')=' + quote(nonce)) == '0'
        record['cleanup']['verified'] = True
    except Exception as error:
        record['cleanup']['error'] = type(error).__name__ + ': ' + str(error)
        record['pass'] = False
    record['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    pathlib.Path(a.out).write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps({'pass': record['pass'], 'out': a.out, 'error': record.get('error'),
                  'cleanup': record['cleanup']}, indent=2))
raise SystemExit(0 if record['pass'] else 1)
