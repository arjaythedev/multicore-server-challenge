#!/usr/bin/env python3
"""Independent gzip/negotiation/keep-alive checks (run against GZIP=1 or GZIP=2).
Usage: python3 tests/perf_features.py PORT
Fixtures are created via the API; use a disposable database.
"""
import argparse
import gzip
import http.client
import json
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('port', type=int)

    args = parser.parse_args()
    client = http.client.HTTPConnection('127.0.0.1', args.port, timeout=15)

    def request(method, path, body=None, token=None, encoding=None):
        headers = {}
        if body is not None:
            headers['Content-Type'] = 'application/json'
            body = json.dumps(body, ensure_ascii=False).encode()
        if token:
            headers['Authorization'] = 'Token ' + token
        if encoding is not None:
            headers['Accept-Encoding'] = encoding
        client.request(method, path, body=body, headers=headers)
        response = client.getresponse()
        raw = response.read()
        headers = dict((k.lower(), v) for k, v in response.getheaders())
        assert headers.get('vary') == 'Accept-Encoding', headers
        if response.status != 204:
            assert int(headers['content-length']) == len(raw)
        return response.status, headers, raw

    try:
        name = 'perf_' + uuid.uuid4().hex
        status, _, body = request('POST', '/api/users', {'user': {'username': name, 'email': name+'@example.com', 'password': 'independent-password'}})
        assert status == 201, (status, body)
        token = json.loads(body)['user']['token']
        text = ('Unicode ✓ and escapes " \\ \n\t ' * 6000)
        status, _, body = request('POST', '/api/articles', {'article': {'title': name, 'description': 'gzip fixture', 'body': text, 'tagList': [name]}}, token)
        assert status == 201, (status, body)
        slug = json.loads(body)['article']['slug']
        path = '/api/articles/' + slug
        status, headers, identity = request('GET', path, token=token, encoding='identity')
        assert status == 200 and 'content-encoding' not in headers
        socket = client.sock
        compressed = 0
        for encoding, allowed in [
            ('gzip', True),
            ('GZip;q=0.001', True),
            ('*', True),
            ('gzip;q=0, *;q=1', False),
            ('*;q=1, gzip;q=0', False),
            ('gzip;q=0.000', False),
            ('gzip;q=1.001', False),
            ('br', False),
            ('identity', False),
            ('gzip;q=1.000', True),
            ('gzip, identity;q=0', True),
            ('*;q=0, gzip', True),
            ('*;q=0, identity', False),
            ('identity;q=0.001, *;q=0', False),
        ]:
            status, headers, raw = request('GET', path, token=token, encoding=encoding)
            assert status == 200 and client.sock is socket, (status, encoding)
            if allowed:
                assert headers.get('content-encoding') == 'gzip', (encoding, headers)
                assert gzip.decompress(raw) == identity, encoding
                assert len(raw) < len(identity)
                compressed += 1
            else:
                assert 'content-encoding' not in headers, (encoding, headers)
                assert raw == identity, encoding
        small_path = '/api/articles?tag=' + name + '_empty'
        status, headers, small_identity = request('GET', small_path, token=token, encoding='identity')
        assert status == 200 and client.sock is socket and 'content-encoding' not in headers
        assert json.loads(small_identity) == {'articles': [], 'articlesCount': 0}
        assert len(small_identity) < 1024
        # Identity exclusion forces gzip even below the threshold and when it grows the response.
        for encoding in ('gzip, identity;q=0', '*;q=0, gzip', 'gzip;q=0.001, *;q=0'):
            status, headers, raw = request('GET', small_path, token=token, encoding=encoding)
            assert status == 200 and client.sock is socket, (status, encoding)
            assert headers.get('content-encoding') == 'gzip', (encoding, headers)
            assert gzip.decompress(raw) == small_identity, encoding
            assert len(raw) > len(small_identity), (encoding, len(raw), len(small_identity))
            compressed += 1
        for encoding in ('gzip;q=0, identity;q=0', '*;q=0', 'br, identity;q=0', 'gzip;q=1, gzip;q=0, identity;q=0'):
            status, headers, raw = request('GET', small_path, token=token, encoding=encoding)
            assert status == 406 and client.sock is socket, (status, encoding)
            assert headers.get('content-length') == '0' and raw == b'', (encoding, headers, raw)
            assert 'content-encoding' not in headers, (encoding, headers)
        status, headers, raw = request('GET', small_path, token=token, encoding='*;q=0, identity')
        assert status == 200 and client.sock is socket and 'content-encoding' not in headers
        assert raw == small_identity
        # A response body larger than a coordinator's chunk traverses reassembly,
        # and independent gzip decoding also verifies CRC32 and uncompressed size.
        status, _, body = request('POST', path+'/comments', {'comment': {'body': text}}, token)
        assert status == 201, (status, body)
        status, _, comments = request('GET', path+'/comments', token=token, encoding='identity')
        assert status == 200
        status, headers, raw = request('GET', path+'/comments', token=token, encoding='gzip')
        assert status == 200 and headers.get('content-encoding') == 'gzip'
        assert gzip.decompress(raw) == comments
        comment = json.loads(comments)['comments'][0]
        status, headers, body = request('DELETE', path+'/comments/'+str(comment['id']), token=token, encoding='gzip;q=0, identity;q=0')
        assert status == 204 and not body and 'content-encoding' not in headers
        status, headers, body = request('DELETE', path, token=token, encoding='gzip')
        assert status == 204 and not body and 'content-encoding' not in headers
        print('PASS gzip: independent decode, UTF-8/escapes, q-values, explicit/wildcard overrides, forced small gzip, empty 406, same-socket negotiation, large article/comment and bodyless 204; compressed variants:', compressed + 1)
    finally:
        client.close()


if __name__ == '__main__':
    main()
