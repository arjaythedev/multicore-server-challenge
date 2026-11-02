-- POST /api/articles, 5/6
INSERT INTO article_tags (article_id, tag_id)
SELECT :article_id::bigint, t.id FROM tags t WHERE t.name = ANY(:tag_list::text[])
