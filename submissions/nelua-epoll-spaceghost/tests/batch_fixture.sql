-- Reset only the explicitly disposable nc_batch_* database checked by batch_sql.py.
TRUNCATE public.users, public.follows, public.articles, public.tags,
         public.article_tags, public.favorites, public.comments RESTART IDENTITY CASCADE;

INSERT INTO public.users (id,username,email,password_hash,bio,image) VALUES
  (1,'reader','reader@example.invalid','fixture-unused',NULL,NULL),
  (2,'alice','alice@example.invalid','fixture-unused','author bio','https://example.invalid/雪.png'),
  (3,'bob','bob@example.invalid','fixture-unused','',NULL),
  (4,E'quo''te\\雪','quote@example.invalid','fixture-unused',NULL,'');

-- Include every PostgreSQL-permitted ASCII control byte, quotes, backslashes,
-- multibyte characters, and a combining mark in a real profile/article/comment.
UPDATE public.users SET bio = '"quoted" ' || chr(92) || ' 雪 😀 é ' ||
  (SELECT string_agg(chr(n),'' ORDER BY n) FROM generate_series(1,31) n) WHERE id=4;

INSERT INTO public.articles (id,slug,author_id,title,description,body,created_at,updated_at)
SELECT n,'article-'||n,CASE WHEN n<=1100 THEN 2 ELSE 3 END,
       'Title '||n,'Description '||n,'Body '||n,
       '2025-04-01 12:00:00.123999+00'::timestamptz+n*interval '1 second',
       '2025-04-02 12:00:00.987654+00'::timestamptz+n*interval '1 second'
  FROM generate_series(1,1105) n;
UPDATE public.articles SET title=(SELECT bio FROM public.users WHERE id=4),
  description='UTF-8: 雪 😀 é',
  body=repeat('"long" '||chr(92)||' 雪 😀 é ',500)||(SELECT bio FROM public.users WHERE id=4)
  WHERE id=1;
UPDATE public.articles SET created_at='1999-12-31 23:59:59.999999+00',
  updated_at='1970-01-01 00:00:00.001999+00' WHERE id=1104;

INSERT INTO public.tags (id,name) VALUES (1,'alpha'),(2,'secondary'),(3,'雪'),(4,'unused');
INSERT INTO public.tags (id,name) SELECT 5,bio FROM public.users WHERE id=4;
INSERT INTO public.article_tags (article_id,tag_id) SELECT id,1 FROM public.articles;
INSERT INTO public.article_tags (article_id,tag_id) SELECT id,2 FROM public.articles WHERE id<=50;
INSERT INTO public.article_tags (article_id,tag_id) VALUES (1,3),(1,5);
INSERT INTO public.favorites (user_id,article_id) SELECT 2,id FROM public.articles;
INSERT INTO public.favorites (user_id,article_id) VALUES (1,1),(1,1100);
INSERT INTO public.follows (follower_id,followee_id) VALUES (1,2),(1,3),(3,2),(4,2);

-- Ties force the secondary id DESC ordering; article-2 remains comment-free.
INSERT INTO public.comments (id,article_id,author_id,body,created_at,updated_at)
SELECT n,1,CASE WHEN n%2=0 THEN 2 ELSE 4 END,
       CASE WHEN n=137 THEN (SELECT bio FROM public.users WHERE id=4) ELSE 'Comment '||n END,
       '2025-05-01 00:00:00.123999+00'::timestamptz+(n/3)*interval '1 second',
       '2025-05-02 00:00:00.456789+00'::timestamptz
  FROM generate_series(1,137) n;

SELECT setval(pg_get_serial_sequence('public.users','id'),4,true);
SELECT setval(pg_get_serial_sequence('public.articles','id'),1105,true);
SELECT setval(pg_get_serial_sequence('public.tags','id'),5,true);
SELECT setval(pg_get_serial_sequence('public.comments','id'),137,true);
ANALYZE public.users;
ANALYZE public.articles;
ANALYZE public.article_tags;
ANALYZE public.favorites;
ANALYZE public.follows;
ANALYZE public.comments;
