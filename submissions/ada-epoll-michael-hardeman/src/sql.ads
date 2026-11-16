--  Every prepared statement. A lookup followed by a write is folded into one data-modifying statement, so each
--  write is one pipelined group.
with Postgres; use Postgres;

package Sql is

   --  The title ($2) as a slug, before the article id is appended.
   Slugify     : constant String := "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";

   Insert_User : aliased constant Statement := Define
     ("insert_user",
      "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
      & "RETURNING id, username, email, bio, image",
      [Text_Oid, Text_Oid, Text_Oid]);

   Update_User : aliased constant Statement := Define
     ("update_user",
      "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
      & "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
      & "WHERE id = $1 RETURNING id, username, email, bio, image",
      [Int8_Oid, Text_Oid, Text_Oid, Text_Oid, Text_Oid, Text_Oid]);

   Follow : aliased constant Statement := Define
     ("follow",
      "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
      & "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) "
      & "SELECT username, bio, image FROM t",
      [Int8_Oid, Text_Oid]);

   Unfollow : aliased constant Statement := Define
     ("unfollow",
      "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
      & "w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) "
      & "SELECT username, bio, image FROM t",
      [Int8_Oid, Text_Oid]);

   Insert_Article : aliased constant Statement := Define
     ("insert_article",
      "INSERT INTO articles (id, slug, author_id, title, description, body) "
      & "SELECT n.id, " & Slugify & " || '-' || n.id, $1, $2, $3, $4 "
      & "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
      [Int8_Oid, Text_Oid, Text_Oid, Text_Oid]);

   Insert_Tags : aliased constant Statement := Define
     ("insert_tags",
      "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
      [1 => Text_Array_Oid]);

   Tag_Article : aliased constant Statement := Define
     ("tag_article",
      "INSERT INTO article_tags (article_id, tag_id) "
      & "SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
      [1 => Text_Array_Oid]);

   Update_Article : aliased constant Statement := Define
     ("update_article",
      "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), "
      & "w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
      & "body = COALESCE($4, body), "
      & "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " & Slugify & " || '-' || id END, updated_at = now() "
      & "WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1) "
      & "SELECT t.id, t.author_id FROM t",
      [Text_Oid, Text_Oid, Text_Oid, Text_Oid, Int8_Oid]);

   Delete_Article : aliased constant Statement := Define
     ("delete_article",
      "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), "
      & "w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) "
      & "SELECT author_id FROM t",
      [Text_Oid, Int8_Oid]);

   Favorite : aliased constant Statement := Define
     ("favorite",
      "WITH t AS (SELECT id FROM articles WHERE slug = $2), "
      & "w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) "
      & "SELECT id FROM t",
      [Int8_Oid, Text_Oid]);

   Unfavorite : aliased constant Statement := Define
     ("unfavorite",
      "WITH t AS (SELECT id FROM articles WHERE slug = $2), "
      & "w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) "
      & "SELECT id FROM t",
      [Int8_Oid, Text_Oid]);

   Insert_Comment : aliased constant Statement := Define
     ("insert_comment",
      "WITH t AS (SELECT id FROM articles WHERE slug = $1), "
      & "c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t "
      & "RETURNING id, body, created_at, updated_at, author_id) "
      & "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
      & "FROM c JOIN users u ON u.id = c.author_id",
      [Text_Oid, Int8_Oid, Text_Oid]);

   Delete_Comment : aliased constant Statement := Define
     ("delete_comment",
      "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
      & "WHERE c.id = $1 AND a.slug = $2), "
      & "w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) "
      & "SELECT author_id FROM t",
      [Int8_Oid, Text_Oid, Int8_Oid]);

   ---------------------------------------------------------------------------------------------------------------
   --  Batched reads (the planner). Each takes arrays of the distinct keys of one batch and tags every row with
   --  its key's 1-based ordinal k. Batch article rows are [k, id, author_id, slug, title, description,
   --  created_at, updated_at (, body)].

   Batch_Columns : constant String :=
     "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";
   --  NULLs after the count in a list statement's count rows, matching Batch_Columns after the id.
   Batch_Padding : constant String :=
     "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

   --  A count capped at 1,000.
   function Capped (Rows : String) return String is ("(SELECT count(*) FROM (" & Rows & " LIMIT 1000) s)");

   --  A capped count for keys that usually reach the cap: one skip of 999 entries settles those.
   function Capped_Large (Rows : String) return String is
     ("(CASE WHEN EXISTS (" & Rows & " OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM (" & Rows
      & ") s) END)");

   Batch_Tags : aliased constant Statement := Define
     ("batch_tags",
      "SELECT id::int8, name FROM tags ORDER BY name",
      []);

   Batch_Users : aliased constant Statement := Define
     ("batch_users",
      "SELECT r.k, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) "
      & "JOIN users u ON u.id = r.id",
      [1 => Int8_Array_Oid]);

   Batch_Logins : aliased constant Statement := Define
     ("batch_logins",
      "SELECT r.k, u.id, u.username, u.email, u.bio, u.image, u.password_hash "
      & "FROM unnest($1::text[]) WITH ORDINALITY r(email, k) JOIN users u ON u.email = r.email",
      [1 => Text_Array_Oid]);

   Batch_Profiles : aliased constant Statement := Define
     ("batch_profiles",
      "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) "
      & "JOIN users u ON u.username = r.username",
      [1 => Text_Array_Oid]);

   Batch_Articles_By_Slug : aliased constant Statement := Define
     ("batch_articles_by_slug",
      "SELECT r.k, " & Batch_Columns & ", a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) "
      & "JOIN articles a ON a.slug = r.slug",
      [1 => Text_Array_Oid]);

   Batch_Articles_By_Id : aliased constant Statement := Define
     ("batch_articles_by_id",
      "SELECT r.k, " & Batch_Columns & ", a.body FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) "
      & "JOIN articles a ON a.id = r.id",
      [1 => Int8_Array_Oid]);

   --  Comment threads: kind 0 rows [0, k, id, body, created_at, updated_at, author_id, -, -] newest first,
   --  kind 1 rows [1, user id, -, username, -, -, -, bio, image] for the threads' distinct authors, kind 2 rows
   --  [2, viewer, followee] for each thread author a signed-in viewer ($2, thread $3) follows.
   Batch_Comments : aliased constant Statement := Define
     ("batch_comments",
      "WITH t AS MATERIALIZED ("
      & "SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id "
      & "FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug "
      & "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
      & "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true) "
      & "SELECT 0::int8, t.k, t.id, t.body, t.created_at, t.updated_at, t.author_id, NULL::text, NULL::text "
      & "FROM t "
      & "UNION ALL "
      & "SELECT 1::int8, u.id, NULL::int8, u.username, NULL::timestamptz, NULL::timestamptz, NULL::int8, "
      & "u.bio, u.image FROM users u "
      & "WHERE u.id = ANY(ARRAY(SELECT DISTINCT t.author_id FROM t WHERE t.author_id IS NOT NULL ORDER BY 1)) "
      & "UNION ALL "
      & "SELECT 2::int8, p.v, fo.followee_id, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::int8, "
      & "NULL::text, NULL::text "
      & "FROM (SELECT t.k, array_agg(t.author_id) AS authors FROM t WHERE t.author_id IS NOT NULL GROUP BY t.k) ta "
      & "JOIN unnest($2::int8[], $3::int8[]) p(v, k) ON p.k = ta.k "
      & "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo "
      & "WHERE fo.follower_id = p.v AND fo.followee_id = ANY(ta.authors)) fo",
      [Text_Array_Oid, Int8_Array_Oid, Int8_Array_Oid]);

   --  List statements: count rows have k <= 0 (-k is the count key; 0 is the single global count) with the
   --  count in column 2, page rows have k > 0 in the batch article layout.
   Batch_Global : aliased constant Statement := Define
     ("batch_global",
      "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), "
      & Batch_Padding & " "
      & "UNION ALL "
      & "SELECT r.k, " & Batch_Columns & " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) "
      & "CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
      [Int8_Array_Oid, Int8_Array_Oid]);

   Batch_Tagged : aliased constant Statement := Define
     ("batch_tagged",
      "SELECT -r.k, " & Capped_Large ("SELECT 1 FROM article_tags at WHERE at.tag_id = t.id") & ", "
      & Batch_Padding & " FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag "
      & "UNION ALL "
      & "SELECT r.k, " & Batch_Columns & " "
      & "FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(tag, lim, off, k) "
      & "JOIN tags t ON t.name = r.tag "
      & "CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id "
      & "ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p "
      & "JOIN articles a ON a.id = p.article_id",
      [Text_Array_Oid, Text_Array_Oid, Int8_Array_Oid, Int8_Array_Oid]);

   Batch_Authored : aliased constant Statement := Define
     ("batch_authored",
      "SELECT -r.k, " & Capped ("SELECT 1 FROM articles a WHERE a.author_id = u.id") & ", " & Batch_Padding
      & " FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username "
      & "UNION ALL "
      & "SELECT r.k, " & Batch_Columns & " "
      & "FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) "
      & "JOIN users u ON u.username = r.username "
      & "CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id "
      & "ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
      [Text_Array_Oid, Text_Array_Oid, Int8_Array_Oid, Int8_Array_Oid]);

   Batch_Favorited : aliased constant Statement := Define
     ("batch_favorited",
      "SELECT -r.k, " & Capped ("SELECT 1 FROM favorites f WHERE f.user_id = u.id") & ", " & Batch_Padding
      & " FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username "
      & "UNION ALL "
      & "SELECT r.k, " & Batch_Columns & " "
      & "FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) "
      & "JOIN users u ON u.username = r.username "
      & "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id "
      & "ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p "
      & "JOIN articles a ON a.id = p.article_id",
      [Text_Array_Oid, Text_Array_Oid, Int8_Array_Oid, Int8_Array_Oid]);

   --  Personal feeds: capped counts per distinct viewer ($1, k <= 0) and pages per (viewer, limit, offset)
   --  (k > 0, [k, id, author_id] only; the other columns come from Batch_Article_Rows). Followees shared by
   --  several viewers ("hubs") are looked at once: whether they have 1,000+ articles, and the id of their
   --  depth-th newest article, a floor below which no page of that depth can reach.
   Batch_Feed : aliased constant Statement := Define
     ("batch_feed",
      "WITH u AS MATERIALIZED ("
      & "SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids, "
      & "r.depth FROM unnest($1::int8[], $5::int8[]) WITH ORDINALITY r(v, depth, k)), "
      & "hubs AS MATERIALIZED ("
      & "SELECT h.fid, "
      & "(SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) "
      & "AS floor_id, "
      & "EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET 999) AS big "
      & "FROM (SELECT f.fid, max(u.depth) AS depth FROM u, unnest(u.fids) f(fid) "
      & "GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 48) h), "
      & "big AS MATERIALIZED (SELECT ARRAY(SELECT fid FROM hubs WHERE big) AS fids) "
      & "SELECT -u.k, CASE WHEN u.fids && (SELECT fids FROM big) THEN 1000::int8 "
      & "ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(u.fids) LIMIT 1000) s) END, "
      & Batch_Padding & " FROM u "
      & "UNION ALL "
      & "SELECT p.k, x.id, x.fid, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz "
      & "FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(v, lim, off, k) "
      & "JOIN u ON u.v = p.v "
      & "CROSS JOIN LATERAL (SELECT COALESCE(max(h.floor_id), 0) AS floor_id FROM hubs h WHERE h.fid = ANY(u.fids)) fl "
      & "CROSS JOIN LATERAL (SELECT y.id, y.fid FROM unnest(u.fids) f(fid) CROSS JOIN LATERAL "
      & "(SELECT a2.id, f.fid FROM articles a2 WHERE a2.author_id = f.fid AND a2.id >= fl.floor_id "
      & "ORDER BY a2.id DESC LIMIT p.lim + p.off) y "
      & "ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x",
      [Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid]);

   --  Phase B. Article columns for articles phase A returned only ids for (feed pages), in the batch layout.
   Batch_Article_Rows : aliased constant Statement := Define
     ("batch_article_rows",
      "SELECT 0::int8, " & Batch_Columns & " FROM articles a WHERE a.id = ANY($1::int8[])",
      [1 => Int8_Array_Oid]);

   --  One row per distinct article ($1): [id, tag ids, favorites count, -, -, -], then one per distinct author
   --  ($2, which may repeat): [-id, -, -, username, bio, image].
   Batch_Article_Details : aliased constant Statement := Define
     ("batch_article_details",
      "SELECT r.id, ARRAY(SELECT at.tag_id::int8 FROM article_tags at WHERE at.article_id = r.id), "
      & "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), NULL::text, NULL::text, NULL::text "
      & "FROM unnest($1::int8[]) r(id) "
      & "UNION ALL "
      & "SELECT -u.id, NULL::int8[], NULL::int8, u.username, u.bio, u.image FROM users u "
      & "WHERE u.id = ANY($2::int8[])",
      [Int8_Array_Oid, Int8_Array_Oid]);

   --  Viewer flags: [0, viewer, article] per favorited pair asked about, [1, viewer, followee] per followed
   --  pair. Each viewer's targets are its slice first .. last of the flat, sorted target array.
   Batch_Flags : aliased constant Statement := Define
     ("batch_flags",
      "SELECT 0::int8, p.v, f.article_id FROM unnest($1::int8[], $3::int8[], $4::int8[]) p(v, s, e) "
      & "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f "
      & "WHERE f.user_id = p.v AND f.article_id = ANY(($2::int8[])[p.s::int : p.e::int])) f "
      & "UNION ALL "
      & "SELECT 1::int8, q.v, fo.followee_id FROM unnest($5::int8[], $7::int8[], $8::int8[]) q(v, s, e) "
      & "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo "
      & "WHERE fo.follower_id = q.v AND fo.followee_id = ANY(($6::int8[])[q.s::int : q.e::int])) fo",
      [Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid,
       Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid, Int8_Array_Oid]);

   type Statement_Access is access constant Statement;
   type Statement_List is array (Positive range <>) of Statement_Access;

   All_Statements : constant Statement_List :=
     [Insert_User'Access,
      Update_User'Access,
      Follow'Access,
      Unfollow'Access,
      Insert_Article'Access,
      Insert_Tags'Access,
      Tag_Article'Access,
      Update_Article'Access,
      Delete_Article'Access,
      Favorite'Access,
      Unfavorite'Access,
      Insert_Comment'Access,
      Delete_Comment'Access,
      Batch_Tags'Access,
      Batch_Users'Access,
      Batch_Logins'Access,
      Batch_Profiles'Access,
      Batch_Articles_By_Slug'Access,
      Batch_Articles_By_Id'Access,
      Batch_Comments'Access,
      Batch_Global'Access,
      Batch_Tagged'Access,
      Batch_Authored'Access,
      Batch_Favorited'Access,
      Batch_Feed'Access,
      Batch_Article_Rows'Access,
      Batch_Article_Details'Access,
      Batch_Flags'Access];

end Sql;
