-- POST /api/articles, 3/6 (inside BEGIN): the slug is the title slugified, then "-<id>".
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, trim(both '-' from lower(regexp_replace(:title::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
       :viewer::bigint, :title::text, :description::text, :article_body::text
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id AS article_id
