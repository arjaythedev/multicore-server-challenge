#!/usr/bin/env python3
"""Independent 0/999/1000/1001 feed fixtures, including a 1000-row sparse-author
fallback and empty pages. Uses read_regression's libpq and JWT helpers.
"""
import concurrent.futures
import http.client
import json
import os
import sys
import threading
import uuid
from read_regression import literal, psql, token


def main():
    port = int(sys.argv[1])
    prefix = 'feedcap_' + uuid.uuid4().hex
    names = [prefix + '_a' + str(i) for i in range(5)] + [prefix + '_v' + str(i) for i in range(5)]
    quoted = ','.join(literal(n) for n in names)
    try:
        psql('INSERT INTO users(username,email,password_hash) VALUES ' + ','.join('('+literal(n)+','+literal(n+'@test.invalid')+",'not-used')" for n in names))
        mapping = json.loads(psql('SELECT json_object_agg(username,id) FROM users WHERE username IN ('+quoted+')'))
        authors = [mapping[n] for n in names[:5]]
        viewers = [mapping[n] for n in names[5:]]
        counts = [999, 1000, 1001, 1, 999]
        for i, count in enumerate(counts):
            psql("INSERT INTO articles(slug,author_id,title,description,body,created_at,updated_at) SELECT "+literal(prefix+'_a'+str(i)+'-')+"||n,"+str(authors[i])+",'cap title','cap description','cap body','2025-01-01T00:00:00Z','2025-01-01T00:00:00Z' FROM generate_series(1,"+str(count)+") n")
        follows = [[], [authors[0]], [authors[1]], [authors[2]], [authors[3], authors[4]]]
        pairs = [(v, a) for v, aa in zip(viewers, follows) for a in aa]
        psql('INSERT INTO follows(follower_id,followee_id) VALUES '+','.join('(%d,%d)' % p for p in pairs))
        rows = json.loads(psql('SELECT json_agg(x) FROM (SELECT slug,author_id FROM articles WHERE author_id IN ('+','.join(map(str,authors))+') ORDER BY id DESC) x'))
        cases = [(i, limit, offset) for i in range(5) for limit in (1, 3) for offset in (0, 998, 999, 1000, 1001)]
        cases = (cases + cases)[:64]
        barrier = threading.Barrier(64)

        def check(case):
            i, limit, offset = case
            client = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
            try:
                client.request('GET','/api/tags')
                warm = client.getresponse(); warm.read()
                assert warm.status == 200
                barrier.wait(timeout=15)
                client.request('GET','/api/articles/feed?limit=%d&offset=%d' % (limit,offset), headers={'Authorization':'Token '+token(viewers[i], os.environ.get('JWT_SECRET','multicore-server-challenge'))})
                response = client.getresponse()
                body = json.loads(response.read())
                assert response.status == 200, (case,response.status,body)
                expected = [row['slug'] for row in rows if row['author_id'] in follows[i]]
                assert body['articlesCount'] == min(1000,len(expected)), (case,body['articlesCount'],len(expected))
                assert [a['slug'] for a in body['articles']] == expected[offset:offset+limit], case
                for article in body['articles']:
                    assert article['author']['following'] is True
                    assert article['favorited'] is False and article['favoritesCount'] == 0
                    assert article['tagList'] == []
            finally:
                client.close()
        with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
            list(pool.map(check,cases))
        print('PASS 64 synchronized feed cap/page/flag checks: empty, 999, 1000, 1001 and combined sparse-author fallback')
    finally:
        psql('DELETE FROM users WHERE username IN ('+quoted+')')


if __name__ == '__main__':
    main()
