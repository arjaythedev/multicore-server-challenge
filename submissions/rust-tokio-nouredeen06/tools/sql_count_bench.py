#!/usr/bin/env python3
"""Check count-cap boundaries and compare prepared global-list query times."""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess


def extract(folder):
    source = (folder / "src/sql.rs").read_text()
    query = re.search(r'pub const LIST_ALL: &str = r#"(.*?)"#;', source, re.S)[1]
    prefix = "WITH c AS ("
    count = query[len(prefix):query.index(") SELECT c.n,")]
    return query, count


def psql(database, sql):
    return subprocess.run(["psql", "-XqAt", "-v", "ON_ERROR_STOP=1", "-d", database],
                          input=sql, capture_output=True, text=True, check=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", default="conduit_seed")
    parser.add_argument("--baseline", type=Path, required=True)
    args = parser.parse_args()
    folder = Path(__file__).resolve().parents[1]
    old, old_count = extract(args.baseline)
    new, new_count = extract(folder)
    assert new_count in (folder / "src/read_batch.rs").read_text(), "batch count must match"
    checks = []
    for size in (0, 1, 2, 999, 1000, 1001):
        # A CTE supplies a smaller relation with the same id column, without
        # changing schema/data. Cover both sides of the cap and the empty case.
        checks.append(f"WITH articles AS (SELECT id FROM public.articles LIMIT {size}), "
                      f"a AS ({old_count}), b AS ({new_count}) SELECT a.n = b.n FROM a,b;")
    assert psql(args.database, "\n".join(checks)).splitlines() == ["t"] * len(checks)
    print("PASS exact-count boundaries: 0, 1, 2, 999, 1000, 1001 rows.")
    queries = dict(baseline=old, candidate=new)
    commands = ["SET plan_cache_mode=force_generic_plan; SET jit=off;"]
    for name, query in queries.items():
        commands.append(f"PREPARE {name}(bigint,bigint,bigint) AS {query};")
    labels = []
    for offset in (0, 40, 1000):
        for rep in range(40):
            for name in (list(queries) if rep % 2 else list(queries)[::-1]):
                labels.append((offset, name, rep))
                commands.append("EXPLAIN(ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "
                                f"EXECUTE {name}(1,10,{offset});")
    output = psql(args.database, "\n".join(commands))
    decoder, measurements = json.JSONDecoder(), {}
    for offset, name, rep in labels:
        output = output.lstrip()
        document, end = decoder.raw_decode(output)
        output = output[end:]
        if rep >= 5:
            measurements.setdefault((offset, name), []).append(document[0]["Execution Time"])
    for offset in (0, 40, 1000):
        old_ms, new_ms = (statistics.median(measurements[offset, name]) for name in queries)
        print(f"offset={offset}: {old_ms:.3f} -> {new_ms:.3f} ms "
              f"({(new_ms / old_ms - 1) * 100:+.1f}%)")


if __name__ == "__main__":
    main()
