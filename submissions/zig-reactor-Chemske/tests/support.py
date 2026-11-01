"""Shared, standard-library-only helpers for disposable integration runs."""
import base64
import hmac
import http.client
import json
import os
import re
import socket
import subprocess
import time


def sql(statement, database='postgres'):
    return subprocess.check_output(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At',
                                    '-d', database, '-c', statement], text=True).strip()


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def mint(identifier, secret, expiry=None):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')
    now = int(time.time())
    message = encode({'alg': 'HS256'}) + b'.' + encode({'sub': str(identifier), 'iat': now, 'exp': now + 3600 if expiry is None else expiry})
    return (message + b'.' + base64.urlsafe_b64encode(hmac.digest(secret.encode(), message, 'sha256')).rstrip(b'=')).decode()


class Server:
    def __init__(self, results, secret, prefix, label, executable, database_port=None, template='conduit_dev', listen_host='127.0.0.1'):
        self.results = results
        self.secret = secret
        self.database = f'challenge_{prefix}_{label}_{os.getpid()}'
        self.port = free_port()
        self.executable = executable
        self.process = None
        self.log = None
        self.database_port = database_port
        self.listen_host = listen_host
        assert template in ('conduit_dev', 'conduit_seed')
        self.template = template

    def __enter__(self):
        sql(f'CREATE DATABASE {self.database} TEMPLATE {self.template}')
        try:
            self.log = (self.results / f'{self.database}.log').open('w')
            database_port = self.database_port or os.environ['PGPORT']
            options = '?sslmode=disable&gssencmode=disable' if self.database_port is not None else ''
            environment = dict(os.environ, HOST=self.listen_host, PORT=str(self.port), JWT_SECRET=self.secret,
                               DATABASE_URL=f"postgres://conduit:conduit@127.0.0.1:{database_port}/{self.database}{options}")
            self.process = subprocess.Popen([str(self.executable)], env=environment, stdout=self.log, stderr=self.log)
            deadline = time.monotonic() + 60
            while True:
                try:
                    assert self.request('GET', '/api/tags')[0] == 200
                    return self
                except OSError:
                    if self.process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('server did not become healthy')
                    time.sleep(0.03)
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        if self.log is not None:
            self.log.close()
        sql(f'DROP DATABASE IF EXISTS {self.database} WITH (FORCE)')

    def request(self, method, path, token=None, body=None, headers=None):
        fields = dict(headers or {})
        if token is not None:
            fields['Authorization'] = 'Token ' + token
        if body is not None and not isinstance(body, (str, bytes)):
            body = json.dumps(body).encode()
            fields['Content-Type'] = 'application/json'
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        try:
            connection.request(method, path, body=body, headers=fields)
            response = connection.getresponse()
            raw = response.read()
            if response.status == 204:
                assert raw == b''
                data = None
            else:
                data = json.loads(raw)
                assert response.getheader('Content-Type') == 'application/json'
            if response.status >= 400:
                assert set(data) == {'errors'} and isinstance(data['errors']['body'][0], str)
            return response.status, data
        finally:
            connection.close()

    def sql(self, statement):
        return sql(statement, self.database)

    def fixture(self, username):
        return int(self.sql(f"INSERT INTO users(username,email,password_hash) SELECT {literal(username)}, {literal(username + '@example.com')}, password_hash FROM users WHERE id=1 RETURNING id").splitlines()[0])


def upstream(server, label, executable):
    results, secret = server.results, server.secret
    transcript = results / f'{label}.jsonl'
    run = subprocess.run([str(executable), '-base', f'http://127.0.0.1:{server.port}',
                          '-secret', secret, '-transcript', str(transcript)],
                         capture_output=True, text=True, timeout=90)
    (results / f'{label}.log').write_text(run.stdout + run.stderr)
    steps = [line for line in run.stdout.splitlines() if re.match(r'^(PASS|FAIL) (users\.|user\.|profile\.)', line)]
    assert steps and all(line.startswith('PASS ') for line in steps), '\n'.join(steps)
    summary = next(line for line in run.stdout.splitlines() if re.match(r'^\d+ steps,', line))
    return run, [json.loads(line) for line in transcript.read_text().splitlines()], steps, summary


def raw_response(reader):
    line = reader.readline()
    assert line, 'connection ended before response headers'
    status = int(line.split()[1])
    headers = {}
    while True:
        line = reader.readline()
        if line == b'\r\n':
            break
        assert line
        key, value = line.decode().split(':', 1)
        headers[key.lower()] = value.strip()
    if status == 204:
        assert 'content-length' not in headers
        return status, None
    return status, json.loads(reader.read(int(headers['content-length'])))


