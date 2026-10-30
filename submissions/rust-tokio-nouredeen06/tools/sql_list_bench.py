#!/usr/bin/env python3
"""Compare prepared list-batch SQL against another submission on a fixed seed.

Requires rustc and psql on PATH. No database changes are made. Example:
  python3 tools/sql_list_bench.py --database conduit_seed \
      --baseline ../rust-tokio-Scooter1337 --repeats 15
Run while application/load benchmarks are stopped. PostgreSQL connection settings
come from the usual PGHOST/PGPORT/PGUSER/PGPASSWORD environment variables.
"""
import argparse
import json
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


FAMILIES = ("all", "tag", "author", "favorited")


def run_psql(database, sql):
    result = subprocess.run(
        ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-d", database],
        input=sql, text=True, capture_output=True, check=True,
    )
    return result.stdout


def queries(directory, scratch, variant):
    source = (directory / "src/read_batch.rs").read_text()
    function = source[source.index("fn shared_list("):source.index("\npub fn same(")]
    path = scratch / f"{variant}.rs"
    path.write_text(
        f'#[path={json.dumps(str(directory / "src/sql.rs"))}] mod sql;\n'
        + function + "\nfn main() {\n"
        + '\n'.join(
            f'''{{ let n = {3 if family == "all" else 4};
            let args = (1..=n).map(|i| format!("${{}}::{{}}[]", i,
                if i == 4 {{ "text" }} else {{ "bigint" }})).collect::<Vec<_>>();
            let names = (1..=n).map(|i| format!("p{{}}", i)).collect::<Vec<_>>();
            std::fs::write({json.dumps(str(scratch / f"{variant}_{family}.sql"))},
                shared_list(sql::LIST_{family.upper()}, &args, &names).unwrap()).unwrap(); }}'''
            for family in FAMILIES
        ) + "\n}\n"
    )
    binary = scratch / variant
    subprocess.run(["rustc", "-A", "dead_code", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
    return {family: (scratch / f"{variant}_{family}.sql").read_text() for family in FAMILIES}


def literal(value):
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    return str(value)


def arrays(values):
    return ["ARRAY[" + ",".join(map(literal, column)) + "]" for column in values]


def inline(query, args):
    return re.sub(r"\$(\d+)", lambda match: args[int(match[1]) - 1], query)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--repeats", type=int, default=15)
    arguments = parser.parse_args()
    if arguments.repeats < 5:
        parser.error("--repeats must be at least 5")
    sample = json.loads(run_psql(arguments.database, """
        SELECT json_build_object(
          'tag', (SELECT t.name FROM article_tags at JOIN tags t ON t.id=at.tag_id
                  WHERE at.article_id=(SELECT max(id) FROM articles) LIMIT 1),
          'author', (SELECT u.username FROM articles a JOIN users u ON u.id=a.author_id
                     ORDER BY a.id DESC LIMIT 1),
          'favorited', (SELECT u.username FROM favorites f JOIN users u ON u.id=f.user_id
                        WHERE f.article_id=(SELECT max(id) FROM articles) LIMIT 1));
    """))
    if any(value is None for value in sample.values()):
        raise RuntimeError("Use the official seed: sample article needs tags and favorites")
    with tempfile.TemporaryDirectory(prefix="conduit-sql-") as tmp:
        sql_by_variant = {variant: queries(directory.resolve(), Path(tmp), variant)
                          for variant, directory in (("baseline", arguments.baseline),
                                                     ("candidate", arguments.candidate))}
        # Compare full rows in both directions, including mixed viewers, filters,
        # limits, empty pages and unknown filters. Both SQLs share one snapshot.
        checks = []
        for family in FAMILIES:
            values = [[0, 1, 2, 3, 4, 5], [10, 10, 5, 100, 1, 10],
                      [0, 0, 10, 1000000, 0, 10]]
            if family != "all":
                values.append([sample[family]] * 4 + ["__unknown_filter__", sample[family]])
            args = arrays(values)
            old = inline(sql_by_variant["baseline"][family], args)
            new = inline(sql_by_variant["candidate"][family], args)
            checks.append(f'''WITH old_rows AS ({old}), new_rows AS ({new})
                SELECT '{family}', count(*) FROM (
                  (SELECT * FROM old_rows EXCEPT ALL SELECT * FROM new_rows)
                  UNION ALL (SELECT * FROM new_rows EXCEPT ALL SELECT * FROM old_rows)) mismatch;''')
        comparison = run_psql(arguments.database, "\n".join(checks)).strip().splitlines()
        if any(line.split("|")[-1] != "0" for line in comparison):
            raise RuntimeError("SQL results differ: " + str(comparison))
        print("Result equivalence: all four list families passed mixed-argument checks.", flush=True)
        statements = ["SET plan_cache_mode=force_generic_plan; SET jit=off;"]
        for variant, family_queries in sql_by_variant.items():
            for family, query in family_queries.items():
                types = "bigint[],bigint[],bigint[]" + (",text[]" if family != "all" else "")
                statements.append(f"PREPARE {variant}_{family}({types}) AS {query};")
        labels = []
        for family in FAMILIES:
            for count in (2, 8, 32):
                for page_count in (1, 2):
                    values = [list(range(count)), [10] * count,
                              [i % page_count * 10 for i in range(count)]]
                    if family != "all":
                        values.append([sample[family]] * count)
                    args = ",".join(arrays(values))
                    for repetition in range(arguments.repeats):
                        order = ("baseline", "candidate") if repetition % 2 else ("candidate", "baseline")
                        for variant in order:
                            labels.append((family, count, page_count, variant, repetition))
                            statements.append(
                                "EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "
                                f"EXECUTE {variant}_{family}({args});"
                            )
        output = run_psql(arguments.database, "\n".join(statements))
        decoder, results = json.JSONDecoder(), {}
        for family, count, page_count, variant, repetition in labels:
            output = output.lstrip()
            document, end = decoder.raw_decode(output)
            output = output[end:]
            if repetition >= 3:
                result = document[0]
                results.setdefault((family, count, page_count, variant), []).append(
                    (result["Execution Time"], result["Plan"]["Shared Hit Blocks"])
                )
        for family in FAMILIES:
            for count in (2, 8, 32):
                for page_count in (1, 2):
                    pairs = [results[(family, count, page_count, variant)]
                             for variant in ("baseline", "candidate")]
                    times = [statistics.median(row[0] for row in pair) for pair in pairs]
                    buffers = [statistics.median(row[1] for row in pair) for pair in pairs]
                    print(f"{family:10} requests={count:2} pages={page_count}: "
                          f"{times[0]:.3f} -> {times[1]:.3f} ms "
                          f"({100 * (times[1] / times[0] - 1):+.1f}%), "
                          f"buffer hits {buffers[0]:g} -> {buffers[1]:g}")


if __name__ == "__main__":
    main()
