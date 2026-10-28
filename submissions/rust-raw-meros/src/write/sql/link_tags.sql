-- Step 3 (only when the article has tags). $1 tag names text[].
INSERT INTO article_tags (article_id, tag_id)
SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])
