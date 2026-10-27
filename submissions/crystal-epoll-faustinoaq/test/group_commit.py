"""Run against an isolated test server: concurrent SQL failures must not lose good writes."""
import concurrent.futures
import json
import time
import urllib.error
import urllib.request
import sys

base = sys.argv[1]
prefix = 'tx_' + str(time.time_ns())

def register(i, duplicate=False):
    body = json.dumps({'user': {'username': prefix if duplicate else prefix + str(i),
                               'email': prefix + str(i) + '@example.com',
                               'password': 'password123'}}).encode()
    req = urllib.request.Request(base + '/api/users', body, {'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

assert register(-1, True)[0] == 201
with concurrent.futures.ThreadPoolExecutor(max_workers=24) as pool:
    results = list(pool.map(lambda i: register(i, i % 2 == 0), range(24)))
for i, (status, data) in enumerate(results):
    assert status == (422 if i % 2 == 0 else 201), (i, status, data)
    if status == 201:
        token = data['user']['token']
        req = urllib.request.Request(base + '/api/user', headers={'Authorization': 'Token ' + token})
        with urllib.request.urlopen(req) as response:
            assert json.load(response)['user']['username'] == prefix + str(i)
print('24 concurrent registrations: expected conflicts; every successful write visible after response')

status, owner = register(1000)
assert status == 201
headers = {'Content-Type': 'application/json', 'Authorization': 'Token ' + owner['user']['token']}

def create_article(i):
    title = prefix + '_article_' + str(i)
    body = json.dumps({'article': {'title': title, 'description': 'transaction test',
                                   'body': 'body ' + str(i), 'tagList': [prefix, prefix + '_shared']}}).encode()
    req = urllib.request.Request(base + '/api/articles', body, headers)
    with urllib.request.urlopen(req, timeout=20) as response:
        assert response.status == 201
        article = json.load(response)['article']
    assert article['title'] == title and article['body'] == 'body ' + str(i)
    with urllib.request.urlopen(base + '/api/articles/' + article['slug']) as response:
        stored = json.load(response)['article']
    assert stored['title'] == title and stored['body'] == 'body ' + str(i)
    assert stored['tagList'] == sorted([prefix, prefix + '_shared'])
    return article['slug']

with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
    slugs = list(pool.map(create_article, range(12)))
assert len(set(slugs)) == 12
print('12 concurrent article transactions: distinct IDs, correct bodies and shared tags, visible after response')
