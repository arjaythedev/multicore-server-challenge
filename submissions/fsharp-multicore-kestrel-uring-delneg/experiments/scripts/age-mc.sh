#!/bin/bash
# age-mc.sh: conduit_aged = conduit_seed + a run's worth of writes (after McscResearch's age2.sql, ids relative to
# the seed's max), autovacuum left on, then ANALYZE. For SQL replays only.
set -e
free=$(df -B1M --output=avail / | tail -1); if [ $free -lt 5500 ]; then echo "age-mc: only ${free} MB free, need 5500 (aged copy ~2.6 GB + WAL)"; exit 1; fi
P="sudo -u postgres psql -X -q -v ON_ERROR_STOP=1"
$P -d postgres -c "DROP DATABASE IF EXISTS conduit_aged" -c "CREATE DATABASE conduit_aged TEMPLATE conduit_seed"
$P -d conduit_aged <<'SQL'
SELECT setseed(0.8);
-- authors by article (weighted by article count), looked up by a random row number: subscripting one big array
-- per row detoasted all of it every time (30+ min)
CREATE TEMP TABLE au AS SELECT (row_number() OVER (ORDER BY id))::int AS i, author_id AS a FROM articles;
CREATE UNIQUE INDEX ON au (i); ANALYZE au;
SELECT count(*) AS na FROM au \gset
SELECT max(id) AS m0 FROM articles \gset
INSERT INTO articles (slug, author_id, title, description, body)
SELECT 'aged-' || s.g, au.a, 'T' || s.g, 'D' || s.g, repeat('x', 1000)
  FROM (SELECT g, 1 + floor(random() * :na)::int AS ix FROM generate_series(1, 120000) g) s JOIN au ON au.i = s.ix ORDER BY s.g;
SELECT max(id) AS m FROM articles \gset
INSERT INTO article_tags (article_id, tag_id)
SELECT a.id, x.t FROM articles a CROSS JOIN LATERAL (SELECT DISTINCT 1 + floor(power(random(), 3) * 200)::int AS t FROM generate_series(1, 3) s WHERE s > a.id * 0) x WHERE a.id > :m0 ON CONFLICT DO NOTHING;
INSERT INTO favorites (user_id, article_id)
SELECT 1 + floor(random() * 100000)::int8, :m - floor(power(random(), 3) * 60000)::int8 FROM generate_series(1, 300000) g ON CONFLICT DO NOTHING;
DELETE FROM favorites WHERE ctid = ANY (ARRAY(SELECT ctid FROM favorites WHERE article_id > :m - 60000 AND random() < 0.15));
INSERT INTO comments (article_id, author_id, body)
SELECT :m - floor(power(random(), 3) * 60000)::int8, 1 + floor(random() * 100000)::int8, 'c' || g FROM generate_series(1, 200000) g;
INSERT INTO follows (follower_id, followee_id)
SELECT s.f, au.a FROM (SELECT g, 1 + floor(random() * 100000)::int8 AS f, 1 + floor(random() * :na)::int AS ix FROM generate_series(1, 100000) g) s JOIN au ON au.i = s.ix ON CONFLICT DO NOTHING;
ANALYZE;
SELECT 'aged', count(*), max(id) FROM articles;
SQL
echo "aged done: $($P -At -d conduit_aged -c 'select count(*) from articles'), $($P -At -d postgres -c "select pg_size_pretty(pg_database_size('conduit_aged'))")"
