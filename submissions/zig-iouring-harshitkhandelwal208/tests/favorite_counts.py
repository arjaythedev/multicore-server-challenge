#!/usr/bin/env python3
"""Narrow favorite-count regression; requires a disposable database and Zig/libpq.

Usage: python3 tests/favorite_counts.py --dsn postgresql://USER:PASS@HOST:PORT/DB
Compiles the actual single/array SQL from src/sql.zig, checks binary result types,
then verifies normal/idempotent requests and proven concurrent insert/delete waits.
Only uniquely named fixture rows are changed. No schema or isolation is changed.
--save-sql/--sql-file retain/replay pre-fix SQL for red/green comparisons.
"""
import argparse
from collections import Counter
import ctypes as c
import ctypes.util
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import select
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
EXPORT = r'''const std = @import("std");
const sql = @import("app");
pub fn main() void {
    inline for (sql.prepared) |d| {
        const name = comptime if (d.id == sql.id(.fav_add)) "single-add"
            else if (d.id == sql.id(.fav_del)) "single-delete"
            else if (d.id == sql.packed_id + 3) "array-add"
            else if (d.id == sql.packed_id + 4) "array-delete"
            else "";
        if (name.len != 0) std.debug.print("-- {s}\n{s}\n", .{name, d.sql});
    }
}
'''
ARTICLE_OIDS = [20, 25, 25, 25, 1184, 1184, 1009, 20, 16, 25, 25, 25, 16, 25]


def require(ok, message):
    if not ok:
        raise AssertionError(message)


def source_sql(zig):
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / '.zig-cache/global'))
    with tempfile.TemporaryDirectory(prefix='favorite-counts-', dir=ROOT / '.zig-cache') as tmp:
        exporter = Path(tmp) / 'dump.zig'
        exporter.write_text(EXPORT)
        result = subprocess.run([zig, 'run', '-O', 'ReleaseSafe', '--dep', 'app',
                                 '-Mroot=' + str(exporter), '-Mapp=' + str(ROOT / 'src/sql.zig')],
                                cwd=ROOT, env=env, capture_output=True, text=True, timeout=120)
    require(result.returncode == 0, 'SQL export failed:\n' + result.stderr)
    parts = re.split(r'^-- ([a-z-]+)\n', result.stderr, flags=re.M)
    require(not parts[0].strip(), 'unexpected SQL exporter output: ' + parts[0])
    queries = dict(zip(parts[1::2], (sql.strip() for sql in parts[2::2])))
    require(set(queries) == {'single-add', 'single-delete', 'array-add', 'array-delete'},
            'SQL exporter did not find all four favorite statements')
    return queries


@dataclass
class Result:
    oids: list
    formats: list
    rows: list


class Database:
    def __init__(self, lib, dsn):
        self.lib = lib
        self.conn = lib.PQconnectdb(dsn.encode())
        if not self.conn or lib.PQstatus(self.conn) != 0:
            message = self.error() if self.conn else 'allocation failed'
            self.close()
            raise RuntimeError('libpq connect: ' + message)
        self.pid = lib.PQbackendPID(self.conn)

    def error(self):
        return self.lib.PQerrorMessage(self.conn).decode(errors='replace').strip()

    def close(self):
        if self.conn:
            self.lib.PQfinish(self.conn)
            self.conn = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()  # A failed test also disconnects/rolls back any open transaction.

    def result(self, res):
        if not res:
            raise RuntimeError(self.error())
        try:
            if self.lib.PQresultStatus(res) not in (1, 2):
                raise RuntimeError(self.lib.PQresultErrorMessage(res).decode(errors='replace'))
            n = self.lib.PQnfields(res)
            rows = [[None if self.lib.PQgetisnull(res, i, j) else
                     c.string_at(self.lib.PQgetvalue(res, i, j), self.lib.PQgetlength(res, i, j))
                     for j in range(n)] for i in range(self.lib.PQntuples(res))]
            return Result([self.lib.PQftype(res, j) for j in range(n)],
                          [self.lib.PQfformat(res, j) for j in range(n)], rows)
        finally:
            self.lib.PQclear(res)

    def query(self, sql):
        return self.result(self.lib.PQexec(self.conn, sql.encode()))

    def prepare(self, sql, array):
        types = (c.c_uint * 2)(1016, 1009) if array else (c.c_uint * 2)(20, 25)
        self.result(self.lib.PQprepare(self.conn, b'favorite', sql.encode(), 2, types))

    def send(self, params):
        values = (c.c_char_p * 2)(*(value.encode() for value in params))
        require(self.lib.PQsendQueryPrepared(self.conn, b'favorite', 2, values, None, None, 1) == 1,
                'sending favorite statement failed: ' + self.error())

    def receive(self):
        results = []
        deadline = time.monotonic() + 10
        while True:
            require(self.lib.PQconsumeInput(self.conn) == 1, self.error())
            if self.lib.PQisBusy(self.conn):
                left = deadline - time.monotonic()
                require(left > 0, 'favorite result exceeded 10 seconds')
                select.select([self.lib.PQsocket(self.conn)], [], [], min(left, .1))
                continue
            res = self.lib.PQgetResult(self.conn)
            if not res:
                break
            results.append(self.result(res))
        require(len(results) == 1, 'expected exactly one favorite statement result')
        return results[0]


def libpq(path):
    lib = c.CDLL(path or ctypes.util.find_library('pq') or 'libpq.so')
    ptr, text, integer = c.c_void_p, c.c_char_p, c.c_int
    signatures = {
        'PQconnectdb': ([text], ptr), 'PQstatus': ([ptr], integer),
        'PQerrorMessage': ([ptr], text), 'PQfinish': ([ptr], None),
        'PQbackendPID': ([ptr], integer), 'PQexec': ([ptr, text], ptr),
        'PQprepare': ([ptr, text, text, integer, c.POINTER(c.c_uint)], ptr),
        'PQsendQueryPrepared': ([ptr, text, integer, c.POINTER(text),
                                 c.POINTER(integer), c.POINTER(integer), integer], integer),
        'PQconsumeInput': ([ptr], integer), 'PQisBusy': ([ptr], integer),
        'PQsocket': ([ptr], integer), 'PQgetResult': ([ptr], ptr),
        'PQresultStatus': ([ptr], integer), 'PQresultErrorMessage': ([ptr], text),
        'PQnfields': ([ptr], integer), 'PQntuples': ([ptr], integer),
        'PQftype': ([ptr, integer], c.c_uint), 'PQfformat': ([ptr, integer], integer),
        'PQgetisnull': ([ptr, integer, integer], integer),
        'PQgetlength': ([ptr, integer, integer], integer),
        'PQgetvalue': ([ptr, integer, integer], ptr), 'PQclear': ([ptr], None),
    }
    for name, (args, result) in signatures.items():
        fn = getattr(lib, name)
        fn.argtypes, fn.restype = args, result
    return lib


def literal(value):
    return "'" + value.replace("'", "''") + "'"


class Fixtures:
    def __init__(self, db):
        self.db, self.users, self.articles = db, [], []
        prefix = 'favorite_counts_' + uuid.uuid4().hex
        self.slugs = [prefix + '-a', prefix + '-b', prefix + '-missing']
        try:
            for i in range(4):
                name = prefix + '_u' + str(i)
                rows = db.query('INSERT INTO users(username,email,password_hash) VALUES (' +
                                ','.join(map(literal, (name, name + '@test.invalid', 'not-used'))) +
                                ') RETURNING id').rows
                self.users.append(int(rows[0][0]))
            for slug in self.slugs[:2]:
                rows = db.query('INSERT INTO articles(slug,author_id,title,description,body) VALUES (' +
                                literal(slug) + ',' + str(self.users[3]) +
                                ",'favorite count title','description','body') RETURNING id").rows
                self.articles.append(int(rows[0][0]))
        except BaseException:
            self.cleanup()
            raise

    def cleanup(self):
        if self.users:
            self.db.query('DELETE FROM users WHERE id IN (' + ','.join(map(str, self.users)) + ')')

    def reset(self, pairs):
        self.db.query('DELETE FROM favorites WHERE article_id IN (' + ','.join(map(str, self.articles)) + ')')
        if pairs:
            self.db.query('INSERT INTO favorites(user_id,article_id) VALUES ' +
                          ','.join('(%d,%d)' % (self.users[u], self.articles[a]) for u, a in sorted(pairs)))

    def persisted(self):
        rows = self.db.query('SELECT user_id,article_id FROM favorites WHERE article_id IN (' +
                             ','.join(map(str, self.articles)) + ')').rows
        return {(self.users.index(int(u)), self.articles.index(int(a))) for u, a in rows}

    def verify(self, result, members, array, add, before):
        targets = {(u, a) for u, a in members if a < 2}
        expected_state = before | targets if add else before - targets
        persisted = self.persisted()
        require(persisted == expected_state, 'persisted favorites differ: %r != %r' % (persisted, expected_state))
        counts = Counter(a for _, a in persisted)
        require(result.oids == ([20] if array else []) + ARTICLE_OIDS, 'binary result OIDs changed')
        require(all(fmt == 1 for fmt in result.formats), 'favorite result is not binary')

        def number(value):
            require(value is not None and len(value) == 8, 'count/id is not a binary int8')
            return int.from_bytes(value, 'big', signed=True)

        actual = []
        for row in result.rows:
            ordinal = number(row[0]) if array else 1
            cols = row[1:] if array else row
            require(cols[8] in (b'\x00', b'\x01'), 'favorited is not a binary boolean')
            actual.append((ordinal, number(cols[0]), cols[1].decode(), number(cols[7]), cols[8] == b'\x01'))
        expected = [(i, self.articles[a], self.slugs[a], counts[a], add)
                    for i, (_, a) in enumerate(members, 1) if a < 2]
        require(actual == expected, 'response %r != %r; persisted counts independently verified: %r' %
                (actual, expected, dict(counts)))
        return [row[3] for row in actual]


def confirmed_wait(observer, waiter, blocker, label):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        rows = observer.query('SELECT wait_event_type,wait_event,pg_blocking_pids(pid)::text '
                              'FROM pg_stat_activity WHERE pid=' + str(waiter.pid)).rows
        if rows and rows[0][0] == b'Lock':
            pids = rows[0][2].decode().strip('{}').split(',')
            if str(blocker.pid) in pids:
                print('WAIT %s: backend %d blocked by %d on %s' %
                      (label, waiter.pid, blocker.pid, rows[0][1].decode()), flush=True)
                return
        time.sleep(.01)
    raise AssertionError('did not observe the intended transaction wait: ' + label)


def run_case(lib, dsn, fixtures, queries, array, add, release, repeat=False):
    key = ('array-' if array else 'single-') + ('add' if add else 'delete')
    members = [(0, 0), (0, 0), (1, 0), (2, 1), (3, 2)] if array else [(0, 0)]
    before = ({(3, 0), (3, 1), (0, 0)} if array else {(3, 0)}) if release is None else {(3, 1)}
    blocked = {(0, 0), (1, 0)} if array else {(0, 0)}
    if not add:
        before |= blocked | ({(2, 1)} if array and release is not None else set())
    if repeat:
        targets = {(u, a) for u, a in members if a < 2}
        before = before | targets if add else before - targets
    fixtures.reset(before)
    label = key + (' normal' + (' repeated' if repeat else '') if release is None else ' wait/' + release.lower())
    params = (['{' + ','.join(str(fixtures.users[u]) for u, _ in members) + '}',
               '{' + ','.join(fixtures.slugs[a] for _, a in members) + '}'] if array else
              [str(fixtures.users[0]), fixtures.slugs[0]])
    with Database(lib, dsn) as waiter:
        waiter.prepare(queries[key], array)
        waiter.query('BEGIN')
        if release is None:
            waiter.send(params)
            result = waiter.receive()
        else:
            with Database(lib, dsn) as blocker:
                blocker.query('BEGIN')
                pairs = [(fixtures.users[u], fixtures.articles[a]) for u, a in sorted(blocked)]
                if add:
                    blocker.query('INSERT INTO favorites(user_id,article_id) VALUES ' +
                                  ','.join('(%d,%d)' % pair for pair in pairs))
                else:
                    blocker.query('DELETE FROM favorites WHERE (user_id,article_id) IN (' +
                                  ','.join('(%d,%d)' % pair for pair in pairs) + ')')
                waiter.send(params)
                confirmed_wait(fixtures.db, waiter, blocker, label)
                blocker.query(release)
                result = waiter.receive()
        waiter.query('COMMIT')
    counts = fixtures.verify(result, members, array, add, before)
    print('PASS %s: response counts=%r; flags, ordinals, OIDs and persisted rows match' % (label, counts), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dsn', required=True, help='explicit libpq DSN for a disposable database')
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--libpq', help='optional path to the PostgreSQL client library')
    parser.add_argument('--save-sql', type=Path)
    parser.add_argument('--sql-file', type=Path, help='replay saved SQL instead of compiling current sources')
    args = parser.parse_args()
    queries = json.loads(args.sql_file.read_text()) if args.sql_file else source_sql(args.zig)
    if args.save_sql:
        args.save_sql.write_text(json.dumps(queries, indent=2) + '\n')
    lib = libpq(args.libpq)
    failures = []
    with Database(lib, args.dsn) as db:
        fixtures = Fixtures(db)
        try:
            for array in (False, True):
                for add in (True, False):
                    for release, repeat in ((None, False), (None, True), ('COMMIT', False), ('ROLLBACK', False)):
                        try:
                            run_case(lib, args.dsn, fixtures, queries, array, add, release, repeat)
                        except AssertionError as exc:
                            failures.append(str(exc))
                            print('FAIL ' + str(exc), flush=True)
        finally:
            fixtures.cleanup()
    require(not failures, '%d/16 favorite-count cases failed' % len(failures))
    print('PASS 16 favorite-count cases, including eight independently confirmed conflict waits')


if __name__ == '__main__':
    main()
