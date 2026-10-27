#!/usr/bin/env python3
"""Check profiles/follows, transaction boundaries and the unchanged upstream contract."""
import concurrent.futures
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
from urllib.parse import quote

from support import Server as DisposableServer, literal, raw_response, sql, upstream
from support import mint as issue_token

submission = Path(__file__).resolve().parents[1]
repo = submission.parents[1]
work = Path(os.environ['CHALLENGE_WORK'])
results = work / 'results/milestone3'
results.mkdir(parents=True, exist_ok=True)
secret = 'milestone-profiles-test-only'
checks = []


def Server(label, executable):
    return DisposableServer(results, secret, 'profiles', label, executable)


def mint(identifier, expiry=None):
    return issue_token(identifier, secret, expiry)


def check_profile(response, name, following, bio=None, image=None):
    assert response == (200, {'profile': {'username': name, 'bio': bio, 'image': image, 'following': following}}), response
    assert type(response[1]['profile']['following']) is bool


def path_for(name):
    return '/api/profiles/' + quote(name, safe='')


def passed(name):
    checks.append(name)


@contextmanager
def blocked_writes(server):
    locker = subprocess.Popen(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At', '-d', server.database,
                               '-c', 'BEGIN; LOCK TABLE follows IN SHARE MODE; SELECT pg_sleep(1.5); COMMIT;'],
                              env=dict(os.environ, PGAPPNAME='milestone-profiles-lock'),
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 3
        while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND application_name='milestone-profiles-lock' AND wait_event='PgSleep'") != '1':
            assert time.monotonic() < deadline
            time.sleep(0.01)
        yield
    finally:
        if locker.poll() is None:
            locker.terminate()
        locker.wait(timeout=5)


conformance = work / 'tools/conformance'
reference = work / 'tools/reference-go'
subprocess.run(['go', 'build', '-o', str(conformance), './cmd/conformance'], cwd=repo / 'bench', check=True)
subprocess.run(['go', 'build', '-o', str(reference), '.'], cwd=repo / 'examples/go', check=True)
with Server('zig', submission / 'zig-out/bin/conduit') as zig, Server('go', reference) as go:
    run, transcript, steps, summary = upstream(zig, 'upstream', conformance)
    golden_run, golden, _, golden_summary = upstream(go, 'reference', conformance)
    assert golden_run.returncode == 0, golden_run.stdout
    auth_steps = [line for line in steps if re.match(r'^PASS (users\.|user\.)', line)]
    profile_steps = [line for line in steps if line.startswith('PASS profile.')]
    assert len(auth_steps) == 50 and len(profile_steps) >= 16
    assert not any(line.startswith('FAIL tags.') for line in run.stdout.splitlines())
    passed(f'unchanged upstream: 50 users/auth and all {len(profile_steps)} reached profile steps passed')
    normalized = {step['step']: step for step in golden}
    profiles = [step for step in transcript if step['step'].startswith('profile.')]
    assert len(profiles) == len(profile_steps)
    assert all(step == normalized[step['step']] for step in profiles)
    passed(f'all {len(profiles)} normalized upstream profile responses match the unchanged Go reference')
    print('Zig full upstream run: ' + summary, flush=True)
    print('Unchanged Go reference: ' + golden_summary, flush=True)

    # Apply the same ordinary operation trace to independent databases.
    special_names = ['m3+plus', 'm3 plus', 'm3/a', 'm3%2F', 'm3_é', 'm3?x', 'm3#x', "m3'; SELECT 1; --"]
    accounts = {}
    for server in (zig, go):
        identifiers = {name: server.fixture(name) for name in ['m3_alice', 'm3_bob', 'm3_target', *special_names]}
        accounts[server] = identifiers
    alice = mint(accounts[zig]['m3_alice'])
    bob = mint(accounts[zig]['m3_bob'])
    target = path_for('m3_target')
    trace = [
        ('GET', target, None, False),
        ('POST', target + '/follow', 'm3_alice', True),
        ('POST', target + '/follow', 'm3_alice', True),
        ('GET', target, 'm3_alice', True),
        ('GET', target, 'm3_bob', False),
        ('GET', target, None, False),
        ('DELETE', target + '/follow', 'm3_alice', False),
        ('DELETE', target + '/follow', 'm3_alice', False),
        ('GET', target, 'm3_alice', False),
    ]
    for method, path, viewer, following in trace:
        responses = [server.request(method, path, mint(accounts[server][viewer]) if viewer else None) for server in (zig, go)]
        assert responses[0] == responses[1]
        check_profile(responses[0], 'm3_target', following)
    passed('Go/Zig operation trace: nullable fields, repeated follow/unfollow and viewer isolation')

    for name in special_names:
        responses = [server.request('GET', path_for(name)) for server in (zig, go)]
        assert responses[0] == responses[1]
        check_profile(responses[0], name, False)
    check_profile(zig.request('GET', '/api/profiles/m3+plus'), 'm3+plus', False)
    assert zig.request('GET', '/api/profiles/m3/a')[0] == 404
    check_profile(zig.request('POST', path_for('m3/a') + '/follow', alice), 'm3/a', True)
    check_profile(zig.request('GET', path_for('m3%2F')), 'm3%2F', False)
    passed('single-pass URL decoding: plus, space, encoded slash, percent, Unicode, query characters and quotes')

    for method, path in [('GET', target), ('POST', target + '/follow'), ('DELETE', target + '/follow')]:
        for header in ['', 'Token ', 'Token garbage', 'Bearer ' + alice, 'Token ' + mint(accounts[zig]['m3_alice'], int(time.time()) - 1)]:
            assert zig.request(method, path, headers={'Authorization': header})[0] == 401
    for method in ['POST', 'DELETE']:
        assert zig.request(method, target + '/follow')[0] == 401
        assert zig.request(method, '/api/profiles/missing/follow')[0] == 401
        assert zig.request(method, '/api/profiles/missing/follow', alice)[0] == 404
    assert zig.request('GET', '/api/profiles/missing', headers={'Authorization': 'bad'})[0] == 401
    check_profile(zig.request('GET', target, mint(999_999_999)), 'm3_target', False)
    # Deliberate reference divergence: SPEC requires 401 for a present empty header.
    assert go.request('GET', target, headers={'Authorization': ''})[0] == 200
    passed('strict optional/required auth, including SPEC-correct rejection of empty headers')

    relation = f"follower_id={accounts[zig]['m3_alice']} AND followee_id={accounts[zig]['m3_target']}"
    for method, expected, count in [('POST', True, '1'), ('POST', True, '1'), ('DELETE', False, '0'), ('DELETE', False, '0')]:
        check_profile(zig.request(method, target + '/follow', alice), 'm3_target', expected)
        assert zig.sql('SELECT count(*) FROM follows WHERE ' + relation) == count
    passed('idempotent follow/unfollow commits exactly the expected relation count')

    self_path = path_for('m3_alice')
    for method, following in [('POST', True), ('DELETE', False)]:
        answers = [server.request(method, self_path + '/follow', mint(accounts[server]['m3_alice'])) for server in (zig, go)]
        assert answers[0] == answers[1]
        check_profile(answers[0], 'm3_alice', following)
    passed('self-follow behaviour matches the fixed schema and Go reference')

    zig.sql(f"INSERT INTO follows(follower_id,followee_id) VALUES ({accounts[zig]['m3_alice']},{accounts[zig]['m3_target']})")
    check_profile(zig.request('GET', target, alice), 'm3_target', True)
    check_profile(zig.request('GET', target, bob), 'm3_target', False)
    zig.sql('DELETE FROM follows WHERE ' + relation)
    check_profile(zig.request('GET', target, alice), 'm3_target', False)
    target_token = mint(accounts[zig]['m3_target'])
    renamed = 'm3_target_new_é'
    assert zig.request('PUT', '/api/user', target_token, {'user': {'username': renamed, 'bio': '', 'image': 'https://example.com/p.png'}})[0] == 200
    assert zig.request('GET', target)[0] == 404
    check_profile(zig.request('GET', path_for(renamed) + '?ignored=/follow'), renamed, False, '', 'https://example.com/p.png')
    assert zig.request('PUT', '/api/user', target_token, {'user': {'username': 'm3_target'}})[0] == 200
    passed('fresh relationship/profile reads after external mutation and username change')

    # Body bytes are consumed even though these endpoints have no JSON body contract.
    wire = (f'POST {target}/follow HTTP/1.1\r\nHost: x\r\nAuthorization: Token {alice}\r\nContent-Length: 3\r\n\r\nbad'
            f'GET {target} HTTP/1.1\r\nHost: x\r\nAuthorization: Token {alice}\r\n\r\n'
            f'GET {target} HTTP/1.1\r\nHost: x\r\nAuthorization: Token {bob}\r\n\r\n'
            f'GET {target} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n').encode()
    with socket.create_connection(('127.0.0.1', zig.port), timeout=10) as client:
        client.sendall(wire[:25])
        time.sleep(0.02)
        client.sendall(wire[25:])
        with client.makefile('rb') as reader:
            for following in [True, True, False, False]:
                check_profile(raw_response(reader), 'm3_target', following, '', 'https://example.com/p.png')
            assert reader.read(1) == b''
    passed('fragmented/pipelined follow and reads preserve bytes, response order and per-request identity')

    for encoded, expected in [('bad%', 400), ('bad%GG', 400), ('bad%00', 422), ('%FF', 422)]:
        assert zig.request('GET', '/api/profiles/' + encoded)[0] == expected
    for method, suffix in [('PUT', '/follow'), ('POST', '/follow/extra'), ('GET', '/extra')]:
        assert zig.request(method, target + suffix, alice)[0] == 404
    assert zig.request('GET', '/api/tags')[0] == 200
    passed('invalid path encodings and unmatched routes fail without breaking later requests')

    # One pair, many connections: duplicates remain idempotent under contention.
    for method, following, expected_count in [('POST', True, '1'), ('DELETE', False, '0')]:
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            responses = list(pool.map(lambda _: zig.request(method, target + '/follow', alice), range(32)))
        for response in responses:
            check_profile(response, 'm3_target', following, '', 'https://example.com/p.png')
        assert zig.sql('SELECT count(*) FROM follows WHERE ' + relation) == expected_count
    passed('64 concurrent repeated follow/unfollow requests leave one row or zero as required')

    # Lock injection checks that no optimistic success escapes before either write commits.
    for method, previous, committed in [('POST', '0', '1'), ('DELETE', '1', '0')]:
        with blocked_writes(zig), concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(zig.request, method, target + '/follow', alice)
            deadline = time.monotonic() + 1
            while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{zig.database}' AND usename='conduit' AND wait_event_type='Lock'") != '1':
                assert time.monotonic() < deadline
                time.sleep(0.01)
            assert not future.done()
            assert zig.sql('SELECT count(*) FROM follows WHERE ' + relation) == previous
            assert future.result(timeout=5)[0] == 200
            assert zig.sql('SELECT count(*) FROM follows WHERE ' + relation) == committed
    passed('blocked follow and unfollow withhold success; a separate session observes the committed state')

    # In this disposable clone only, fail at COMMIT after the INSERT has executed.
    zig.sql("""CREATE FUNCTION milestone_reject_follow_commit() RETURNS trigger LANGUAGE plpgsql AS $$
               BEGIN RAISE EXCEPTION 'milestone deferred commit failure'; RETURN NEW; END $$;
               CREATE CONSTRAINT TRIGGER milestone_reject_follow_commit AFTER INSERT ON follows
               DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION milestone_reject_follow_commit();""")
    try:
        assert zig.request('POST', target + '/follow', alice)[0] == 503
        assert zig.sql('SELECT count(*) FROM follows WHERE ' + relation) == '0'
        check_profile(zig.request('GET', target, alice), 'm3_target', False, '', 'https://example.com/p.png')
    finally:
        zig.sql('DROP TRIGGER milestone_reject_follow_commit ON follows; DROP FUNCTION milestone_reject_follow_commit()')
    assert zig.request('POST', target + '/follow', alice)[0] == 200
    assert zig.sql('SELECT count(*) FROM follows WHERE ' + relation) == '1'
    assert zig.request('DELETE', target + '/follow', alice)[0] == 200
    passed('deferred COMMIT failure returns 503, rolls back the row and leaves the connection reusable')

    zig.sql('ALTER TABLE follows RENAME TO follows_unavailable')
    try:
        for method, path in [('GET', target), ('POST', target + '/follow'), ('DELETE', target + '/follow')]:
            assert zig.request(method, path, alice)[0] == 503
    finally:
        zig.sql('ALTER TABLE follows_unavailable RENAME TO follows')
    assert zig.request('POST', target + '/follow', alice)[0] == 200
    assert zig.request('DELETE', target + '/follow', alice)[0] == 200
    passed('SQL errors for all three routes drain cleanly and recover after the table is restored')

    with blocked_writes(zig):
        client = socket.create_connection(('127.0.0.1', zig.port), timeout=5)
        try:
            client.sendall(f'POST {target}/follow HTTP/1.1\r\nHost: x\r\nAuthorization: Token {alice}\r\nContent-Length: 0\r\n\r\n'.encode())
            deadline = time.monotonic() + 1
            while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{zig.database}' AND usename='conduit' AND wait_event_type='Lock'") != '1':
                assert time.monotonic() < deadline
                time.sleep(0.01)
            client.close()
            assert zig.request('GET', '/api/tags')[0] == 200
            deadline = time.monotonic() + 3
            while zig.sql('SELECT count(*) FROM follows WHERE ' + relation) != '1':
                assert time.monotonic() < deadline
                time.sleep(0.01)
        finally:
            client.close()
    check_profile(zig.request('GET', target, alice), 'm3_target', True, '', 'https://example.com/p.png')
    passed('disconnect during a blocked follow preserves transaction draining and later client responses')

    assert zig.process.poll() is None
    evidence = {'milestone': 3, 'checks': checks, 'upstream_users_auth_steps': len(auth_steps),
                'upstream_profile_steps_reached': len(profile_steps), 'profile_transcripts_equal_to_reference': len(profiles),
                'upstream_full_summary': summary, 'upstream_exit_status': run.returncode,
                'reference_summary': golden_summary, 'reference_exit_status': golden_run.returncode,
                'reference_divergence': 'An empty Authorization header returns 401 as SPEC requires; Go treats it as absent.',
                'scope': 'native Mac correctness; no linked Linux or capacity claim'}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: {len(checks)} profile scenarios; 50 upstream auth and {len(profile_steps)} reached profile steps passed', flush=True)
