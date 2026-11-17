#!/usr/bin/env python3
"""Export shared SQL data for the independently authored C application.

Only statement text is copied. No generated application logic enters the C
counterpart. Named and inline statements come from the Nelua sources; the five
compile-time batch statements come from the compiler's expanded string literals.
"""
import argparse
import ast
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def statements(generated):
    result = {}
    named = dict(re.findall(r'local (q_\w+):\s*cstring <comptime> = \[\[(.*?)\]\]',
                            (ROOT / 'src/reads.nelua').read_text(), re.S))
    names = ['tags', 'profile', 'article', 'article_id', 'list_all', 'list_tag',
             'list_author', 'list_favorite', 'list_feed', 'comments']
    for identifier, name in enumerate(names):
        sql = named['q_' + name]
        result[identifier] = sql[1:] if sql.startswith('\n') else sql
    for file in ['mutations.nelua', 'batch.nelua']:
        for identifier, sql in re.findall(r'N\.query\(db,\s*(\d+),\s*\[\[(.*?)\]\]',
                                          (ROOT / 'src' / file).read_text(), re.S):
            identifier = int(identifier)
            if identifier in result:
                raise ValueError('duplicate SQL ID ' + str(identifier))
            result[identifier] = sql[1:] if sql.startswith('\n') else sql
    families = {}
    pattern = r'static(?: const)? char \w+\[\d+\]\s*=\s*("(?:[^"\\]|\\.)*");'
    for match in re.finditer(pattern, generated.read_text()):
        sql = ast.literal_eval(match.group(1))
        if 'page_keys AS MATERIALIZED' not in sql:
            continue
        if 'WHERE fo.follower_id=k.owner' in sql:
            identifier = 98
        elif 'FROM public.article_tags x WHERE x.tag_id=f.id' in sql:
            identifier = 95
        elif 'FROM public.articles a WHERE a.author_id=f.id' in sql:
            identifier = 96
        elif 'FROM public.favorites x WHERE x.user_id=f.id' in sql:
            identifier = 97
        else:
            identifier = 94
        if identifier in families and families[identifier] != sql:
            raise ValueError('ambiguous batch SQL ID ' + str(identifier))
        families[identifier] = sql
    if set(families) != set(range(94, 99)):
        raise ValueError('missing expanded batch statement')
    result.update(families)
    if set(result) != set(range(10)) | set(range(40, 55)) | set(range(90, 99)):
        raise ValueError('unexpected statement ID set: ' + repr(sorted(result)))
    return result


def c_literal(value):
    # All challenge SQL is ASCII. C's universal-character escapes are not an
    # encoding transport for arbitrary UTF-8; reject such input explicitly.
    value.encode('ascii')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generated-c', type=Path, default=ROOT / 'build/app.c')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    queries = statements(args.generated_c)
    digest = hashlib.sha256(''.join(str(i) + '\0' + queries[i] + '\0'
                                   for i in sorted(queries)).encode()).hexdigest()
    text = ('/* Shared statement DATA only. Regenerate with tools/export_sql.py.\n'
            ' * SQL SHA256: ' + digest + '\n */\n'
            '#ifndef NC_SQL_SHARED_H\n#define NC_SQL_SHARED_H\n'
            'static const char *const nc_sql[128] = {\n' +
            ''.join('    [' + str(i) + '] = ' + c_literal(queries[i]) + ',\n'
                    for i in sorted(queries)) + '};\n#endif\n')
    target = ROOT / 'src/sql_shared.h'
    if args.check:
        if not target.is_file() or target.read_text() != text:
            raise SystemExit('shared SQL differs; regenerate with tools/export_sql.py')
        print('PASS: all 34 C statements match the Nelua source/expanded SQL')
    else:
        target.write_text(text)
        print('wrote', target, '(34 statements, data only)')


if __name__ == '__main__':
    main()
