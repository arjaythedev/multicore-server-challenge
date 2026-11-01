"""EXPLAIN (ANALYZE, BUFFERS) one of our prepared statements (its exact text from src/sql.mojo), as a custom and
as a generic plan.

    python3 tools/explain.py <database> "<statement name from pgss.py>" <param> [<param> ...]
"""
import subprocess
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from pgss import our_statements  # noqa: E402

db, stmt, params = sys.argv[1], sys.argv[2], sys.argv[3:]
query = our_statements().get(stmt)  # the exact SQL the server prepares
if query is None:
    sys.exit(f"no statement named {stmt!r} in src/sql.mojo")
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
