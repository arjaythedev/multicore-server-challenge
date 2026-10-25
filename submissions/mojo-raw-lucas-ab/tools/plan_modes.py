"""Planning and execution time of one prepared statement under each plan_cache_mode x jit combination, after a
few warm-up executions in the same session (as on a long-lived connection).

    python3 tools/plan_modes.py <database> "<statement name from pgss.py>" <param> [<param> ...]
"""
import re
import subprocess
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from pgss import our_statements  # noqa: E402

RUNS = 5

db, stmt, params = sys.argv[1], sys.argv[2], sys.argv[3:]
query = our_statements().get(stmt)  # the exact SQL the server prepares
if query is None:
    sys.exit(f"no statement named {stmt!r} in src/sql.mojo")
args = ", ".join("'" + p.replace("'", "''") + "'" for p in params)
print(f"{stmt}({args})")
for mode in ("force_custom_plan", "force_generic_plan"):
    for jit in ("on", "off"):
        script = f"PREPARE s AS {query};\nSET plan_cache_mode = {mode};\nSET jit = {jit};\n"
        call = f"s({args})" if args else "s"
        script += f"EXPLAIN (ANALYZE, SUMMARY ON) EXECUTE {call};\n" * RUNS
        r = subprocess.run(["psql", "-X", "-q", "-d", db], input=script, capture_output=True, text=True)
        text = r.stdout + r.stderr
        plan = [float(x) for x in re.findall(r"Planning Time: ([\d.]+) ms", text)]
        exe = [float(x) for x in re.findall(r"Execution Time: ([\d.]+) ms", text)]
        jit_ms = [float(x) for x in re.findall(r"Total ([\d.]+) ms", text)]
        if not exe:
            print(f"  {mode:20s} jit={jit:3s} ERROR {text.strip()[:200]}")
            continue
        # the last runs reflect a warm session; report their median
        tail_p, tail_e = sorted(plan[-3:]), sorted(exe[-3:])
        print(f"  {mode:20s} jit={jit:3s} plan {tail_p[1]:7.3f} ms  exec {tail_e[1]:8.3f} ms"
              + (f"  (JIT {sorted(jit_ms[-3:])[1]:.1f} ms)" if jit_ms else ""))
