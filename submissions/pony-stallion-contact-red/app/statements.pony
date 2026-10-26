type _RequestStatement is (
  _Tags | _RegisterUser | _LoginUser | _CurrentUser | _UpdateUser |
  _Profile | _FollowTarget | _FollowInsert | _FollowDelete |
  _ArticlePageAll | _ArticlePageFeed | _ArticlePageTag |
  _ArticlePageAuthor | _ArticlePageFavorited |
  _ArticleFullBySlug | _ArticleFullById |
  _ArticleInsert | _ArticleIdAndAuthorBySlug | _ArticleUpdateInput |
  _ArticleUpdate |
  _ArticleDelete |
  _ArticleIdBySlug | _FavoriteInsert | _FavoriteDelete |
  _CommentsBySlug | _CommentInput | _CommentInsert |
  _CommentOwner | _CommentDelete)

type _Statement is (_RequestStatement | _Rollback)

primitive _Tags
primitive _RegisterUser
primitive _LoginUser
primitive _CurrentUser
primitive _UpdateUser
primitive _Profile
primitive _FollowTarget
primitive _FollowInsert
primitive _FollowDelete
primitive _ArticlePageAll
primitive _ArticlePageFeed
primitive _ArticlePageTag
primitive _ArticlePageAuthor
primitive _ArticlePageFavorited
primitive _ArticleFullBySlug
primitive _ArticleFullById
primitive _ArticleInsert
primitive _ArticleIdAndAuthorBySlug
primitive _ArticleUpdateInput
primitive _ArticleUpdate
primitive _ArticleDelete
primitive _ArticleIdBySlug
primitive _FavoriteInsert
primitive _FavoriteDelete
primitive _CommentsBySlug
primitive _CommentInput
primitive _CommentInsert
primitive _CommentOwner
primitive _CommentDelete
primitive _Rollback

primitive _Catalog
  fun tag_scan_safe(statement: _RequestStatement,
    params: Array[_Param] val): Bool
  =>
    let shape: (USize, USize) = match statement
      | _CurrentUser => (1, 0)
      | _Profile | _ArticleFullBySlug | _CommentsBySlug => (1, 1)
      | _ArticleFullById => (2, 0)
      | _ArticlePageAll | _ArticlePageFeed => (3, 0)
      | _ArticlePageTag | _ArticlePageAuthor | _ArticlePageFavorited => (3, 1)
      else return false
      end
    if params.size() != (shape._1 + shape._2) then return false end
    var index: USize = 0
    for param in params.values() do
      if index < shape._1 then
        match param
        | let _: I64 => None
        else return false
        end
      else
        match param
        | let _: String => None
        else return false
        end
      end
      index = index + 1
    end
    true

  fun kind(statement: _RequestStatement): USize =>
    match statement
    | _Tags => 0
    | _RegisterUser => 1
    | _LoginUser => 2
    | _CurrentUser => 3
    | _UpdateUser => 4
    | _Profile => 5
    | _FollowTarget => 6
    | _FollowInsert => 7
    | _FollowDelete => 8
    | _ArticlePageAll => 9
    | _ArticlePageFeed => 10
    | _ArticlePageTag => 11
    | _ArticlePageAuthor => 12
    | _ArticlePageFavorited => 13
    | _ArticleFullBySlug => 14
    | _ArticleFullById => 15
    | _ArticleInsert => 16
    | _ArticleIdAndAuthorBySlug => 17
    | _ArticleUpdateInput => 18
    | _ArticleUpdate => 19
    | _ArticleDelete => 20
    | _ArticleIdBySlug => 21
    | _FavoriteInsert => 22
    | _FavoriteDelete => 23
    | _CommentsBySlug => 24
    | _CommentInput => 25
    | _CommentInsert => 26
    | _CommentOwner => 27
    | _CommentDelete => 28
    end

  fun all(): Array[_Statement] val =>
    recover val
      Array[_Statement]
        .>push(_Tags).>push(_RegisterUser).>push(_LoginUser)
        .>push(_CurrentUser).>push(_UpdateUser).>push(_Profile)
        .>push(_FollowTarget).>push(_FollowInsert).>push(_FollowDelete)
        .>push(_ArticlePageAll).>push(_ArticlePageFeed)
        .>push(_ArticlePageTag).>push(_ArticlePageAuthor)
        .>push(_ArticlePageFavorited)
        .>push(_ArticleFullBySlug).>push(_ArticleFullById)
        .>push(_ArticleInsert).>push(_ArticleIdAndAuthorBySlug)
        .>push(_ArticleUpdateInput).>push(_ArticleUpdate)
        .>push(_ArticleDelete)
        .>push(_ArticleIdBySlug).>push(_FavoriteInsert)
        .>push(_FavoriteDelete).>push(_CommentsBySlug)
        .>push(_CommentInput).>push(_CommentInsert).>push(_CommentOwner)
        .>push(_CommentDelete).>push(_Rollback)
    end

  fun name(statement: _Statement): String =>
    match statement
    | _Tags => "tags"
    | _RegisterUser => "register_user"
    | _LoginUser => "login_user"
    | _CurrentUser => "current_user"
    | _UpdateUser => "update_user"
    | _Profile => "profile"
    | _FollowTarget => "follow_target"
    | _FollowInsert => "follow_insert"
    | _FollowDelete => "follow_delete"
    | _ArticlePageAll => "article_page_all"
    | _ArticlePageFeed => "article_page_feed"
    | _ArticlePageTag => "article_page_tag"
    | _ArticlePageAuthor => "article_page_author"
    | _ArticlePageFavorited => "article_page_favorited"
    | _ArticleFullBySlug => "article_full_by_slug"
    | _ArticleFullById => "article_full_by_id"
    | _ArticleInsert => "article_insert"
    | _ArticleIdAndAuthorBySlug => "article_id_and_author_by_slug"
    | _ArticleUpdateInput => "article_update_input"
    | _ArticleUpdate => "article_update"
    | _ArticleDelete => "article_delete"
    | _ArticleIdBySlug => "article_id_by_slug"
    | _FavoriteInsert => "favorite_insert"
    | _FavoriteDelete => "favorite_delete"
    | _CommentsBySlug => "comments_by_slug"
    | _CommentInput => "comment_input"
    | _CommentInsert => "comment_insert"
    | _CommentOwner => "comment_owner"
    | _CommentDelete => "comment_delete"
    | _Rollback => "rollback"
    end

  fun sql(statement: _Statement): String =>
    match statement
    | _Tags =>
      "SELECT json_build_object('tags', COALESCE(" +
        "json_agg(name ORDER BY name), '[]'::json))::text FROM tags"
    | _RegisterUser =>
      """
      INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
      RETURNING id, username, email, bio, image
      """
    | _LoginUser =>
      """
      SELECT id, username, email, bio, image, password_hash
      FROM users WHERE email = $1
      """
    | _CurrentUser =>
      "SELECT id, username, email, bio, image FROM users WHERE id = $1"
    | _UpdateUser =>
      """
      UPDATE users SET email = COALESCE($2, email),
        username = COALESCE($3, username),
        password_hash = COALESCE($4, password_hash),
        bio = COALESCE($5, bio), image = COALESCE($6, image)
      WHERE id = $1 RETURNING id, username, email, bio, image
      """
    | _Profile =>
      """
      SELECT u.id, u.username, u.bio, u.image,
        EXISTS(SELECT 1 FROM follows fo
          WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
      FROM users u WHERE u.username = $2
      """
    | _FollowTarget =>
      "SELECT id, username, bio, image FROM users WHERE username = $1"
    | _FollowInsert =>
      "INSERT INTO follows (follower_id, followee_id) "
        + "VALUES ($1, $2) ON CONFLICT DO NOTHING"
    | _FollowDelete =>
      "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2"
    | _ArticlePageAll =>
      _SQL.article_list(_SQL.article_page(),
        "SELECT count(*) AS total FROM " +
        "(SELECT 1 FROM articles a LIMIT 1000) s")
    | _ArticlePageFeed =>
      _SQL.article_list(_SQL.article(false) + """
        WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
          (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
            ORDER BY a2.id DESC LIMIT ($2::bigint::int + $3::bigint::int)) x
          WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)
        ORDER BY a.id DESC
        """, """
      SELECT count(*) AS total FROM (SELECT 1 FROM articles a
        WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo
          WHERE fo.follower_id = $1) LIMIT 1000) s
      """)
    | _ArticlePageTag =>
      _SQL.article_list(_SQL.article(false) + """
        WHERE a.id IN (SELECT at.article_id FROM article_tags at
          WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
          ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)
        ORDER BY a.id DESC
        """, """
      SELECT count(*) AS total FROM (SELECT 1 FROM article_tags at
        WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
        LIMIT 1000) s
      """)
    | _ArticlePageAuthor =>
      _SQL.article_list(_SQL.article_page("WHERE a.author_id = " +
        "(SELECT au.id FROM users au WHERE au.username = $4)"),
        "SELECT count(*) AS total FROM (SELECT 1 FROM articles a " +
        "WHERE a.author_id = " +
        "(SELECT u.id FROM users u WHERE u.username = $4) " +
        "LIMIT 1000) s")
    | _ArticlePageFavorited =>
      _SQL.article_list(_SQL.article(false) + """
        WHERE a.id IN (SELECT f.article_id FROM favorites f
          WHERE f.user_id =
            (SELECT fu.id FROM users fu WHERE fu.username = $4)
          ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC
        """, """
      SELECT count(*) AS total FROM (SELECT 1 FROM favorites f
        WHERE f.user_id =
          (SELECT fu.id FROM users fu WHERE fu.username = $4)
        LIMIT 1000) s
      """)
    | _ArticleFullBySlug => _SQL.article(true) + " WHERE a.slug = $2"
    | _ArticleFullById => _SQL.article(true) + " WHERE a.id = $2"
    | _ArticleInsert => _SQL.insert_article()
    | _ArticleIdAndAuthorBySlug =>
      "SELECT id, author_id FROM articles WHERE slug = $1"
    | _ArticleUpdateInput => _SQL.article_update_input()
    | _ArticleUpdate => _SQL.update_article()
    | _ArticleDelete => "DELETE FROM articles WHERE id = $1"
    | _ArticleIdBySlug => "SELECT id FROM articles WHERE slug = $1"
    | _FavoriteInsert =>
      "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) "
        + "ON CONFLICT DO NOTHING"
    | _FavoriteDelete =>
      "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2"
    | _CommentsBySlug => _SQL.comments()
    | _CommentInput => _SQL.comment_input()
    | _CommentInsert => _SQL.insert_comment()
    | _CommentOwner =>
      """
      SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
      WHERE c.id = $1 AND a.slug = $2
      """
    | _CommentDelete => "DELETE FROM comments WHERE id = $1"
    | _Rollback => "ROLLBACK"
    end
