"""Print the run summary: per-endpoint table, mismatch classes, first mismatches."""
from .runner import Stats

LINE = "-" * 100


def _statuses(counter) -> str:
    return " ".join(f"{code}:{n}" for code, n in sorted(counter.items()))


def print_report(stats: Stats, elapsed: float, total: int) -> int:
    """Write the report to stdout; returns the number of mismatches."""
    bad = sum(stats.bad.values())
    print(LINE)
    print(f"{'endpoint':<48}{'requests':>9}{'mismatch':>9}  statuses (server A)")
    for label in sorted(stats.count):
        print(f"{label:<48}{stats.count[label]:>9}{stats.bad[label]:>9}  {_statuses(stats.status[label])}")
    print(LINE)
    print(f"{total} requests in {elapsed:.1f}s, {bad} mismatches")
    if stats.errors:
        print("5xx / no-response (informational, counted even when both sides agree):")
        for (name, label, code), n in sorted(stats.errors.items()):
            print(f"  server {name}: {label} -> {code}: {n}  e.g. {stats.error_example[(name, label, code)][:230]}")
    _classes(stats)
    for m in stats.shown:
        print(LINE)
        print(f"#{m.index} {m.label}  [{m.reason}]\n  diff: {m.detail}\n  request: {m.request}\n  A: {m.a}\n  B: {m.b}")
    return bad


def _classes(stats: Stats):
    if not stats.classes:
        return
    print(LINE)
    print("mismatch classes (count, endpoint, first differing field, status A/B):")
    for (label, why, sa, sb), (n, first) in sorted(stats.classes.items(), key=lambda kv: -kv[1][0]):
        print(f"  {n:>6}  {label}  [{why}]  {sa}/{sb}\n          e.g. #{first.index} {first.detail}")
