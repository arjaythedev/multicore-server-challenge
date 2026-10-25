"""Group commit under conflicts: while `users` is locked against inserts, 60 registrations (20 usernames x 3, all
different emails) pile up into commit groups that contain duplicates. Each group with a duplicate fails as a whole,
so its members must be retried one by one: exactly one 201 per username, the rest 422, each 201's token naming the
id Postgres stored, and no duplicate rows.

    python3 tests/group_commit_check.py <base url> <database> [lock seconds]
"""
import base64
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

base, db = sys.argv[1], sys.argv[2]
lock_s = float(sys.argv[3]) if len(sys.argv) > 3 else 3
tag = str(int(time.time()))
names = [f"gc{tag}_{i}" for i in range(20)]
jobs = [(n, f"{n}_{k}@example.com") for n in names for k in range(3)]
results = {}


def register(username, email):
    body = json.dumps({"user": {"username": username, "email": email, "password": "group-commit-1"}}).encode()
    req = urllib.request.Request(f"{base}/api/users", data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            results[email] = (r.status, json.load(r))
    except urllib.error.HTTPError as e:
        results[email] = (e.code, json.loads(e.read() or b"{}"))


locker = subprocess.Popen(["psql", "-X", "-q", "-d", db, "-c",
                           f"BEGIN; LOCK TABLE users IN EXCLUSIVE MODE; SELECT pg_sleep({lock_s}); COMMIT;"])
time.sleep(0.3)  # the lock is held before the first insert arrives
threads = [threading.Thread(target=register, args=j) for j in jobs]
t0 = time.time()
for t in threads:
    t.start()
for t in threads:
    t.join()
locker.wait()
elapsed = time.time() - t0

bad = 0
for n in names:
    statuses = sorted(results[e][0] for u, e in jobs if u == n)
    if statuses != [201, 422, 422]:
        bad += 1
        print("FAIL", n, statuses)
rows = subprocess.run(["psql", "-X", "-At", "-d", db, "-c",
                       f"select username, id, count(*) over (partition by username) from users where username like 'gc{tag}_%'"],
                      capture_output=True, text=True, check=True).stdout.split()
stored = {}
for r in rows:
    u, i, c = r.split("|")
    stored[u] = int(i)
    if c != "1":
        bad += 1
        print("FAIL duplicate rows for", u)
for email, (status, body) in results.items():
    if status == 201:
        u = body["user"]["username"]
        payload = body["user"]["token"].split(".")[1]
        sub = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["sub"]
        if int(sub) != stored.get(u):
            bad += 1
            print("FAIL token sub", sub, "but", u, "has id", stored.get(u))
print(f"{len(jobs)} registrations in {elapsed:.1f} s ({lock_s:.0f} s of it locked): {len(stored)} users stored, "
      + ("all correct" if bad == 0 else f"{bad} failures"))
sys.exit(1 if bad else 0)
