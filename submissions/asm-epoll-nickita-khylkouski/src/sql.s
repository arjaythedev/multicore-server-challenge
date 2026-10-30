# sql.s: the prepared statements (same SQL as the Rust reference, src/sql.rs) and their table.
# Statement i is prepared as "sNN" on every Postgres connection; sql_name(i) gives its name.
.include "defs.inc"
.include "app.inc"

# Article columns over `a` joined to `users u` (Rust article_cols!); BODY adds a.body.
.macro ARTICLE_COLS body
    .ascii "a.id, a.slug, a.title, a.description, "
    .ifnb \body
    .ascii "a.body, "
    .endif
    .ascii "a.created_at, a.updated_at,\n"
    .ascii " ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),\n"
    .ascii " (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),\n"
    .ascii " EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),\n"
    .ascii " u.username, u.bio, u.image,\n"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
.endm

# Statement table entry: SQL start label and end label.
.macro STMT start, end
    .quad \start, \end - \start
.endm

.section .rodata

q_list_all:
    .ascii "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,\n"
    .ascii " ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),\n"
    .ascii " fv.fc,\n fv.fav,\n u.username, u.bio, u.image,\n"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3) bounded ORDER BY bounded.id DESC LIMIT $2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC"
q_list_all_end:

q_list_tag:
    .ascii "WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,\n"
    .ascii " ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),\n"
    .ascii " fv.fc,\n fv.fav,\n u.username, u.bio, u.image,\n"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC"
q_list_tag_end:

q_list_author:
    .ascii "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) LIMIT 1000) s) SELECT c.n, "
    ARTICLE_COLS
    .ascii " FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
q_list_author_end:

q_list_favorited:
    .ascii "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,\n"
    .ascii " ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),\n"
    .ascii " (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),\n"
    .ascii " COALESCE(a.id = ANY(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = $1)), false),\n"
    .ascii " u.username, u.bio, u.image,\n"
    .ascii " COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)), false) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
q_list_favorited_end:

q_list_feed:
    .ascii "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s) SELECT c.n, "
    ARTICLE_COLS
    .ascii " FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
q_list_feed_end:

q_article_by_slug:
    .ascii "SELECT "
    ARTICLE_COLS body
    .ascii " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"
q_article_by_slug_end:

q_article_by_id:
    .ascii "SELECT "
    ARTICLE_COLS body
    .ascii " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2"
q_article_by_id_end:

q_profile:
    .ascii "SELECT u.username, u.bio, u.image,\n"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)\n"
    .ascii "FROM users u WHERE u.username = $2"
q_profile_end:

q_user_by_id:
    .ascii "SELECT id, username, email, bio, image FROM users WHERE id = $1"
q_user_by_id_end:

q_user_by_email:
    .ascii "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
q_user_by_email_end:

q_comments:
    .ascii "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,\n"
    .ascii " COALESCE(c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1), false)\n"
    .ascii "FROM articles a\n"
    .ascii "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id\n"
    .ascii "                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true\n"
    .ascii "LEFT JOIN users u ON u.id = c.author_id\n"
    .ascii "WHERE a.slug = $2\n"
    .ascii "ORDER BY c.created_at DESC, c.id DESC"
q_comments_end:

q_tags:
    .ascii "SELECT ARRAY(SELECT name FROM tags ORDER BY name)"
q_tags_end:

q_favorite:
    .ascii "WITH t AS (SELECT id FROM articles WHERE slug = $2),\n"
    .ascii " w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)\n"
    .ascii "SELECT id FROM t"
q_favorite_end:

q_unfavorite:
    .ascii "WITH t AS (SELECT id FROM articles WHERE slug = $2),\n"
    .ascii " w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t))\n"
    .ascii "SELECT id FROM t"
q_unfavorite_end:

q_article_create:
    .ascii "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),\n"
    .ascii " a AS (INSERT INTO articles (id, slug, author_id, title, description, body)\n"
    .ascii "       SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM n\n"
    .ascii "       RETURNING id, slug, title, description, body, created_at, updated_at, author_id),\n"
    .ascii " existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),\n"
    .ascii " t AS (INSERT INTO tags (name)\n"
    .ascii "       SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names\n"
    .ascii "       WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name)\n"
    .ascii "       ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),\n"
    .ascii " all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t),\n"
    .ascii " x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags)\n"
    .ascii "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,\n"
    .ascii " ARRAY(SELECT name FROM all_tags ORDER BY name), 0::bigint, false,\n"
    .ascii " u.username, u.bio, u.image,\n"
    .ascii " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)\n"
    .ascii "FROM a JOIN users u ON u.id = a.author_id"
q_article_create_end:

q_article_update:
    .ascii "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),\n"
    .ascii " w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),\n"
    .ascii "       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,\n"
    .ascii "       updated_at = now()\n"
    .ascii "       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1)\n"
    .ascii "SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t"
q_article_update_end:

q_article_delete:
    .ascii "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),\n"
    .ascii " w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))\n"
    .ascii "SELECT author_id FROM t"
q_article_delete_end:

q_comment_create:
    .ascii "WITH t AS (SELECT id FROM articles WHERE slug = $1),\n"
    .ascii " c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t\n"
    .ascii "       RETURNING id, body, created_at, updated_at, author_id)\n"
    .ascii "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"
q_comment_create_end:

q_comment_delete:
    .ascii "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id\n"
    .ascii "                WHERE c.id = $1 AND a.slug = $2),\n"
    .ascii " w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))\n"
    .ascii "SELECT author_id FROM t"
q_comment_delete_end:

q_follow:
    .ascii "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n"
    .ascii " w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)\n"
    .ascii "SELECT username, bio, image FROM t"
q_follow_end:

q_unfollow:
    .ascii "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),\n"
    .ascii " w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))\n"
    .ascii "SELECT username, bio, image FROM t"
q_unfollow_end:

q_user_insert:
    .ascii "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)\n"
    .ascii "RETURNING id, username, email, bio, image"
q_user_insert_end:

q_user_update:
    .ascii "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),\n"
    .ascii " password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)\n"
    .ascii "WHERE id = $1\n"
    .ascii "RETURNING id, username, email, bio, image"
q_user_update_end:

# Merged runs (writer.s): one statement for a run of consecutive same-type writes in a group commit. Param i is
# the array of the jobs' params i; each row is the row that job's own statement returns, with the job's 1-based
# ordinal in the run appended as a last int8 column. A favorite / follow repeated inside a run is inserted once.
q_favorite_n:
    .ascii "WITH r AS (SELECT x.k, x.uid, a.id FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k)\n"
    .ascii "           JOIN articles a ON a.slug = x.slug),\n"
    .ascii " w AS (INSERT INTO favorites (user_id, article_id) SELECT DISTINCT uid, id FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING)\n"
    .ascii "SELECT id, k FROM r"
q_favorite_n_end:

q_unfavorite_n:
    .ascii "WITH r AS (SELECT x.k, x.uid, a.id FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k)\n"
    .ascii "           JOIN articles a ON a.slug = x.slug),\n"
    .ascii " w AS (DELETE FROM favorites f USING r WHERE f.user_id = r.uid AND f.article_id = r.id)\n"
    .ascii "SELECT id, k FROM r"
q_unfavorite_n_end:

q_follow_n:
    .ascii "WITH r AS (SELECT x.k, x.fid, u.id, u.username, u.bio, u.image FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k)\n"
    .ascii "           JOIN users u ON u.username = x.uname),\n"
    .ascii " w AS (INSERT INTO follows (follower_id, followee_id) SELECT DISTINCT fid, id FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING)\n"
    .ascii "SELECT username, bio, image, k FROM r"
q_follow_n_end:

q_unfollow_n:
    .ascii "WITH r AS (SELECT x.k, x.fid, u.id, u.username, u.bio, u.image FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k)\n"
    .ascii "           JOIN users u ON u.username = x.uname),\n"
    .ascii " w AS (DELETE FROM follows fo USING r WHERE fo.follower_id = r.fid AND fo.followee_id = r.id)\n"
    .ascii "SELECT username, bio, image, k FROM r"
q_unfollow_n_end:

# Comment ids are drawn in ordinal order, so the run's comments are numbered as if inserted one by one.
q_comment_create_n:
    .ascii "WITH r AS (SELECT x.k, a.id AS aid, x.uid, x.body FROM unnest($1::text[], $2::int8[], $3::text[]) WITH ORDINALITY x(slug, uid, body, k)\n"
    .ascii "           JOIN articles a ON a.slug = x.slug),\n"
    .ascii " n AS (SELECT o.k, o.aid, o.uid, o.body, nextval(pg_get_serial_sequence('comments', 'id')) AS id FROM (SELECT * FROM r ORDER BY k) o),\n"
    .ascii " c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, aid, uid, body FROM n\n"
    .ascii "       RETURNING id, body, created_at, updated_at, author_id)\n"
    .ascii "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, n.k FROM c JOIN n ON n.id = c.id JOIN users u ON u.id = c.author_id"
q_comment_create_n_end:

q_session:
    .ascii "SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_memoize = off"
q_session_end:

# Statement table, indexed by S_* (app.inc order). Single-request forms first; the read families come first,
# in RK_* order, so S_<family> == RK_<family>.
.balign 8
.globl sql_table
sql_table:
    STMT q_list_all, q_list_all_end                 # 0  S_LIST_ALL
    STMT q_list_tag, q_list_tag_end                 # 1  S_LIST_TAG
    STMT q_list_author, q_list_author_end           # 2  S_LIST_AUTHOR
    STMT q_list_favorited, q_list_favorited_end     # 3  S_LIST_FAVORITED
    STMT q_list_feed, q_list_feed_end               # 4  S_LIST_FEED
    STMT q_article_by_slug, q_article_by_slug_end   # 5  S_ARTICLE_SLUG
    STMT q_article_by_id, q_article_by_id_end       # 6  S_ARTICLE_ID
    STMT q_profile, q_profile_end                   # 7  S_PROFILE
    STMT q_user_by_id, q_user_by_id_end             # 8  S_USER_ID
    STMT q_user_by_email, q_user_by_email_end       # 9  S_USER_EMAIL
    STMT q_comments, q_comments_end                 # 10 S_COMMENTS
    STMT q_tags, q_tags_end                         # 11 S_TAGS
    STMT q_favorite, q_favorite_end                 # 12 S_FAVORITE
    STMT q_unfavorite, q_unfavorite_end             # 13 S_UNFAVORITE
    STMT q_article_create, q_article_create_end     # 14 S_ARTICLE_CREATE
    STMT q_article_update, q_article_update_end     # 15 S_ARTICLE_UPDATE
    STMT q_article_delete, q_article_delete_end     # 16 S_ARTICLE_DELETE
    STMT q_comment_create, q_comment_create_end     # 17 S_COMMENT_CREATE
    STMT q_comment_delete, q_comment_delete_end     # 18 S_COMMENT_DELETE
    STMT q_follow, q_follow_end                     # 19 S_FOLLOW
    STMT q_unfollow, q_unfollow_end                 # 20 S_UNFOLLOW
    STMT q_user_insert, q_user_insert_end           # 21 S_USER_INSERT
    STMT q_user_update, q_user_update_end           # 22 S_USER_UPDATE
    STMT q_favorite_n, q_favorite_n_end             # 23 S_FAVORITE_N
    STMT q_unfavorite_n, q_unfavorite_n_end         # 24 S_UNFAVORITE_N
    STMT q_follow_n, q_follow_n_end                 # 25 S_FOLLOW_N
    STMT q_unfollow_n, q_unfollow_n_end             # 26 S_UNFOLLOW_N
    STMT q_comment_create_n, q_comment_create_n_end # 27 S_COMMENT_CREATE_N
sql_table_end:
.globl sql_count
.equ sql_count, (sql_table_end - sql_table) / 16

# Names "s00".."s99", 4 bytes each (NUL-terminated).
.globl sql_names
sql_names:
    .irp t, 0,1,2,3,4,5,6,7,8,9
    .irp u, 0,1,2,3,4,5,6,7,8,9
    .byte 's', '0' + \t, '0' + \u, 0
    .endr
    .endr

.section .rodata
DEFSTR .Lmsg_prep, "prepare failed for statement "


.text

# sql_prepare_all(fd) -> 0 | -1: session settings, then Parse every statement (blocking, at startup).
.globl sql_prepare_all
sql_prepare_all:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov edi, ebx
    lea rsi, [rip + q_session]
    mov edx, q_session_end - q_session
    call pg_exec_simple
    test rax, rax
    js .Lpa_fail
    xor r12d, r12d
.Lpa_loop:
    cmp r12d, sql_count
    jae .Lpa_ok
    lea r13, [rip + sql_table]
    mov rax, r12
    shl rax, 4
    add r13, rax
    mov edi, ebx
    lea rsi, [rip + sql_names]
    lea rsi, [rsi + r12*4]
    mov rdx, [r13]
    mov rcx, [r13 + 8]
    call pg_prepare
    test rax, rax
    js .Lpa_fail_stmt
    inc r12d
    jmp .Lpa_loop
.Lpa_ok:
    xor eax, eax
    jmp .Lpa_ret
.Lpa_fail_stmt:
    lea rdi, [rip + .Lmsg_prep]
    mov esi, .Lmsg_prep_len
    mov rdx, r12
    call rt_log_num
.Lpa_fail:
    mov rax, -1
.Lpa_ret:
    pop r13
    pop r12
    pop rbx
    ret

.section .note.GNU-stack,"",@progbits
