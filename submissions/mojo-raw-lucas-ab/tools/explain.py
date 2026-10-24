"""EXPLAIN (ANALYZE, BUFFERS) one of our prepared statements, taking its exact text from pg_stat_statements (so a
run of the server must have executed it), as a custom and as a generic plan.

    python3 tools/explain.py <database> "<statement name from pgss.py>" <param> [<param> ...]
"""
import subprocess
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from pgss import name, psql  # noqa: E402

db, stmt, params = sys.argv[1], sys.argv[2], sys.argv[3:]
# pg_stat_statements keeps one row per statement; the query text can span lines, so ask for it by name instead
out = psql(db, "select queryid, query from pg_stat_statements where query not like '%pg_stat_statements%' and query !~* '^\\s*(prepare|explain) '"
               " and calls > 0")
query = None
for row in out.split("\n"):
    if "\t" in row and name(row.split("\t", 1)[1]) == stmt:
        query = row.split("\t", 1)[1]
if query is None:
    sys.exit(f"no statement named {stmt!r} in pg_stat_statements")
args = ", ".join("'" + p.replace("'", "''") + "'" for p in params)
script = f"""
PREPARE s AS {query};
SET plan_cache_mode = force_custom_plan;
\\echo ==== custom plan
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON) EXECUTE s({args});
SET plan_cache_mode = force_generic_plan;
\\echo ==== generic plan
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, SUMMARY ON) EXECUTE s({args});
"""
print(subprocess.run(["psql", "-X", "-q", "-d", db], input=script, capture_output=True, text=True).stdout)
