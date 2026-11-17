#!/usr/bin/env python3
"""Check real batch dispatch against individual handlers on a disposable nc_batch_* DB.

Uses the independent SQL fixture/oracles in batch_sql.py. Run batch_sql.py first.
Every token is independently signed here; wrapped native entrypoints measure actual
query parameter bytes and verify per-request authentication in both pipeline modes.
"""
import argparse
import base64
import ctypes as C
import hmac
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
from batch_sql import Database

ROOT = Path(__file__).resolve().parents[1]
SECRET = 'coalesce-independent-test-secret'


def token(viewer, *, expired=False):
    def enc(v):
        return base64.urlsafe_b64encode(json.dumps(v).encode()).rstrip(b'=')
    head = enc({'alg': 'HS256', 'typ': 'JWT'})
    body = enc({'sub': str(viewer), 'exp': int(time.time()) + (-60 if expired else 3600)})
    data = head + b'.' + body
    return data + b'.' + base64.urlsafe_b64encode(hmac.digest(SECRET.encode(), data, 'sha256')).rstrip(b'=')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true', help='preload the compiler ASan runtime into Python')
    parser.add_argument('--implementation', choices=['c', 'nelua'], default='nelua')
    args = parser.parse_args()
    url = os.environ['DATABASE_URL']
    db = Database('psql', url)
    name = db.execute('SELECT current_database()')
    if not name.startswith('nc_batch_'):
        raise RuntimeError('Requires disposable nc_batch_* database; run batch_sql.py first')
    os.environ['JWT_SECRET'] = SECRET
    config = shlex.split(os.environ.get('PG_CONFIG', 'pg_config'))
    include = subprocess.check_output(config + ['--includedir'], text=True).strip()
    flags = ['-std=gnu11', '-O1' if args.sanitize else '-O3', '-g', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
             '-I' + str(ROOT / 'src'), '-I' + include,
             '-Wl,--wrap=nc_db_query', '-Wl,--wrap=nc_auth', '-Wl,--wrap=nc_value']
    if args.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    application = ['build/app.c']
    if args.implementation == 'c':
        flags += ['-DNC_APP_C']
        application = ['src/app_c.c', 'src/batch_c.c', 'src/serialize_c.c']
    with tempfile.TemporaryDirectory(prefix='nc-coalesce-') as directory:
        tmp = Path(directory)
        wrapper = tmp / 'measure.c'
        wrapper.write_text('''#include "native.h"
#include <string.h>
static size_t bytes, authentications, fields;
nc_result *__real_nc_db_query(nc_db *,int,const char *,int,const char *const *);
nc_result *__wrap_nc_db_query(nc_db *d,int id,const char *s,int n,const char *const *p) {
  /* Count parameters where they are constructed: submission has values;
   * pipeline result collection deliberately supplies only null pointers. */
  for (int i=0;i<n;++i) if (p[i]) bytes+=strlen(p[i]);
  return __real_nc_db_query(d,id,s,n,p);
}
int64_t __real_nc_auth(nc_request *);
int64_t __wrap_nc_auth(nc_request *r) { ++authentications; return __real_nc_auth(r); }
const char *__real_nc_value(nc_result *,int,int);
const char *__wrap_nc_value(nc_result *r,int row,int col) { ++fields; return __real_nc_value(r,row,col); }
void reset_measurement(void) { bytes=authentications=fields=0; }
size_t measured_bytes(void) { return bytes; }
size_t measured_fields(void) { return fields; }
size_t measured_authentications(void) { return authentications; }
''')
        library = tmp / 'batch.so'
        subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + flags +
                       [str(ROOT / p) for p in application + ['src/request.c', 'src/bcrypt.c', 'src/db.c', 'src/json_scan.c', 'src/json_dispatch.c']] +
                       [str(wrapper), '-pthread', '-lpq', '-lcrypto', '-lcrypt', '-o', str(library)], check=True)
        lib = C.CDLL(str(library))
        signatures = {
            'nc_request_create': ([C.c_char_p, C.c_size_t], C.c_void_p),
            'nc_request_free': ([C.c_void_p], None),
            'nc_db_open': ([C.c_char_p], C.c_void_p),
            'nc_db_close': ([C.c_void_p], None),
            'nc_status': ([C.c_void_p], C.c_int),
            'nc_response_data': ([C.c_void_p, C.POINTER(C.c_size_t)], C.c_void_p),
            'conduit_handle': ([C.c_void_p, C.c_void_p], None),
            'conduit_batch': ([C.POINTER(C.c_void_p), C.c_int, C.c_void_p], None),
            'reset_measurement': ([], None),
            'measured_bytes': ([], C.c_size_t),
            'measured_fields': ([], C.c_size_t),
            'measured_authentications': ([], C.c_size_t),
        }
        for name, (arguments, result) in signatures.items():
            getattr(lib, name).argtypes = arguments
            getattr(lib, name).restype = result

        os.environ['READ_COALESCE'] = 'invalid'
        assert not lib.nc_db_open(url.encode())

        def request(path, authorization=None):
            wire = b'GET ' + path.encode() + b' HTTP/1.1\r\nHost: test\r\n'
            if authorization:
                wire += b'Authorization: Token ' + authorization + b'\r\n'
            wire += b'\r\n'
            result = lib.nc_request_create(wire, len(wire))
            assert result
            return result

        def response(r):
            size = C.c_size_t()
            body = lib.nc_response_data(r, C.byref(size))
            return lib.nc_status(r), json.loads(C.string_at(body, size.value))

        def connection(coalesce, pipeline):
            os.environ['READ_COALESCE'] = str(coalesce)
            os.environ['READ_PIPELINE'] = str(pipeline)
            d = lib.nc_db_open(url.encode())
            assert d
            return d

        paths = ['/api/tags', '/api/profiles/alice', '/api/profiles/absent',
                 '/api/articles/article-1', '/api/articles/absent',
                 '/api/articles/article-1/comments', '/api/articles/article-2/comments',
                 '/api/articles/absent/comments', '/api/articles?limit=5',
                 '/api/articles?limit=5&offset=5', '/api/articles?tag=alpha&limit=3',
                 '/api/articles?author=alice&limit=2', '/api/articles?favorited=reader&limit=2',
                 '/api/articles/feed?limit=4', '/api/articles/feed?limit=4&offset=4',
                 '/api/articles?limit=0', '/api/articles?offset=9223372036854775807']
        inputs = [(path, token(viewer) if viewer else None)
                  for path in paths for viewer in (0, 1, 2)]
        inputs += [('/api/articles?limit=5', token(1, expired=True)),
                   ('/api/profiles/alice', b'invalid')]
        inputs *= 2
        assert len(inputs) <= 128
        d = connection(0, 0)
        expected = []
        for path, authorization in inputs:
            r = request(path, authorization)
            lib.conduit_handle(r, d)
            expected.append(response(r))
            lib.nc_request_free(r)
        lib.nc_db_close(d)
        for pipeline in (0, 1):
            measurements = []
            for coalesce in (0, 1):
                d = connection(coalesce, pipeline)
                requests = (C.c_void_p * len(inputs))(*(request(*i) for i in inputs))
                lib.reset_measurement()
                lib.conduit_batch(requests, len(inputs), d)
                actual = [response(r) for r in requests]
                size = C.c_size_t()
                addresses = [lib.nc_response_data(r, C.byref(size)) for r in requests]
                assert len(set(addresses)) == len(requests), 'response storage is aliased'
                assert actual == expected, (pipeline, coalesce, next(
                    (i, inputs[i], a, b) for i, (a, b) in enumerate(zip(actual, expected)) if a != b))
                assert lib.measured_authentications() == sum(path != '/api/tags' for path, _ in inputs)
                measurements.append(lib.measured_bytes())
                # Free every representative first; copied response storage must survive.
                for i in range(len(inputs) // 2):
                    lib.nc_request_free(requests[i])
                for i in range(len(inputs) // 2, len(inputs)):
                    assert response(requests[i]) == expected[i]
                    lib.nc_request_free(requests[i])
                # A later batch must observe a committed change.
                before = json.loads(db.execute("SELECT to_json(bio) FROM users WHERE username='alice'"))
                try:
                    db.execute("UPDATE users SET bio='fresh-coalesce-test' WHERE username='alice'")
                    r = request('/api/profiles/alice')
                    one = (C.c_void_p * 1)(r)
                    lib.conduit_batch(one, 1, d)
                    assert response(r)[1]['profile']['bio'] == 'fresh-coalesce-test'
                    lib.nc_request_free(r)
                finally:
                    from batch_sql import literal
                    db.execute("UPDATE users SET bio=" + ("NULL" if before is None else literal(before)) + " WHERE username='alice'")
                lib.nc_db_close(d)
            assert measurements[1] < measurements[0] * 0.6, measurements
            print(f'PASS: pipeline={pipeline}: {len(inputs)} responses match individual handlers; '
                  f'every token checked; parameter bytes {measurements[0]} -> {measurements[1]}; '
                  'independent buffers and later-batch freshness')


        # Distinct authenticated viewers cannot share complete responses. Only
        # the public article fragments may be shared; both flags must stay personal.
        inputs = [('/api/articles?limit=20', token(viewer)) for viewer in range(1, 33)]
        expected = []
        d = connection(0, 0)
        for item in inputs:
            r = request(*item)
            lib.conduit_handle(r, d)
            expected.append(response(r))
            lib.nc_request_free(r)
        lib.nc_db_close(d)
        for pipeline in (0, 1):
            fields = []
            parameters = []
            for shared in (0, 1):
                d = connection(shared, pipeline)
                requests = (C.c_void_p * len(inputs))(*(request(*item) for item in inputs))
                lib.reset_measurement()
                lib.conduit_batch(requests, len(inputs), d)
                assert [response(r) for r in requests] == expected
                assert lib.measured_authentications() == len(inputs)
                fields.append(lib.measured_fields())
                parameters.append(lib.measured_bytes())
                size = C.c_size_t()
                assert len({lib.nc_response_data(r, C.byref(size)) for r in requests}) == len(inputs)
                for r in requests:
                    lib.nc_request_free(r)
                lib.nc_db_close(d)
            assert parameters[0] == parameters[1], 'distinct viewers were merged'
            assert fields[1] < fields[0] * 0.6, fields
            print(f'PASS: pipeline={pipeline}: 32 distinct viewers retain personal flags; '
                  f'text field reads {fields[0]} -> {fields[1]}; no response aliases')


if __name__ == '__main__':
    main()
