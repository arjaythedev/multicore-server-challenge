#!/usr/bin/env python3
"""Require full conformance and exercise committed writes, rollback and ownership."""
import concurrent.futures
from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import time
from urllib.parse import quote

from support import Server, free_port, literal, mint, raw_response, sql, upstream

submission = Path(__file__).resolve().parents[1]
repo = submission.parents[1]
work = Path(os.environ['CHALLENGE_WORK'])
results = work / 'results/milestone5'
results.mkdir(parents=True, exist_ok=True)
secret = 'milestone-writes-test-only'
checks = []
reference = work / 'tools/reference-go'
conformance = work / 'tools/conformance'


def passed(name):
    checks.append(name)


def path(slug):
    return '/api/articles/' + quote(slug, safe='')


def payload(title, tags=None):
    value = {'title': title, 'description': 'Description é "quoted"', 'body': 'Body\nsecond line \\ ☕'}
    if tags is not None:
        value['tagList'] = tags
    return {'article': value}


@contextmanager
def blocked_tags(server):
    locker = subprocess.Popen(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At', '-d', server.database,
                               '-c', 'BEGIN; LOCK TABLE tags IN SHARE MODE; SELECT pg_sleep(1.5); COMMIT;'],
                              env=dict(os.environ, PGAPPNAME='milestone-write-lock'),
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 3
        while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND application_name='milestone-write-lock' AND wait_event='PgSleep'") != '1':
            assert time.monotonic() < deadline
            time.sleep(0.01)
        yield
    finally:
        if locker.poll() is None:
            locker.terminate()
        locker.wait(timeout=5)


def wait_for_lock(server):
    deadline = time.monotonic() + 1
    while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{server.database}' AND usename='conduit' AND wait_event_type='Lock'") != '1':
        assert time.monotonic() < deadline
        time.sleep(0.01)


@contextmanager
def reference_peer(server):
    # Another unmodified implementation writes to this same disposable database.
    port = free_port()
    with (results / 'concurrent-reference.log').open('w') as log:
        environment = dict(os.environ, HOST='127.0.0.1', PORT=str(port), JWT_SECRET=secret,
                           DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:{os.environ['PGPORT']}/{server.database}")
        process = subprocess.Popen([str(reference)], env=environment, stdout=log, stderr=log)
        peer = Server(results, secret, 'unused', 'unused', reference)
        peer.port = port
        try:
            deadline = time.monotonic() + 10
            while True:
                try:
                    assert peer.request('GET', '/api/tags')[0] == 200
                    break
                except OSError:
                    assert process.poll() is None and time.monotonic() < deadline
                    time.sleep(0.02)
            yield peer
        finally:
            process.terminate()
            process.wait(timeout=5)


subprocess.run(['go', 'build', '-o', str(conformance), './cmd/conformance'], cwd=repo / 'bench', check=True)
subprocess.run(['go', 'build', '-o', str(reference), '.'], cwd=repo / 'examples/go', check=True)
with Server(results, secret, 'writes', 'zig_contract', submission / 'zig-out/bin/conduit') as zig, Server(results, secret, 'writes', 'go_contract', reference) as go:
    run, transcript, _, summary = upstream(zig, 'upstream', conformance)
    golden_run, golden, _, golden_summary = upstream(go, 'reference', conformance)
    assert run.returncode == golden_run.returncode == 0, run.stdout
    assert len(transcript) == len(golden) == 197
    assert transcript == golden
    passed('all 197 unchanged upstream steps pass')
    passed('all 197 normalized responses exactly match the unchanged Go reference')
    print('Zig: ' + summary, flush=True)
    print('Go reference: ' + golden_summary, flush=True)

with Server(results, secret, 'writes', 'focus', submission / 'zig-out/bin/conduit') as zig:
    author = zig.fixture('m5_author')
    other = zig.fixture('m5_other')
    token, other_token = mint(author, secret), mint(other, secret)
    connection_count = int(sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{zig.database}' AND usename='conduit'"))
    assert connection_count >= 1

    def create(title, tags=None):
        return zig.request('POST', '/api/articles', token, payload(title, tags))

    def idle():
        deadline = time.monotonic() + 3
        while sql(f"SELECT count(*) FROM pg_stat_activity WHERE datname='{zig.database}' AND usename='conduit' AND state='idle' AND xact_start IS NULL") != str(connection_count):
            assert time.monotonic() < deadline
            time.sleep(0.01)

    special = ['m5,a', 'm5"b', 'm5\\c', 'm5 space', 'NULL', 'é']
    status, result = create('m5 Élan -- "你好" / PING', special + special)
    assert status == 201
    article = result['article']
    slug = article['slug']
    identifier = int(slug.rsplit('-', 1)[1])
    assert slug == 'm5-lan-ping-' + str(identifier)
    assert article['tagList'] == sorted(special)
    assert article['body'] == payload('x')['article']['body']
    assert zig.sql(f'SELECT count(*) FROM article_tags WHERE article_id={identifier}') == str(len(special))
    idle()
    passed('article, distinct escaped tags and links are committed before the 201 response')

    sequence = zig.sql('SELECT last_value FROM articles_id_seq')
    for invalid in [payload('invalid', ['ok', None]), payload('invalid', ['nul\0tag']), {'article': {'title': 1}}, {'article': {'title': 'x', 'description': 'd', 'body': 'nul\0body'}}]:
        assert zig.request('POST', '/api/articles', token, invalid)[0] == 422
    assert zig.sql('SELECT last_value FROM articles_id_seq') == sequence
    assert zig.request('PUT', path(slug), other_token, {'article': {'body': 'forbidden'}})[0] == 403
    assert zig.request('DELETE', path(slug), other_token)[0] == 403
    assert zig.request('GET', path(slug))[1]['article']['body'] == article['body']
    assert zig.request('PUT', '/api/articles/missing', token, {'article': {'title': ''}})[0] == 422
    passed('invalid bodies do not consume an article ID; ownership and validation precedence prevent unauthorized changes')

    for table, tag in [('tags', 'm5_fail_tag'), ('article_tags', 'm5_fail_link')]:
        zig.sql(f"CREATE FUNCTION milestone_reject_stage() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'milestone stage failure'; RETURN NEW; END $$; CREATE TRIGGER milestone_reject_stage BEFORE INSERT ON {table} FOR EACH ROW EXECUTE FUNCTION milestone_reject_stage()")
        title = 'm5 rollback ' + table
        try:
            assert create(title, [tag])[0] == 503
            assert zig.sql('SELECT count(*) FROM articles WHERE title=' + literal(title)) == '0'
            assert zig.sql('SELECT count(*) FROM tags WHERE name=' + literal(tag)) == '0'
        finally:
            zig.sql(f'DROP TRIGGER milestone_reject_stage ON {table}; DROP FUNCTION milestone_reject_stage()')
        idle()
        assert zig.request('GET', '/api/tags')[0] == 200
    passed('tag-insert and tag-link failures roll back the article and new tags, then release an idle connection')

    zig.sql("CREATE FUNCTION milestone_reject_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'milestone deferred failure'; RETURN NEW; END $$; CREATE CONSTRAINT TRIGGER milestone_reject_commit AFTER INSERT ON articles DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION milestone_reject_commit()")
    try:
        assert create('m5 deferred failure', ['m5_deferred_tag'])[0] == 503
        assert zig.sql("SELECT count(*) FROM articles WHERE title='m5 deferred failure'") == '0'
        assert zig.sql("SELECT count(*) FROM tags WHERE name='m5_deferred_tag'") == '0'
    finally:
        zig.sql('DROP TRIGGER milestone_reject_commit ON articles; DROP FUNCTION milestone_reject_commit()')
    idle()
    assert create('m5 after deferred failure')[0] == 201
    passed('deferred COMMIT failure returns 503 and rolls back article, tags and links without replay')

    with blocked_tags(zig), concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(create, 'm5 blocked transaction', ['m5_blocked_tag'])
        wait_for_lock(zig)
        assert not future.done()
        assert zig.sql("SELECT count(*) FROM articles WHERE title='m5 blocked transaction'") == '0'
        assert future.result(timeout=5)[0] == 201
        assert zig.sql("SELECT count(*) FROM articles WHERE title='m5 blocked transaction'") == '1'
    idle()
    passed('a blocked tag stage exposes neither partial article data nor an early success response')

    with reference_peer(zig) as peer:
        barrier = threading.Barrier(8)
        def concurrent_create(i):
            barrier.wait(timeout=5)
            target = zig if i % 2 == 0 else peer
            return target.request('POST', '/api/articles', token, payload(f'm5 concurrent {i}', ['m5_shared_tag']))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            answers = list(pool.map(concurrent_create, range(8)))
        assert all(answer[0] == 201 and answer[1]['article']['tagList'] == ['m5_shared_tag'] for answer in answers)
        assert len({answer[1]['article']['slug'] for answer in answers}) == 8
    assert zig.sql("SELECT count(*) FROM tags WHERE name='m5_shared_tag'") == '1'
    assert zig.sql("SELECT count(*) FROM article_tags at JOIN tags t ON t.id=at.tag_id WHERE t.name='m5_shared_tag'") == '8'
    idle()
    passed('simultaneous Zig/Go creates on the same database link one shared new tag to all eight articles')

    for method, expected_flag, expected_count in [('POST', True, 1), ('DELETE', False, 0)]:
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            answers = list(pool.map(lambda _: zig.request(method, path(slug) + '/favorite', other_token), range(32)))
        assert all(answer[0] == 200 and answer[1]['article']['favorited'] is expected_flag and answer[1]['article']['favoritesCount'] == expected_count for answer in answers)
        assert zig.sql(f'SELECT count(*) FROM favorites WHERE article_id={identifier}') == str(expected_count)
    passed('64 concurrent repeated favourite/unfavourite writes return committed, idempotent state')

    assert zig.request('POST', '/api/profiles/m5_author/follow', token)[0] == 200
    created_comment = zig.request('POST', path(slug) + '/comments', token, {'comment': {'body': 'Self-following author still returns false on create'}})
    assert created_comment[0] == 201 and created_comment[1]['comment']['author']['following'] is False
    def comment(i):
        return zig.request('POST', path(slug) + '/comments', token if i % 2 else other_token, {'comment': {'body': f'm5 comment {i} "é"'}})
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        answers = list(pool.map(comment, range(24)))
    assert all(answer[0] == 201 for answer in answers)
    assert len({answer[1]['comment']['id'] for answer in answers}) == 24
    zig.sql(f"INSERT INTO comments(article_id,author_id,body,created_at,updated_at) SELECT {identifier},{author},'tie comment','2025-01-01 00:00:00+00','2025-01-01 00:00:00+00' FROM generate_series(1,110)")
    listed = zig.request('GET', path(slug) + '/comments', token)[1]['comments']
    expected = [int(value) for value in zig.sql(f'SELECT id FROM comments WHERE article_id={identifier} ORDER BY created_at DESC,id DESC LIMIT 100').splitlines()]
    assert [entry['id'] for entry in listed] == expected and len(listed) == 100
    assert all(entry['author']['following'] == (entry['author']['username'] == 'm5_author') for entry in listed)
    passed('concurrent comment IDs, newest-100 timestamp/ID ordering and self-following author semantics')

    cid = created_comment[1]['comment']['id']
    other_article = create('m5 different article')[1]['article']['slug']
    assert zig.request('DELETE', path(other_article) + f'/comments/{cid}', token)[0] == 404
    assert zig.request('DELETE', path(slug) + f'/comments/{cid}', other_token)[0] == 403
    for invalid in ['-1', '+1', '1.0', '9223372036854775808']:
        assert zig.request('DELETE', path(slug) + '/comments/' + quote(invalid, safe=''), token)[0] == 404
    encoded_id = ''.join('%' + format(ord(ch), '02x') for ch in str(cid))
    assert zig.request('DELETE', path(slug) + '/comments/' + encoded_id, token) == (204, None)
    assert zig.sql(f'SELECT count(*) FROM comments WHERE id={cid}') == '0'
    passed('comment deletion checks the article and actual comment owner, with strict decoded integer IDs')

    # Permission failure affects only the post-commit article read; never replay the write.
    zig.sql('REVOKE SELECT ON favorites FROM conduit')
    try:
        assert create('m5 committed but response unavailable', ['m5_postcommit_tag'])[0] == 503
        assert zig.sql("SELECT count(*) FROM articles WHERE title='m5 committed but response unavailable'") == '1'
    finally:
        zig.sql('GRANT SELECT ON favorites TO conduit')
    idle()
    committed_slug = zig.sql("SELECT slug FROM articles WHERE title='m5 committed but response unavailable'")
    assert zig.request('GET', path(committed_slug))[0] == 200
    passed('a failed post-commit read returns 503 while preserving exactly one committed article')

    with blocked_tags(zig):
        raw_body = json.dumps(payload('m5 disconnected write', ['m5_disconnected_tag'])).encode()
        client = socket.create_connection(('127.0.0.1', zig.port), timeout=5)
        try:
            client.sendall((f'POST /api/articles HTTP/1.1\r\nHost: x\r\nAuthorization: Token {token}\r\nContent-Length: {len(raw_body)}\r\n\r\n').encode() + raw_body)
            wait_for_lock(zig)
            client.close()
            assert zig.request('GET', '/api/tags')[0] == 200
            deadline = time.monotonic() + 3
            while zig.sql("SELECT count(*) FROM articles WHERE title='m5 disconnected write'") != '1':
                assert time.monotonic() < deadline
                time.sleep(0.01)
        finally:
            client.close()
    idle()
    passed('disconnect during article creation retains transaction ownership through commit and later requests')

    cascade = create('m5 cascade delete', ['m5_persistent_tag'])[1]['article']
    cascade_id = int(cascade['slug'].rsplit('-', 1)[1])
    assert zig.request('POST', path(cascade['slug']) + '/favorite', other_token)[0] == 200
    assert zig.request('POST', path(cascade['slug']) + '/comments', other_token, {'comment': {'body': 'cascade me'}})[0] == 201
    wire = (f'DELETE {path(cascade["slug"])} HTTP/1.1\r\nHost: x\r\nAuthorization: Token {token}\r\n\r\nGET /api/tags HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n').encode()
    with socket.create_connection(('127.0.0.1', zig.port), timeout=5) as client:
        client.sendall(wire)
        with client.makefile('rb') as reader:
            assert raw_response(reader) == (204, None)
            assert raw_response(reader)[0] == 200
            assert reader.read(1) == b''
    for table in ['articles', 'article_tags', 'favorites', 'comments']:
        column = 'id' if table == 'articles' else 'article_id'
        assert zig.sql(f'SELECT count(*) FROM {table} WHERE {column}={cascade_id}') == '0'
    assert zig.sql("SELECT count(*) FROM tags WHERE name='m5_persistent_tag'") == '1'
    passed('bodyless 204 pipelining and article cascade deletion preserve the shared tags')

    with blocked_tags(zig), concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(create, 'm5 lost transaction', ['m5_lost_tag'])
        wait_for_lock(zig)
        zig.sql(f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='{zig.database}' AND usename='conduit'")
        assert future.result(timeout=5)[0] == 503
    assert zig.sql("SELECT count(*) FROM articles WHERE title='m5 lost transaction'") == '0'
    assert zig.sql("SELECT count(*) FROM tags WHERE name='m5_lost_tag'") == '0'
    deadline = time.monotonic() + 10
    while True:
        status = zig.request('GET', '/api/tags')[0]
        if status == 200:
            break
        assert status == 503 and time.monotonic() < deadline
        time.sleep(0.03)
    assert create('m5 request after recovery')[0] == 201
    assert zig.sql("SELECT count(*) FROM articles WHERE title='m5 lost transaction'") == '0'
    passed('backend loss rolls back the open transaction, returns 503 and never automatically replays a write')

    assert zig.process.poll() is None
    evidence = {'milestone': 5, 'checks': checks, 'upstream_steps_passed': len(transcript),
                'normalized_responses_equal_to_reference': len(transcript), 'upstream_summary': summary,
                'upstream_exit_status': run.returncode, 'reference_summary': golden_summary,
                'reference_exit_status': golden_run.returncode,
                'scope': 'native Mac development seed; no full-seed, linked Linux or capacity claim'}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: {len(checks)} write scenarios and all 197 unchanged upstream steps', flush=True)
