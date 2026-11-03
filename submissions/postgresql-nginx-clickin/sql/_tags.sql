-- The tag names of every article in ids(id), as JSON text (tg.tags), in one join for the whole batch. tags is
-- read once and hashed ("OFFSET 0" keeps it a subquery): looking each tag up in tags_pkey cost two buffers per
-- tag of every article.
SELECT at.article_id, json_agg(t.name ORDER BY t.name)::text AS tags
  FROM ids JOIN article_tags at ON at.article_id = ids.id JOIN (SELECT id, name FROM tags OFFSET 0) t ON t.id = at.tag_id
 GROUP BY at.article_id
