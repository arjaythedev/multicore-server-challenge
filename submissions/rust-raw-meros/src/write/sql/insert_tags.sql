-- Step 2 (only when the article has tags). $1 tag names text[]. Sorted so concurrent groups lock in the same order.
INSERT INTO tags (name) SELECT x FROM unnest($1::text[]) AS x ORDER BY x
ON CONFLICT (name) DO NOTHING
