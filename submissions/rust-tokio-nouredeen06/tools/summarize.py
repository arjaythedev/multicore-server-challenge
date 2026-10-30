#!/usr/bin/env python3
"""Summarize bench.py results, limiting CPU samples to the measured interval."""
import argparse
import json
from pathlib import Path


def summarize(directory):
    merged = json.loads((directory / "merged.json").read_text())
    meta = json.loads((directory / "metadata.json").read_text())
    samples = json.loads((directory / "monitor.json").read_text())
    start = merged["start_at_ms"] / 1000 + merged["ramp_s"]
    samples = [s for s in samples if start <= s["time"] <= start + merged["measure_s"]]
    first, last = samples[0], samples[-1]
    elapsed = last["time"] - first["time"]
    return dict(
        run=directory.name, users=merged["users"], think_scale=meta["args"]["think_scale"],
        measure_s=merged["measure_s"], **merged["overall"], **merged["verdict"],
        app_cores=(last["app_cpu_s"] - first["app_cpu_s"]) / elapsed,
        pg_cores=(last["pg_cpu_s"] - first["pg_cpu_s"]) / elapsed,
        app_peak_mib=max(s["app_rss"] for s in samples) / 1024**2,
        loadgen_cores=merged["boxes"][0]["proc_cpu_avg_measure_pct"] * meta["logical_cpus"] / 100,
        settings=meta["settings"],
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", nargs="+", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    rows = [summarize(d) for d in args.directories]
    print("| Run | req/s | p95 ms | p99 ms | Errors | App cores | PG cores | RSS MiB | Pass / LG limited |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in rows:
        print(f"| {r['run']} | {r['rps']:.0f} | {r['p95_ms']:.1f} | {r['p99_ms']:.1f} | "
              f"{r['errors']} | {r['app_cores']:.2f} | {r['pg_cores']:.2f} | "
              f"{r['app_peak_mib']:.0f} | {r['pass']} / {r['lg_limited']} |")
    if args.json:
        args.json.write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
