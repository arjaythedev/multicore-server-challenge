-- An article (a, its author u, its tag names tg.tags from _tags.sql) as JSON text in three parts, for the
-- *_batch.sql files. Everything that doesn't depend on who is asking is worked out once per article per batch;
-- each request then adds its own "favorited" and "following":
--   p1 [|| ',"body":' ...] || p2 || favorited || p3 || following || '}}'
'{"slug":' || to_json(a.slug)::text || ',"title":' || to_json(a.title)::text
  || ',"description":' || to_json(a.description)::text AS p1,
',"tagList":' || coalesce(tg.tags, '[]')
  || ',"createdAt":"' || to_char(a.created_at AT TIME ZONE 'UTC', {{_ts}})
  || '","updatedAt":"' || to_char(a.updated_at AT TIME ZONE 'UTC', {{_ts}}) || '","favorited":' AS p2,
',"favoritesCount":' || (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)
  || ',"author":{"username":' || to_json(u.username)::text || ',"bio":' || coalesce(to_json(u.bio)::text, 'null')
  || ',"image":' || coalesce(to_json(u.image)::text, 'null') || ',"following":' AS p3
