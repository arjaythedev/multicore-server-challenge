#!/usr/bin/env python3
import csv
import sys
from decimal import Decimal
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("Usage: python3 sql-diff.py RUN_ID")

root = Path(__file__).resolve().parent
run_id = sys.argv[1]

if not run_id.replace("-", "").replace("_", "").isalnum():
    raise SystemExit("Invalid RUN_ID")

directory = root / "runs" / run_id

def load(name):
    with (directory / name).open(newline="") as f:
        return {
            (
                row["dbid"],
                row["userid"],
                row["toplevel"],
                row["queryid"],
            ): row
            for row in csv.DictReader(f)
        }

before = load("sql-begin.csv")
after = load("sql-end.csv")

begin_meta = (directory / "sql-begin.meta").read_text().strip()
end_meta = (directory / "sql-end.meta").read_text().strip()

if begin_meta != end_meta:
    raise SystemExit(
        "WARNING: pg_stat_statements reset/deallocation "
        "changed during test. Delta may be unreliable."
    )

results = []

for key, row in after.items():
    previous = before.get(key)

    old_calls = int(previous["calls"]) if previous else 0
    old_time = Decimal(previous["total_exec_time"]) if previous else Decimal(0)

    calls = int(row["calls"]) - old_calls
    total_ms = Decimal(row["total_exec_time"]) - old_time

    if calls < 0 or total_ms < 0:
        raise SystemExit("Counters decreased; cannot calculate reliable delta")

    if calls == 0:
        continue

    results.append({
        "calls": calls,
        "total_ms": total_ms,
        "mean_ms": total_ms / calls,
        "sql": " ".join(row["query"].split())[:130],
    })

results.sort(key=lambda x: x["total_ms"], reverse=True)

print(f"RUN_ID: {run_id}")
print(f"{'CALLS':>9} {'TOTAL_MS':>12} {'MEAN_MS':>11}  SQL")

for item in results[:25]:
    print(
        f"{item['calls']:>9} "
        f"{item['total_ms']:>12.2f} "
        f"{item['mean_ms']:>11.3f}  "
        f"{item['sql']}"
    )
