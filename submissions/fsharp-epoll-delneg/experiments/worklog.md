# Worklog: fsharp-epoll-delneg

Harness (our box, NOT official): wsl26, 24 CPUs (AMD, WSL2 kernel 6.18), Postgres 18 cluster pinned to CPUs 0-7,
server as user `challenge` in a systemd unit with `LimitNOFILE=200000` on CPUs 0-7, the real `bench/cmd/loadgen`
on other CPUs at real think time, full seed (fresh copy per search), box sysctls. Search like the scorer: 3-minute
warm-up at 500 users, 2-minute probes doubling from 25k then bisecting to 5%, 5-minute hold stepping down 5%.
Script: `experiments/h.sh`.

## Experiments

- **e01 #87 (`9de3218`) on the harness** (reference): probes 25k, 50k, 100k, 150k, 180k pass at 100-111 µs/req
  (app 45, PG 55-65); 190k and 200k flagged LG-limited (the load generator processes shared one CPU set and fell
  behind; fixed in the harness afterwards).
