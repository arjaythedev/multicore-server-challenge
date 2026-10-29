#!/usr/bin/env python3
"""Compares two saved runs (Benchmarks/results/<label>/): mean time and allocation per operation, with the change."""
import glob, json, os, sys

def load(label):
    rows = {}
    for f in glob.glob(os.path.join('results', label, '**', '*-report-full*.json'), recursive=True):
        for b in json.load(open(f))['Benchmarks']:
            name = b.get('FullName') or f"{b['Type']}.{b['Method']}"
            name = name.replace('Conduit.Benchmarks.', '')
            rows[name] = (b['Statistics']['Mean'], b['Statistics']['StandardError'], (b.get('Memory') or {}).get('BytesAllocatedPerOperation', 0))
    return rows

def fmt_time(ns):
    for unit, div in (('s', 1e9), ('ms', 1e6), ('us', 1e3)):
        if ns >= div: return f"{ns / div:.2f} {unit}"
    return f"{ns:.1f} ns"

def pct(a, b):
    return f"{(b - a) / a * 100:+.1f}%" if a else "-"

if len(sys.argv) != 3: sys.exit("usage: compare.py <label-a> <label-b>")
a, b = load(sys.argv[1]), load(sys.argv[2])
if not a or not b: sys.exit(f"no results found for {sys.argv[1] if not a else sys.argv[2]} under results/")
print(f"{'benchmark':<52} {sys.argv[1]:>11} {sys.argv[2]:>11} {'time':>8} {sys.argv[1]+' B/op':>12} {sys.argv[2]+' B/op':>12} {'alloc':>8}")
for name in sorted(set(a) & set(b)):
    (ma, ea, ba), (mb, eb, bb) = a[name], b[name]
    # a change smaller than the combined standard error (x3) is noise
    mark = '' if abs(mb - ma) > 3 * (ea + eb) else '  (noise)'
    print(f"{name:<52} {fmt_time(ma):>11} {fmt_time(mb):>11} {pct(ma, mb):>8} {ba:>12.0f} {bb:>12.0f} {pct(ba, bb):>8}{mark}")
for name in sorted(set(a) ^ set(b)):
    print(f"{name:<52} only in {sys.argv[1] if name in a else sys.argv[2]}")
