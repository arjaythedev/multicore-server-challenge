"""Static wiring check: composition-root imports cleanly and all 19 endpoints registered."""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import conduit_server.adapters.inbound.controllers as controllers  # noqa: F401,E402
from conduit_server.adapters.inbound.router import router


def main():
    methods = sorted(f"{r.method} {r.pattern.pattern}" for r in router.routes)
    expected = 19
    assert len(router.routes) == expected, (
        f"expected {expected} routes, got {len(router.routes)}\n" + "\n".join(methods)
    )
    print("CHECK_OK: 19 routes registered")
    for line in methods:
        print(" ", line)


if __name__ == "__main__":
    main()
