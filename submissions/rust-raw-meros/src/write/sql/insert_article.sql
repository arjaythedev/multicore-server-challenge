-- POST /api/articles, step 1 of up to 4 in one group (the statements of one article stay adjacent, so currval()
-- below refers to this article). $1 slug base text, $2 author int8, $3 title text, $4 description text, $5 body text.
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, $1 || '-' || n.id, $2, $3, $4, $5
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
