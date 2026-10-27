#!/usr/bin/env bash
# feed count-proof potential on the seed: heavy authors (>= 1000 articles) and how many viewers follow one
psql -X -d conduit_seed <<SQL
\timing on
SELECT count(*) AS authors_ge1000, max(n) FROM (SELECT author_id, count(*) n FROM articles GROUP BY 1) x WHERE n >= 1000;
SELECT width_bucket(n, ARRAY[1,10,50,100,200,500,1000]) b, count(*), min(n), max(n) FROM (SELECT author_id, count(*) n FROM articles GROUP BY 1) x GROUP BY 1 ORDER BY 1;
WITH h AS (SELECT author_id FROM articles GROUP BY 1 HAVING count(*) >= 1000),
     v AS (SELECT DISTINCT follower_id FROM follows)
SELECT (SELECT count(*) FROM v) viewers,
       (SELECT count(DISTINCT f.follower_id) FROM follows f JOIN h ON h.author_id = f.followee_id) follow_heavy;
WITH c AS (SELECT followee_id, count(*) n FROM follows GROUP BY 1)
SELECT percentile_disc(ARRAY[0.5,0.9,0.99,1.0]) WITHIN GROUP (ORDER BY n) followers_pctl FROM c;
-- viewers whose followees have >= 1000 articles in all, and how many need >= 5 followees to prove it via top-5
WITH fa AS (SELECT f.follower_id v, a.author_id, count(*) n FROM follows f JOIN articles a ON a.author_id = f.followee_id GROUP BY 1, 2),
     t AS (SELECT v, sum(n) tot, max(n) mx FROM fa GROUP BY 1)
SELECT count(*) viewers, count(*) FILTER (WHERE tot >= 1000) capped, count(*) FILTER (WHERE mx >= 1000) one_heavy,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY mx) median_max_followee_articles FROM t;
SQL
