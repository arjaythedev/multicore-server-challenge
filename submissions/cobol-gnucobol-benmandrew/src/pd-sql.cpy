*> ================= sql: the prepared statements =================
*> Every statement the server runs, built once at start-up and registered in order, so statement n is prepared as
*> s<n>. The fragments that several statements share are built first.

BUILD-SQL.
    MOVE 0 TO SQ-COUNT SQ-USED
    MOVE "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id" TO SQ-PF
    MOVE 77 TO SQ-PF-LEN
    MOVE "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))" TO SQ-SLUG2
    MOVE 72 TO SQ-SLUG2-LEN

    *> full_select: every column of an article, the body included, with its author
    MOVE 1 TO SQ-TP
    STRING "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at," X"0A"
        "       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name" X"0A"
        "               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list," X"0A"
        "       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count," X"0A"
        "       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,"
        X"0A"
        "       u.username, u.bio, u.image," X"0A"
        "       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
        " AS following" X"0A"
        "  FROM articles a" X"0A"
        "  JOIN users u ON u.id = a.author_id"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    COMPUTE SQ-FULL-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-FULL-LEN) TO SQ-FULL

    *> fv_join
    MOVE 1 TO SQ-TP
    STRING X"0A" "  CROSS JOIN LATERAL (SELECT count(*) AS fc, bool_or(f.user_id = $1) AS fav FROM favorites f"
        " WHERE f.article_id = x.id) fv"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    COMPUTE SQ-FVJ-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-FVJ-LEN) TO SQ-FVJ

    *> page_cols, page_cols_fv (following_lookup as the following column), and the feed's columns (following is
    *> true)
    MOVE 0 TO SQ-FV
    MOVE "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = x.author_id)" TO SQ-FOL
    MOVE 92 TO SQ-FOL-LEN
    PERFORM SQ-PAGE-COLS
    COMPUTE SQ-PC-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-PC-LEN) TO SQ-PC
    MOVE 1 TO SQ-FV
    PERFORM SQ-PAGE-COLS
    COMPUTE SQ-PCFV-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-PCFV-LEN) TO SQ-PCFV
    MOVE 0 TO SQ-FV
    MOVE "true" TO SQ-FOL
    MOVE 4 TO SQ-FOL-LEN
    PERFORM SQ-PAGE-COLS
    COMPUTE SQ-PCT-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-PCT-LEN) TO SQ-PCT

    *> the counts of the filtered lists, with the filter as $4
    MOVE 1 TO SQ-TP
    STRING "SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t"
        " WHERE t.name = $4) OFFSET 999) THEN 1000 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id ="
        " (SELECT t.id FROM tags t WHERE t.name = $4)) END"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    COMPUTE SQ-TAGC-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-TAGC-LEN) TO SQ-TAGC
    MOVE 1 TO SQ-TP
    STRING "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u"
        " WHERE u.username = $4) LIMIT 1000) s"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    COMPUTE SQ-AUTHC-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-AUTHC-LEN) TO SQ-AUTHC
    MOVE 1 TO SQ-TP
    STRING "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu"
        " WHERE fu.username = $4) LIMIT 1000) s"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    COMPUTE SQ-FAVC-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-FAVC-LEN) TO SQ-FAVC
    MOVE 1 TO SQ-TP
    STRING "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM"
        " follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    COMPUTE SQ-FEEDC-LEN = SQ-TP - 1
    MOVE SQ-T (1:SQ-FEEDC-LEN) TO SQ-FEEDC

    *> s1 list_all
    MOVE 1 TO SQ-TP
    STRING "SELECT " SQ-PCFV (1:SQ-PCFV-LEN) "," X"0A"
        "       (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a ORDER BY a.id OFFSET 999) THEN 1000" X"0A"
        "                    ELSE (SELECT count(*) FROM articles a) END) AS total" X"0A"
        "  FROM (SELECT " SQ-PF (1:SQ-PF-LEN) " FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3) x" X"0A"
        "  JOIN users u ON u.id = x.author_id" SQ-FVJ (1:SQ-FVJ-LEN) X"0A"
        " ORDER BY x.id DESC"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s2 list_tag
    MOVE SQ-PCFV TO SQ-A1
    MOVE SQ-PCFV-LEN TO SQ-A1-LEN
    MOVE SQ-FVJ TO SQ-A2
    MOVE SQ-FVJ-LEN TO SQ-A2-LEN
    MOVE 1 TO SQ-TP
    STRING "SELECT " SQ-PF (1:SQ-PF-LEN) " FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id ="
        " (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p"
        " JOIN articles a ON a.id = p.article_id"
        DELIMITED BY SIZE INTO SQ-A3 WITH POINTER SQ-TP
    COMPUTE SQ-A3-LEN = SQ-TP - 1
    MOVE SQ-TAGC TO SQ-A4
    MOVE SQ-TAGC-LEN TO SQ-A4-LEN
    PERFORM SQ-FILTERED

    *> s3 list_author
    MOVE 1 TO SQ-TP
    STRING "SELECT " SQ-PF (1:SQ-PF-LEN) " FROM articles a WHERE a.author_id = (SELECT au.id FROM users au"
        " WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3"
        DELIMITED BY SIZE INTO SQ-A3 WITH POINTER SQ-TP
    COMPUTE SQ-A3-LEN = SQ-TP - 1
    MOVE SQ-AUTHC TO SQ-A4
    MOVE SQ-AUTHC-LEN TO SQ-A4-LEN
    PERFORM SQ-FILTERED

    *> s4 list_favorited
    MOVE SQ-PC TO SQ-A1
    MOVE SQ-PC-LEN TO SQ-A1-LEN
    MOVE 0 TO SQ-A2-LEN
    MOVE 1 TO SQ-TP
    STRING "SELECT " SQ-PF (1:SQ-PF-LEN) " FROM (SELECT f.article_id FROM favorites f WHERE f.user_id ="
        " (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p"
        " JOIN articles a ON a.id = p.article_id"
        DELIMITED BY SIZE INTO SQ-A3 WITH POINTER SQ-TP
    COMPUTE SQ-A3-LEN = SQ-TP - 1
    MOVE SQ-FAVC TO SQ-A4
    MOVE SQ-FAVC-LEN TO SQ-A4-LEN
    PERFORM SQ-FILTERED

    *> s5 list_feed
    MOVE SQ-PCT TO SQ-A1
    MOVE SQ-PCT-LEN TO SQ-A1-LEN
    MOVE 1 TO SQ-TP
    STRING "SELECT " SQ-PF (1:SQ-PF-LEN) " FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id"
        " FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x"
        " WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a ON a.id = p.id"
        DELIMITED BY SIZE INTO SQ-A3 WITH POINTER SQ-TP
    COMPUTE SQ-A3-LEN = SQ-TP - 1
    MOVE SQ-FEEDC TO SQ-A4
    MOVE SQ-FEEDC-LEN TO SQ-A4-LEN
    PERFORM SQ-FILTERED

    *> s6 count_all
    MOVE 1 TO SQ-TP
    STRING "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s7 to s9: count_of, the filter becomes $1; s10 count_feed
    MOVE SQ-TAGC TO SQ-T
    COMPUTE SQ-TP = SQ-TAGC-LEN + 1
    PERFORM SQ-SWAP-4
    PERFORM SQ-SAVE
    MOVE SQ-AUTHC TO SQ-T
    COMPUTE SQ-TP = SQ-AUTHC-LEN + 1
    PERFORM SQ-SWAP-4
    PERFORM SQ-SAVE
    MOVE SQ-FAVC TO SQ-T
    COMPUTE SQ-TP = SQ-FAVC-LEN + 1
    PERFORM SQ-SWAP-4
    PERFORM SQ-SAVE
    MOVE SQ-FEEDC TO SQ-T
    COMPUTE SQ-TP = SQ-FEEDC-LEN + 1
    PERFORM SQ-SAVE

    *> s11 article_by_slug, s12 article_by_id, s13 article_just_created
    MOVE 1 TO SQ-TP
    STRING SQ-FULL (1:SQ-FULL-LEN) " WHERE a.slug = $2" DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING SQ-FULL (1:SQ-FULL-LEN) " WHERE a.id = $2" DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING SQ-FULL (1:SQ-FULL-LEN) " WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s14 insert_article
    MOVE 1 TO SQ-TP
    STRING "INSERT INTO articles (id, slug, author_id, title, description, body)" X"0A"
        "SELECT n.id, " SQ-SLUG2 (1:SQ-SLUG2-LEN) " || '-' || n.id, $1, $2, $3, $4" X"0A"
        "  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n" X"0A"
        "RETURNING id"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s15 insert_tags, s16 insert_article_tags
    MOVE 1 TO SQ-TP
    STRING "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING "INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles',"
        " 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s17 article_owner
    MOVE 1 TO SQ-TP
    STRING "SELECT id, author_id FROM articles WHERE slug = $1" DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s18 update_article
    MOVE 1 TO SQ-TP
    STRING "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description),"
        " body = COALESCE($4, body)," X"0A"
        "       slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SQ-SLUG2 (1:SQ-SLUG2-LEN) " || '-' || id END,"
        X"0A"
        "       updated_at = now()" X"0A"
        " WHERE id = $1"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s19 delete_article
    MOVE 1 TO SQ-TP
    STRING "DELETE FROM articles WHERE id = $1" DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s20 favorite, s21 unfavorite
    MOVE 1 TO SQ-TP
    STRING "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2"
        " ON CONFLICT DO NOTHING"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a"
        " WHERE a.slug = $2)"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s22 comments
    MOVE 1 TO SQ-TP
    STRING "SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,"
        " c.following" X"0A"
        "  FROM articles a" X"0A"
        "  LEFT JOIN LATERAL (" X"0A"
        "       SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image," X"0A"
        "              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id ="
        " c.author_id) AS following" X"0A"
        "         FROM comments c JOIN users u ON u.id = c.author_id" X"0A"
        "        WHERE c.article_id = a.id" X"0A"
        "        ORDER BY c.created_at DESC, c.id DESC" X"0A"
        "        LIMIT 100) c ON true" X"0A"
        " WHERE a.slug = $2"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s23 insert_comment
    MOVE 1 TO SQ-TP
    STRING "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM articles a"
        " WHERE a.slug = $1" X"0A"
        "           RETURNING id, body, created_at, updated_at, author_id)" X"0A"
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image" X"0A"
        "  FROM c JOIN users u ON u.id = c.author_id"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s24 delete_comment
    MOVE 1 TO SQ-TP
    STRING "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id"
        " WHERE c.id = $1 AND a.slug = $2)," X"0A"
        "     d AS (DELETE FROM comments c USING t WHERE c.id = t.id AND t.author_id = $3)" X"0A"
        "SELECT author_id FROM t"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s25 insert_user, s26 user_by_email, s27 user_by_id
    MOVE 1 TO SQ-TP
    STRING "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)"
        " RETURNING id, username, email, bio, image"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING "SELECT id, username, email, bio, image FROM users WHERE id = $1"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s28 update_user
    MOVE 1 TO SQ-TP
    STRING "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username)," X"0A"
        "                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio),"
        " image = COALESCE($6, image)" X"0A"
        " WHERE id = $1" X"0A"
        "RETURNING id, username, email, bio, image"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s29 profile
    MOVE 1 TO SQ-TP
    STRING "SELECT u.id, u.username, u.bio, u.image," X"0A"
        "       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)"
        " AS following" X"0A"
        "  FROM users u WHERE u.username = $2"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s30 follow, s31 unfollow
    MOVE 1 TO SQ-TP
    STRING "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2)," X"0A"
        "     ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u"
        " ON CONFLICT DO NOTHING)" X"0A"
        "SELECT username, bio, image FROM u"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE
    MOVE 1 TO SQ-TP
    STRING "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2)," X"0A"
        "     del AS (DELETE FROM follows fo USING u WHERE fo.follower_id = $1 AND fo.followee_id = u.id)" X"0A"
        "SELECT username, bio, image FROM u"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE

    *> s32 tags
    MOVE 1 TO SQ-TP
    STRING "SELECT '{""tags"":' || coalesce(json_agg(name)::text, '[]') || '}' FROM (SELECT name FROM tags"
        " ORDER BY name) s"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE.

*> page_cols_with: the list columns from page subquery x. SQ-FV = 1 takes the favourites from fv_join; SQ-FOL
*> is the following expression. Result in SQ-T, up to SQ-TP.
SQ-PAGE-COLS.
    MOVE 1 TO SQ-TP
    STRING "x.id, x.slug, x.title, x.description, x.created_at, x.updated_at," X"0A"
        "       ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name" X"0A"
        "               FROM article_tags at WHERE at.article_id = x.id ORDER BY 1) AS tag_list," X"0A"
        "       "
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    IF SQ-FV = 1
        STRING "fv.fc AS favorites_count, coalesce(fv.fav, false) AS favorited,"
            DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    ELSE
        STRING "(SELECT count(*) FROM favorites f WHERE f.article_id = x.id) AS favorites_count," X"0A"
            "       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = x.id AND f.user_id = $1) AS favorited,"
            DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    END-IF
    STRING X"0A" "       u.username, u.bio, u.image," X"0A" "       " SQ-FOL (1:SQ-FOL-LEN) " AS following"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP.

*> filtered_list: SQ-A1 columns, SQ-A2 join (may be empty), SQ-A3 page query, SQ-A4 count query; saves it.
SQ-FILTERED.
    MOVE 1 TO SQ-TP
    STRING "WITH x AS MATERIALIZED (" SQ-A3 (1:SQ-A3-LEN) "), n AS (SELECT count(*)::int AS n FROM x)" X"0A"
        "SELECT " SQ-A1 (1:SQ-A1-LEN) "," X"0A"
        "       (CASE WHEN n.n > 0 AND n.n < $2 THEN least($3 + n.n, 1000)" X"0A"
        "             WHEN n.n = $2 AND $3 + $2 >= 1000 THEN 1000" X"0A"
        "             ELSE (" SQ-A4 (1:SQ-A4-LEN) ") END)::bigint AS total" X"0A"
        "  FROM x JOIN users u ON u.id = x.author_id CROSS JOIN n"
        DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    IF SQ-A2-LEN > 0
        STRING SQ-A2 (1:SQ-A2-LEN) DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    END-IF
    STRING X"0A" " ORDER BY x.id DESC" DELIMITED BY SIZE INTO SQ-T WITH POINTER SQ-TP
    PERFORM SQ-SAVE.

*> Every "$4" in SQ-T (1:SQ-TP - 1) becomes "$1" (count_of).
SQ-SWAP-4.
    COMPUTE SQ-TL = SQ-TP - 2
    PERFORM VARYING SQ-I FROM 1 BY 1 UNTIL SQ-I > SQ-TL
        IF SQ-T (SQ-I:2) = "$4"
            MOVE "$1" TO SQ-T (SQ-I:2)
        END-IF
    END-PERFORM.

*> Registers SQ-T (1:SQ-TP - 1) as the next statement: its name, read-only flag and Bind head.
SQ-SAVE.
    COMPUTE SQ-TL = SQ-TP - 1
    ADD 1 TO SQ-COUNT
    COMPUTE SQ-OFF (SQ-COUNT) = SQ-USED + 1
    MOVE SQ-TL TO SQ-LEN (SQ-COUNT)
    MOVE SQ-T (1:SQ-TL) TO SQ-AREA (SQ-OFF (SQ-COUNT):SQ-TL)
    ADD SQ-TL TO SQ-USED
    MOVE SQ-COUNT TO SQ-NUM
    IF SQ-COUNT < 10
        STRING "s" SQ-NUM (2:1) DELIMITED BY SIZE INTO SQ-NAME (SQ-COUNT)
        MOVE 2 TO SQ-NAME-LEN (SQ-COUNT)
    ELSE
        STRING "s" SQ-NUM DELIMITED BY SIZE INTO SQ-NAME (SQ-COUNT)
        MOVE 3 TO SQ-NAME-LEN (SQ-COUNT)
    END-IF
    *> read-only unless a word (a run of letters and '_') is INSERT, UPDATE or DELETE
    MOVE 1 TO SQ-RO (SQ-COUNT)
    MOVE 0 TO SQ-WLEN
    PERFORM VARYING SQ-I FROM 1 BY 1 UNTIL SQ-I > SQ-TL + 1
        IF SQ-I <= SQ-TL AND ((SQ-T (SQ-I:1) >= "A" AND SQ-T (SQ-I:1) <= "Z")
                OR (SQ-T (SQ-I:1) >= "a" AND SQ-T (SQ-I:1) <= "z") OR SQ-T (SQ-I:1) = "_")
            ADD 1 TO SQ-WLEN
            IF SQ-WLEN <= 16
                MOVE SQ-T (SQ-I:1) TO SQ-WORD (SQ-WLEN:1)
            END-IF
        ELSE
            IF SQ-WLEN = 6 AND (SQ-WORD (1:6) = "INSERT" OR SQ-WORD (1:6) = "UPDATE"
                    OR SQ-WORD (1:6) = "DELETE")
                MOVE 0 TO SQ-RO (SQ-COUNT)
            END-IF
            MOVE 0 TO SQ-WLEN
        END-IF
    END-PERFORM
    MOVE 0 TO SQ-K
    INSPECT SQ-T (1:SQ-TL) TALLYING SQ-K FOR ALL "::text[]"
    IF SQ-K > 0
        MOVE 1 TO SQ-ARR (SQ-COUNT)
    ELSE
        MOVE 0 TO SQ-ARR (SQ-COUNT)
    END-IF
    *> Bind head: empty portal, name, then the parameter format codes: one code, binary, for the text[] statements
    *> (their only parameter); none (all text) for the rest.
    MOVE 1 TO SQ-TP
    IF SQ-ARR (SQ-COUNT) = 1
        STRING X"00" SQ-NAME (SQ-COUNT) (1:SQ-NAME-LEN (SQ-COUNT)) X"00" X"00010001"
            DELIMITED BY SIZE INTO SQ-BH (SQ-COUNT) WITH POINTER SQ-TP
    ELSE
        STRING X"00" SQ-NAME (SQ-COUNT) (1:SQ-NAME-LEN (SQ-COUNT)) X"00" X"0000"
            DELIMITED BY SIZE INTO SQ-BH (SQ-COUNT) WITH POINTER SQ-TP
    END-IF
    COMPUTE SQ-BH-LEN (SQ-COUNT) = SQ-TP - 1.
