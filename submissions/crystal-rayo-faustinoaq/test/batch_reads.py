"""Compare mixed batched reads with isolated reads, including distinct viewers."""
import concurrent.futures
import json
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

base = sys.argv[1]
prefix = 'rayo_batch_' + str(time.time_ns())


def request(path, token=None, method='GET', body=None):
    headers = {'Content-Type': 'application/json', 'Accept-Encoding': 'identity'}
    if token:
        headers['Authorization'] = 'Token ' + token
    req = urllib.request.Request(base + path, json.dumps(body).encode() if body else None,
                                 headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.loads(response.read())


tokens = []
for suffix in ('owner', 'reader'):
    name = prefix + suffix
    status, result = request('/api/users', method='POST', body={'user': {
        'username': name, 'email': name + '@example.com', 'password': 'batch password'}})
    assert status == 201
    tokens.append(result['user']['token'])
status, result = request('/api/articles', tokens[0], 'POST', {'article': {
    'title': prefix, 'description': 'batch test', 'body': 'body', 'tagList': [prefix, 'escaped"tag']}})
assert status == 201
slug = result['article']['slug']
request('/api/articles/' + slug + '/favorite', tokens[1], 'POST')
request('/api/profiles/' + prefix + 'owner/follow', tokens[1], 'POST')
request('/api/articles/' + slug + '/comments', tokens[0], 'POST', {'comment': {'body': 'test'}})

cases = []
for token in (None, *tokens):
    for path in ('/api/articles/' + slug, '/api/articles/' + slug + '/comments',
                 '/api/articles?author=' + prefix + 'owner', '/api/articles?tag=' + prefix,
                 '/api/articles?favorited=' + prefix + 'reader', '/api/articles?tag=missing-' + prefix,
                 '/api/articles/missing-' + prefix, '/api/articles/missing-' + prefix + '/comments'):
        cases.append((path, token))
cases.extend([('/api/articles/feed', token) for token in tokens])
cases.append(('/api/tags', None))
expected = [request(*case) for case in cases]
assert expected[0][1]['article']['favorited'] is False
assert expected[16][1]['article']['favorited'] is True
assert expected[17][1]['comments'][0]['author']['following'] is True

# Disconnected queued readers must not receive or corrupt a later slot's response.
url = urllib.parse.urlsplit(base)
for _ in range(40):
    with socket.create_connection((url.hostname, url.port), timeout=30) as sock:
        sock.sendall(b'GET /api/articles?limit=20 HTTP/1.1\r\nHost: test\r\n\r\n')


def check(i):
    index = i % len(cases)
    assert request(*cases[index]) == expected[index], cases[index]


with concurrent.futures.ThreadPoolExecutor(max_workers=40) as pool:
    list(pool.map(check, range(len(cases) * 20)))
print('PASS: 540 mixed reads match isolated reads; viewer flags, empty pages, missing articles, disconnects')
