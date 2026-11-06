#!/usr/bin/env python3
"""Independent HTTP/JSON/JWT/bcrypt boundary checks; standard library only."""
import base64
import ctypes as C
import hashlib
import hmac
import json
import os
from pathlib import Path
import random
import shlex
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    os.environ['JWT_SECRET'] = 'request-unit-secret'
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    with tempfile.TemporaryDirectory(prefix='nelua-request-') as directory:
        library = Path(directory) / 'request.so'
        subprocess.run(compiler + ['-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror',
                       '-fPIC', '-shared', '-I' + str(ROOT / 'src'), str(ROOT / 'src/request.c'),
                       str(ROOT / 'src/bcrypt.c'), '-pthread',
                       '-lcrypto', '-lcrypt', '-o', str(library)], check=True)
        lib = C.CDLL(str(library))
        signatures = {
            'nc_request_size': ([C.c_char_p, C.c_size_t], C.c_ssize_t),
            'nc_request_create': ([C.c_char_p, C.c_size_t], C.c_void_p),
            'nc_request_free': ([C.c_void_p], None),
            'nc_method': ([C.c_void_p], C.c_char_p),
            'nc_segments': ([C.c_void_p], C.c_int),
            'nc_segment': ([C.c_void_p, C.c_int], C.c_char_p),
            'nc_query': ([C.c_void_p, C.c_char_p], C.c_char_p),
            'nc_keepalive': ([C.c_void_p], C.c_bool),
            'nc_body': ([C.c_void_p, C.c_char_p], C.c_void_p),
            'nc_field': ([C.c_void_p, C.c_char_p], C.c_void_p),
            'nc_kind': ([C.c_void_p], C.c_int),
            'nc_string': ([C.c_void_p], C.c_char_p),
            'nc_array_length': ([C.c_void_p], C.c_int),
            'nc_array_item': ([C.c_void_p, C.c_int], C.c_void_p),
            'nc_tag_array': ([C.c_void_p, C.c_void_p], C.c_char_p),
            'nc_text_vector': ([C.c_void_p, C.POINTER(C.c_char_p), C.c_int], C.c_char_p),
            'nc_int_vector': ([C.c_void_p, C.POINTER(C.c_int64), C.c_int], C.c_char_p),
            'nc_parse_uint': ([C.c_char_p], C.c_int64),
            'nc_auth': ([C.c_void_p], C.c_int64),
            'nc_token': ([C.c_void_p], C.c_char_p),
            'nc_issue_token': ([C.c_void_p, C.c_int64], C.c_char_p),
            'nc_hash': ([C.c_void_p, C.c_char_p], C.c_char_p),
            'nc_verify': ([C.c_char_p, C.c_char_p], C.c_bool),
            'nc_begin': ([C.c_void_p, C.c_int], C.c_void_p),
            'nc_write_n': ([C.c_void_p, C.c_char_p, C.c_size_t], None),
            'nc_status': ([C.c_void_p], C.c_int),
            'nc_response_data': ([C.c_void_p, C.POINTER(C.c_size_t)], C.c_void_p),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(lib, name)
            function.argtypes = arguments
            function.restype = result

        def wire(body=b'', path=b'/api/tags', headers=b'', method=b'GET'):
            return method + b' ' + path + b' HTTP/1.1\r\nHost: test\r\n' + headers + b'Content-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body

        def request(body=b'', path=b'/api/tags', headers=b'', method=b'GET'):
            raw = wire(body, path, headers, method)
            result = lib.nc_request_create(raw, len(raw))
            assert result, raw
            return result

        raw = wire(b'{"user":{"username":"snow"}}', method=b'POST')
        for length in range(len(raw)):
            assert lib.nc_request_size(raw, length) == 0, length
        assert lib.nc_request_size(raw, len(raw)) == len(raw)
        assert lib.nc_request_size(raw + b'GET /api/tags HTTP/1.1\r\n\r\n', len(raw)+26) == len(raw)
        for headers in [b'Content-Length: 1\r\nContent-Length: 2\r\n',
                        b'Transfer-Encoding: chunked\r\n', b'Content-Length: -1\r\n',
                        b'Bad Header: x\r\n', b'Bad\x00Header: x\r\n', b' Content-Length: 0\r\n', b'X: bad\x00value\r\n']:
            value = b'GET / HTTP/1.1\r\n' + headers + b'\r\n'
            assert lib.nc_request_size(value, len(value)) == -1, headers
        value=b'GET / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n'
        assert lib.nc_request_size(value,len(value)) == -2
        assert lib.nc_request_size(None,0) == 0
        r = request(path=b'/api/profiles/quo%27te%2F%E9%9B%AA?tag=first&tag=second&space=a+b&empty=', headers=b'Connection: close\r\n')
        assert lib.nc_method(r) == b'GET'
        assert lib.nc_segments(r) == 3
        assert lib.nc_segment(r,2) == "quo'te/雪".encode()
        assert lib.nc_segment(r,-1) is None
        assert lib.nc_query(r,b'tag') == b'first'
        assert lib.nc_query(r,b'space') == b'a b'
        assert lib.nc_query(r,b'empty') == b''
        assert lib.nc_query(r,b'absent') is None
        assert not lib.nc_keepalive(r)
        lib.nc_request_free(r)
        for path in [b'/api/%00',b'/api/%',b'/api/%zz']:
            value=wire(path=path)
            assert not lib.nc_request_create(value,len(value))
        for number, expected in [(b'0',0),(b'001',1),(b'9223372036854775807',2**63-1),
                                 (b'9223372036854775808',-1),(b'',-1),(b'+1',-1),
                                 (b' 1',-1),(b'-1',-1),(b'1.0',-1),(b'1e3',-1)]:
            assert lib.nc_parse_uint(number) == expected

        strings = ['plain', 'quote" slash\\ line\n\r\t\b\f', '雪 😀 e\u0301', ''.join(chr(i) for i in range(1,32))]
        rng=random.Random(923)
        alphabet=list('abc雪😀"\\\n\t')
        strings += [''.join(rng.choice(alphabet) for _ in range(rng.randrange(100))) for _ in range(100)]
        for value in strings:
            for ascii_only in [True,False]:
                r=request(json.dumps({'user':{'username':value}},ensure_ascii=ascii_only).encode())
                user=lib.nc_body(r,b'user')
                assert lib.nc_kind(user) == 1
                assert lib.nc_string(lib.nc_field(user,b'username')) == value.encode()
                lib.nc_request_free(r)
        r=request(b'{"user":{"username":"first","username":"last","nil":null,"array":["a","quo\\\"te","back\\\\slash"]}}')
        user=lib.nc_body(r,b'user')
        assert lib.nc_string(lib.nc_field(user,b'username')) == b'last'
        assert lib.nc_kind(lib.nc_field(user,b'nil')) == 0
        array=lib.nc_field(user,b'array')
        assert lib.nc_array_length(array) == 3
        assert lib.nc_string(lib.nc_array_item(array,1)) == b'quo"te'
        assert lib.nc_tag_array(r,array) == b'{"a","quo\\"te","back\\\\slash"}'
        assert lib.nc_text_vector(r,(C.c_char_p*3)(b'a',None,b'NULL'),3) == b'{"a",NULL,"NULL"}'
        assert lib.nc_int_vector(r,(C.c_int64*3)(-2**63,0,2**63-1),3) == b'{-9223372036854775808,0,9223372036854775807}'
        lib.nc_request_free(r)
        malformed=[b'',b'null',b'[]',b'{',b'{}junk',b'{"user":[]}',b'{"user":null}',
                   b'{"user":{"x":"\\u0000"}}',b'{"user":{"x":"\\ud800"}}',b'{"user":{"x":"\\udc00"}}',
                   b'{"user":{"x":"\xc0\x80"}}',b'{"user":{"x":01}}',b'{"user":{"x":1.}}',
                   b'{"user":{"x":1e}}',b'{"user":{"x":truefalse}}',b'{"user":{"x":[1,]}}',b'{"user":{"x":"\\q"}}']
        for value in malformed:
            r=request(value)
            assert not lib.nc_body(r,b'user'), value
            lib.nc_request_free(r)

        def b64(value):
            return base64.urlsafe_b64encode(value).rstrip(b'=')

        def token(payload, algorithm='HS256', key=b'request-unit-secret'):
            header=b64(json.dumps({'alg':algorithm,'typ':'JWT'},separators=(',',':')).encode())
            message=header+b'.'+b64(json.dumps(payload,separators=(',',':')).encode())
            return message+b'.'+b64(hmac.digest(key,message,'sha256'))

        payload={'sub':'42','iat':int(time.time()),'exp':int(time.time())+3600}
        value=token(payload)
        r=request(headers=b'Authorization: Token '+value+b'\r\n')
        assert lib.nc_auth(r) == 42
        assert lib.nc_token(r) == value
        os.environ['JWT_SECRET']='wrong-secret'
        assert lib.nc_auth(r) == -1 # No remembered verification, even inside one request.
        os.environ['JWT_SECRET']='request-unit-secret'
        assert lib.nc_auth(r) == 42
        lib.nc_request_free(r)
        bad=[token({**payload,'exp':0}),token({**payload,'sub':'0'}),token({**payload,'sub':'-1'}),
             token({**payload,'sub':42}),token({**payload,'sub':'9223372036854775808'}),
             token({**payload,'exp':'4102444800'}),token({**payload,'exp':True}),
             token({k:v for k,v in payload.items() if k!='exp'}),token(payload,algorithm='HS512'),
             token(payload,key=b'wrong'),token({**payload,'nbf':4102444800}),value+b'.extra',value[:-1]+b'!']
        for value in bad:
            r=request(headers=b'Authorization: Token '+value+b'\r\n')
            assert lib.nc_auth(r) == -1,value
            lib.nc_request_free(r)
        for headers, expected in [(b'',0),(b'Authorization: Bearer x\r\n',-1),(b'Authorization:\r\n',-1)]:
            r=request(headers=headers)
            assert lib.nc_auth(r) == expected
            lib.nc_request_free(r)
        r=request()
        issued=lib.nc_issue_token(r,42)
        head,body,signature=issued.split(b'.')
        assert hmac.compare_digest(base64.urlsafe_b64decode(signature+b'='),hmac.digest(b'request-unit-secret',head+b'.'+body,'sha256'))
        claims=json.loads(base64.urlsafe_b64decode(body+b'='*((-len(body))%4)))
        assert claims['sub']=='42' and claims['exp']-claims['iat']==2592000
        assert abs(claims['iat']-time.time()) < 5
        first=lib.nc_hash(r,b'password123')
        second=lib.nc_hash(r,b'password123')
        assert first.startswith(b'$2b$10$') and first != second
        assert lib.nc_verify(b'password123',first)
        assert not lib.nc_verify(b'wrong',first)
        assert lib.nc_hash(r,b'x'*73) is None
        assert not lib.nc_verify(b'x'*73,first)
        assert not lib.nc_verify(b'password123',b'$6$unsupported')
        buffer=lib.nc_begin(r,200)
        lib.nc_write_n(buffer,b'{}',2)
        length=C.c_size_t()
        data=lib.nc_response_data(r,C.byref(length))
        assert C.string_at(data,length.value)==b'{}' and lib.nc_status(r)==200
        lib.nc_write_n(buffer,b'x',100000000)
        data=lib.nc_response_data(r,C.byref(length))
        assert lib.nc_status(r)==500 and 'errors' in json.loads(C.string_at(data,length.value))
        lib.nc_request_free(r)
    print('PASS: framing, URL/JSON Unicode and controls, duplicate keys, vectors, independent JWT/HMAC, bcrypt cost10 and response bounds')


if __name__=='__main__':
    main()
