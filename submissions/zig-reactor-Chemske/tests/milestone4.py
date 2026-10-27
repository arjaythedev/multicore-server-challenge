#!/usr/bin/env python3
"""Check article/feed reads against the unchanged reference and fault-injected clones."""
import concurrent.futures
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import time
from urllib.parse import quote, urlencode

from support import Server as DisposableServer, literal, mint as issue_token, raw_response, upstream

submission = Path(__file__).resolve().parents[1]
repo = submission.parents[1]
work = Path(os.environ['CHALLENGE_WORK'])
results = work / 'results/milestone4'
results.mkdir(parents=True, exist_ok=True)
secret = 'milestone-article-reads-only'
checks = []


def server(label, executable):
    return DisposableServer(results, secret, 'reads', label, executable)


def mint(identifier, expiry=None):
    return issue_token(identifier, secret, expiry)


def passed(name):
    checks.append(name)


def article_path(slug):
    return '/api/articles/' + quote(slug, safe='')


def page(response, count=None, size=None):
    status, body = response
    assert status == 200 and set(body) == {'articles', 'articlesCount'}, response
    assert type(body['articlesCount']) is int
    if count is not None:
        assert body['articlesCount'] == count, body['articlesCount']
    if size is not None:
        assert len(body['articles']) == size, len(body['articles'])
    for row in body['articles']:
        assert set(row) == {'slug', 'title', 'description', 'createdAt', 'updatedAt', 'tagList', 'favoritesCount', 'favorited', 'author'}
        assert set(row['author']) == {'username', 'bio', 'image', 'following'}
        assert type(row['favoritesCount']) is int and type(row['favorited']) is bool
        assert type(row['author']['following']) is bool and isinstance(row['tagList'], list)
    return body['articles']


def slugs(response, count=None, size=None):
    return [row['slug'] for row in page(response, count, size)]


conformance = work / 'tools/conformance'
reference = work / 'tools/reference-go'
subprocess.run(['go', 'build', '-o', str(conformance), './cmd/conformance'], cwd=repo / 'bench', check=True)
subprocess.run(['go', 'build', '-o', str(reference), '.'], cwd=repo / 'examples/go', check=True)
with server('zig_contract', submission / 'zig-out/bin/conduit') as zig, server('go_contract', reference) as go:
    run, transcript, _, summary = upstream(zig, 'upstream', conformance)
    golden_run, golden, _, golden_summary = upstream(go, 'reference', conformance)
    assert golden_run.returncode == 0
    prefix = []
    for step in transcript:
        if step['step'].startswith('favorite.'):
            break
        prefix.append(step)
    read_steps = [step for step in prefix if step['step'].startswith(('articles.list.', 'feed.', 'article.get.'))]
    assert len(prefix) == 119 and len(read_steps) == 51
    failures = set(re.findall(r'^FAIL (\S+)', run.stdout, re.MULTILINE))
    assert not any(step['step'] in failures for step in prefix), failures
    expected = {step['step']: step for step in golden}
    assert all(step == expected[step['step']] for step in prefix)
    passed('119 upstream steps before favourite writes pass, including all 51 article/feed read steps')
    passed('all 119 normalized responses match the unchanged Go reference, including all 51 reads')
    print('Zig full upstream run: ' + summary, flush=True)
    print('Unchanged Go reference: ' + golden_summary, flush=True)

# Fresh clones prevent later reference writes from contaminating the differential read fixtures.
with server('zig', submission / 'zig-out/bin/conduit') as zig, server('go', reference) as go:
    names = ['m4_author é+', 'm4_author_b', 'm4_viewer_a', 'm4_viewer_b']
    ids = {s: {name: s.fixture(name) for name in names} for s in (zig, go)}
    first, second, third = 'm4_first/é+?%2F', 'm4_second', 'm4_third'
    tag_names = ['m4,a', 'm4"b', 'm4\\c', 'NULL', 'm4{brace}', 'm4 space', 'é']
    title, description, body = 'Title "quoted" \\ and é', 'line one\nline two ☕', 'Article body\nwith Unicode é and a backslash \\'
    for s in (zig, go):
        a, b, viewer = ids[s][names[0]], ids[s][names[1]], ids[s][names[2]]
        for identifier, slug, author in [(20001, first, a), (20002, second, a), (20003, third, b)]:
            s.sql(f"INSERT INTO articles(id,slug,author_id,title,description,body,created_at,updated_at) VALUES ({identifier},{literal(slug)},{author},{literal(title)},{literal(description)},{literal(body)},'2025-04-01 12:00:00.123999+02','1969-12-31 23:59:59.987654+00')")
        for tag in tag_names:
            s.sql(f"INSERT INTO tags(name) VALUES ({literal(tag)}) ON CONFLICT DO NOTHING; INSERT INTO article_tags SELECT 20001,id FROM tags WHERE name={literal(tag)}")
        s.sql(f"INSERT INTO article_tags SELECT 20003,id FROM tags WHERE name={literal(tag_names[0])}; INSERT INTO favorites(user_id,article_id) VALUES ({viewer},20001); INSERT INTO follows(follower_id,followee_id) VALUES ({viewer},{a})")
    alice, bob = mint(ids[zig][names[2]]), mint(ids[zig][names[3]])
    by_author = '/api/articles?' + urlencode({'author': names[0]})
    by_tag = '/api/articles?' + urlencode({'tag': tag_names[0]})
    by_favorite = '/api/articles?' + urlencode({'favorited': names[2]})

    def compare(path, viewer=None):
        responses = [s.request('GET', path, mint(ids[s][viewer]) if viewer else None) for s in (zig, go)]
        assert responses[0][0] == responses[1][0], (path, responses)
        if responses[0][0] < 400:
            assert responses[0] == responses[1], (path, responses)
        return responses[0]

    result = compare(article_path(first), names[2])
    article = result[1]['article']
    assert result[0] == 200 and article['body'] == body
    assert article['title'] == title and article['description'] == description
    assert article['tagList'] == sorted(tag_names)
    assert article['createdAt'] == '2025-04-01T10:00:00.123Z'
    assert article['updatedAt'] == '1969-12-31T23:59:59.987Z'
    assert article['favorited'] is True and article['author']['following'] is True
    assert article['author']['bio'] is None and article['author']['image'] is None
    passed('single-article escaping, quoted PostgreSQL arrays, null fields and UTC millisecond truncation match Go')

    assert slugs(compare('/api/articles?limit=3')) == [third, second, first]
    assert slugs(compare(by_author), 2) == [second, first]
    assert slugs(compare(by_tag), 2) == [third, first]
    assert slugs(compare(by_favorite), 1) == [first]
    empty_tags = zig.request('GET', article_path(second))[1]['article']['tagList']
    assert empty_tags == []
    passed('ID ordering, compact list objects, empty tag arrays and all three filters match Go')

    for query in [
        {'tag': tag_names[0], 'author': names[1], 'favorited': names[3]},
        {'tag': '', 'author': names[0], 'favorited': names[3]},
        {'author': names[0], 'favorited': names[3]},
        {'tag': "'; SELECT pg_sleep(30); --"},
        {'author': 'missing'}, {'favorited': 'missing'},
    ]:
        compare('/api/articles?' + urlencode(query))
    assert slugs(compare(by_author + '&offset=2'), 2, 0) == []
    assert slugs(compare('/api/articles?tag=missing'), 0, 0) == []
    passed('filter precedence, empty filters, parameterized injection text and empty-page counts')

    for query in [
        'limit=1&limit=0', 'limit=0&limit=1', 'offset=1&offset=0', '%6cimit=1',
        'limit=%GG', 'limit=1;ignored', 'limit=01&offset=0002',
        'tag=&tag=ignored&author=' + quote(names[0], safe=''),
        'tag=%GG&tag=' + quote(tag_names[0], safe=''),
    ]:
        compare('/api/articles?' + query)
    assert zig.request('GET', '/api/articles?limit=0&limit=1')[0] == 422
    for path in ['/api/articles?tag=%00', '/api/articles?author=%FF', '/api/articles?offset=9223372036854775808']:
        assert zig.request('GET', path)[0] == 422
    passed('duplicate/encoded query keys, first-value semantics and strict numeric/text bounds')

    assert slugs(compare('/api/articles/feed', names[2]), 2) == [second, first]
    assert slugs(compare('/api/articles/feed', names[3]), 0, 0) == []
    assert slugs(compare('/api/articles/feed?offset=1&limit=1&tag=ignored', names[2]), 2, 1) == [first]
    assert zig.request('GET', '/api/articles/feed?tag=%00', alice)[0] == 200
    anon = compare(article_path(first))[1]['article']
    other = compare(article_path(first), names[3])[1]['article']
    assert not anon['favorited'] and not anon['author']['following']
    assert not other['favorited'] and not other['author']['following']
    assert anon['favoritesCount'] == article['favoritesCount'] == 1
    passed('feed selection and per-viewer favourite/following flags without shared identity state')

    for path in ['/api/articles', '/api/articles/feed', article_path(first)]:
        for header in ['', 'Bearer ' + alice, 'Token invalid', 'Token ' + mint(ids[zig][names[2]], int(time.time()) - 1)]:
            assert zig.request('GET', path, headers={'Authorization': header})[0] == 401
    assert zig.request('GET', '/api/articles/feed')[0] == 401
    assert zig.request('GET', '/api/articles?limit=0', headers={'Authorization': 'invalid'})[0] == 401
    assert zig.request('GET', article_path(first) + '?limit=0')[0] == 200
    passed('optional/required auth precedes pagination, while single reads ignore list query fields')

    # Mutate outside the application, then require the next request to see it.
    viewer, author = ids[zig][names[2]], ids[zig][names[0]]
    zig.sql(f'DELETE FROM favorites WHERE user_id={viewer} AND article_id=20001; DELETE FROM follows WHERE follower_id={viewer} AND followee_id={author}')
    changed = zig.request('GET', article_path(first), alice)[1]['article']
    assert not changed['favorited'] and not changed['author']['following'] and changed['favoritesCount'] == 0
    assert slugs(zig.request('GET', '/api/articles/feed', alice), 0, 0) == []
    zig.sql(f'INSERT INTO favorites VALUES ({viewer},20001,now()); INSERT INTO follows VALUES ({viewer},{author},now())')
    assert slugs(zig.request('GET', '/api/articles/feed', alice), 2) == [second, first]
    passed('fresh article and feed reads after external favourite/follow mutations')

    wire = (f'GET {article_path(first)} HTTP/1.1\r\nHost: x\r\nAuthorization: Token {alice}\r\n\r\n'
            f'GET /api/articles/feed?limit=1 HTTP/1.1\r\nHost: x\r\nAuthorization: Token {bob}\r\n\r\n'
            f'GET {article_path(first)} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n').encode()
    with socket.create_connection(('127.0.0.1', zig.port), timeout=10) as client:
        client.sendall(wire[:23])
        time.sleep(0.02)
        client.sendall(wire[23:])
        with client.makefile('rb') as reader:
            assert raw_response(reader)[1]['article']['favorited'] is True
            assert raw_response(reader) == (200, {'articles': [], 'articlesCount': 0})
            assert raw_response(reader)[1]['article']['favorited'] is False
            assert reader.read(1) == b''
    passed('fragmented/pipelined article and two-stage feed requests preserve order and viewer isolation')

    def concurrent_read(i):
        if i % 3 == 0:
            return slugs(zig.request('GET', '/api/articles/feed', alice), 2) == [second, first]
        if i % 3 == 1:
            return slugs(zig.request('GET', by_author + '&offset=20', bob), 2, 0) == []
        return zig.request('GET', article_path(first))[1]['article']['favorited'] is False
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        assert all(pool.map(concurrent_read, range(96)))
    passed('96 concurrent single/list/feed reads keep page, count and viewer results together')

    for s in (zig, go):
        a, viewer = ids[s][names[0]], ids[s][names[2]]
        s.sql(f"INSERT INTO articles(id,slug,author_id,title,description,body,created_at,updated_at) SELECT n,'m4_bulk_'||n,{a},'bulk','bulk','bulk','2025-01-01 00:00:00+00','2025-01-01 00:00:00+00' FROM generate_series(21000,22004) n; INSERT INTO tags(name) VALUES ('m4_cap'); INSERT INTO article_tags SELECT a.id,t.id FROM articles a CROSS JOIN tags t WHERE a.id BETWEEN 21000 AND 22004 AND t.name='m4_cap'; INSERT INTO favorites SELECT {viewer},id,'2025-01-01 00:00:00+00' FROM articles WHERE id BETWEEN 21000 AND 22004")
    cap_paths = ['/api/articles', '/api/articles?tag=m4_cap', by_author, by_favorite, '/api/articles/feed']
    for path in cap_paths:
        separator = '&' if '?' in path else '?'
        assert len(page(compare(path + separator + 'limit=2&offset=1002', names[2]), 1000, 2)) == 2
        for offset in [2147483647, 9223372036854775807]:
            assert slugs(zig.request('GET', path + separator + f'limit=100&offset={offset}', alice), 1000, 0) == []
    # SPEC permits this offset; the reference's explicit int32 casts overflow here.
    assert go.request('GET', '/api/articles/feed?limit=100&offset=2147483647', mint(ids[go][names[2]]))[0] == 500
    passed('all five count families cap at 1000 without truncating pages; valid int64 offsets stay overflow-safe')

    # Fail only the second query, after its page has succeeded, in this private clone.
    zig.sql("""CREATE FUNCTION milestone_count_allowed() RETURNS boolean LANGUAGE plpgsql AS $$
               BEGIN IF current_query() LIKE 'SELECT count(*)%' THEN RAISE EXCEPTION 'milestone count failure'; END IF; RETURN true; END $$;
               ALTER TABLE articles ENABLE ROW LEVEL SECURITY;
               CREATE POLICY milestone_count_failure ON articles FOR SELECT TO conduit USING (milestone_count_allowed());""")
    try:
        for path in ['/api/articles?limit=1', '/api/articles?offset=100000000']:
            answer = zig.request('GET', path)
            assert answer[0] == 503 and set(answer[1]) == {'errors'}
    finally:
        zig.sql('DROP POLICY milestone_count_failure ON articles; ALTER TABLE articles DISABLE ROW LEVEL SECURITY; DROP FUNCTION milestone_count_allowed()')
    assert slugs(zig.request('GET', '/api/articles?offset=100000000'), 1000, 0) == []
    passed('count-stage errors discard both populated and empty pages, then allow connection reuse')

    zig.sql('ALTER TABLE favorites RENAME TO favorites_unavailable')
    try:
        for path in [article_path(first), by_author, '/api/articles/feed']:
            assert zig.request('GET', path, alice)[0] == 503
    finally:
        zig.sql('ALTER TABLE favorites_unavailable RENAME TO favorites')
    assert zig.request('GET', article_path(first), alice)[0] == 200
    passed('page-stage database errors return 503 and recover after the table is restored')

    zig.sql("UPDATE articles SET body=repeat('a',3*1024*1024) WHERE id=20001")
    client = socket.socket()
    client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
    client.settimeout(10)
    client.connect(('127.0.0.1', zig.port))
    try:
        client.sendall(f'GET {article_path(first)} HTTP/1.1\r\nHost: x\r\n\r\n'.encode())
        assert client.recv(128).startswith(b'HTTP/1.1 200')
        assert zig.request('GET', '/api/tags')[0] == 200
    finally:
        client.close()
    zig.sql('UPDATE articles SET body=repeat(chr(1),1024*1024) WHERE id=20001')
    assert zig.request('GET', article_path(first))[0] == 503
    zig.sql(f'UPDATE articles SET body={literal(body)} WHERE id=20001')
    assert zig.request('GET', article_path(first))[0] == 200
    passed('slow/disconnected readers do not block tags; oversized serialized responses fail within the configured bound')

    assert zig.process.poll() is None
    evidence = {'milestone': 4, 'checks': checks, 'upstream_supported_prefix_steps': len(prefix),
                'upstream_article_feed_steps': len(read_steps), 'normalized_prefix_responses_equal_to_reference': len(prefix),
                'upstream_full_summary': summary, 'upstream_exit_status': run.returncode,
                'reference_summary': golden_summary, 'reference_exit_status': golden_run.returncode,
                'scope': 'native Mac correctness; no linked Linux runtime or capacity claim'}
    (results / 'results.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(f'PASS: {len(checks)} article/feed scenarios; 119 upstream prefix steps, including 51 reads, passed', flush=True)
