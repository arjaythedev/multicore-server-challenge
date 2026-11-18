using Conduit.Dispatch;
using Conduit.Json;
using Conduit.Pg;

namespace Conduit.Api;

/// <summary>
/// The write kinds this build serves. Each is one statement that looks up and changes in a single step, so an
/// expected outcome (unknown slug, not the author, already following) comes back as a row or as no row and never as a
/// server error. A server error would abort the whole group commit, and every write in it would run again alone.
/// </summary>
public static class WriteOps {
    /// <summary>POST /api/users.</summary>
    public static readonly WriteOp Register = new RegisterOp();

    /// <summary>PUT /api/user.</summary>
    public static readonly WriteOp UpdateUser = new UpdateUserOp();

    /// <summary>POST /api/articles.</summary>
    public static readonly WriteOp CreateArticle = new CreateArticleOp();

    /// <summary>PUT /api/articles/:slug.</summary>
    public static readonly WriteOp UpdateArticle = new UpdateArticleOp();

    /// <summary>DELETE /api/articles/:slug.</summary>
    public static readonly WriteOp DeleteArticle = new StatusOp("w_delete_article", WriteSql.DeleteArticle, DeleteTarget.Article);

    /// <summary>POST /api/articles/:slug/favorite.</summary>
    public static readonly WriteOp Favorite = new ArticleChangeOp("w_favorite", WriteSql.Favorite);

    /// <summary>DELETE /api/articles/:slug/favorite.</summary>
    public static readonly WriteOp Unfavorite = new ArticleChangeOp("w_unfavorite", WriteSql.Unfavorite);

    /// <summary>POST /api/articles/:slug/comments.</summary>
    public static readonly WriteOp CreateComment = new CreateCommentOp();

    /// <summary>DELETE /api/articles/:slug/comments/:id.</summary>
    public static readonly WriteOp DeleteComment = new StatusOp("w_delete_comment", WriteSql.DeleteComment, DeleteTarget.Comment);

    /// <summary>POST /api/profiles/:username/follow.</summary>
    public static readonly WriteOp Follow = new FollowOp("w_follow", WriteSql.Follow);

    /// <summary>DELETE /api/profiles/:username/follow.</summary>
    public static readonly WriteOp Unfollow = new FollowOp("w_unfollow", WriteSql.Unfollow);

    /// <summary>Every kind, for preparing statements.</summary>
    public static IReadOnlyList<WriteOp> All { get; } =
        [Register, UpdateUser, CreateArticle, UpdateArticle, DeleteArticle, Favorite, Unfavorite, CreateComment, DeleteComment, Follow, Unfollow];

    /// <summary>Adds <paramref name="value"/> as text, or NULL when it is null. The statements turn NULL into "leave unchanged".</summary>
    private static void AddNullableText(PgParams p, string? value) {
        if (value is null) {
            p.AddNull();
        } else {
            p.AddText(value);
        }
    }

    /// <summary>
    /// Writes <c>{"user": {...}}</c> from the columns of <paramref name="row"/> at the given positions, with
    /// <paramref name="token"/> as the token.
    /// </summary>
    private static void WriteUser(JsonWriter w, in PgRow row, int username, int email, int bio, int image, ReadOnlySpan<byte> token) {
        w.StartObject();
        w.PropertyName("user"u8);
        w.StartObject();
        w.PropertyName("email"u8);
        w.WriteString(row[email]);
        w.PropertyName("token"u8);
        w.WriteString(token);
        w.PropertyName("username"u8);
        w.WriteString(row[username]);
        w.PropertyName("bio"u8);
        UserFamily.Nullable(w, row, bio);
        w.PropertyName("image"u8);
        UserFamily.Nullable(w, row, image);
        w.EndObject();
        w.EndObject();
    }

    /// <summary>POST /api/users: one row (id, username, email, bio, image), or none when the username or email is taken.</summary>
    private sealed class RegisterOp : WriteOp {
        /// <summary>The one statement.</summary>
        private static readonly WriteStatement[] Own = [new("w_register", WriteSql.Register, [PgOid.Text, PgOid.Text, PgOid.Text])];

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => Own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams p = sink.Add("w_register");
            p.AddText(job.Username!);
            p.AddText(job.Email!);
            p.AddText(job.PasswordHash!);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            WriteUser(job.Out.Body, row, username: 1, email: 2, bio: 3, image: 4, job.Signer!(PgBinary.ReadInt8(row[0])));
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) => job.Rows > 0 ? 201 : Error(job, 422, "username or email already taken");
    }

    /// <summary>PUT /api/user: one row (status, username, email, bio, image); none means the user does not exist.</summary>
    private sealed class UpdateUserOp : WriteOp {
        /// <summary>The one statement.</summary>
        private static readonly WriteStatement[] Own =
            [new("w_update_user", WriteSql.UpdateUser, [PgOid.Int8, PgOid.Text, PgOid.Text, PgOid.Text, PgOid.Text, PgOid.Text])];

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => Own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams p = sink.Add("w_update_user");
            p.AddInt8(job.Viewer);
            AddNullableText(p, job.Email);
            AddNullableText(p, job.Username);
            AddNullableText(p, job.PasswordHash);
            AddNullableText(p, job.Bio);
            AddNullableText(p, job.Image);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            job.Status = PgBinary.ReadInt4(row[0]);
            if (job.Status == 200) {
                WriteUser(job.Out.Body, row, username: 1, email: 2, bio: 3, image: 4, job.Token);
            }
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) {
            if (job.Rows == 0) {
                return Error(job, 401, "user not found");
            }

            return job.Status == 200 ? 200 : Error(job, 422, "username or email already taken");
        }
    }

    /// <summary>POST /api/articles: one statement writes the article and its tag links and returns the full article.</summary>
    private sealed class CreateArticleOp : WriteOp {
        /// <summary>The one statement.</summary>
        private static readonly WriteStatement[] Own =
            [new("w_create_article", WriteSql.CreateArticle, [PgOid.Int8, PgOid.Text, PgOid.Text, PgOid.Text, PgOid.TextArray])];

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => Own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            // The tag names themselves are inserted once per transaction by WriteBatch, in sorted order, before this runs.
            PgParams p = sink.Add("w_create_article");
            p.AddInt8(job.Viewer);
            p.AddText(job.Title!);
            p.AddText(job.Description!);
            p.AddText(job.Body!);
            p.AddTextArray(job.Tags);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            JsonWriter w = job.Out.Body;
            w.StartObject();
            w.PropertyName("article"u8);
            ArticleJson.WriteArticle(w, row, 0, withBody: true);
            w.EndObject();
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) => job.Rows > 0 ? 201 : Error(job, 500, "internal error");
    }

    /// <summary>PUT /api/articles/:slug: one row (status, full article columns); none means no such slug.</summary>
    private sealed class UpdateArticleOp : WriteOp {
        /// <summary>The one statement.</summary>
        private static readonly WriteStatement[] Own =
            [new("w_update_article", WriteSql.UpdateArticle, [PgOid.Int8, PgOid.Text, PgOid.Text, PgOid.Text, PgOid.Text])];

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => Own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams p = sink.Add("w_update_article");
            p.AddInt8(job.Viewer);
            p.AddText(job.Slug!);
            AddNullableText(p, job.Title);
            AddNullableText(p, job.Description);
            AddNullableText(p, job.Body);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            job.Status = PgBinary.ReadInt4(row[0]);
            if (job.Status != 200) {
                return;
            }

            JsonWriter w = job.Out.Body;
            w.StartObject();
            w.PropertyName("article"u8);
            ArticleJson.WriteArticle(w, row, 1, withBody: true);
            w.EndObject();
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) {
            if (job.Rows == 0) {
                return Error(job, 404, "article not found");
            }

            return job.Status switch {
                200 => 200,
                403 => Error(job, 403, "only the author can change this article"),
                _ => Error(job, 404, "article not found"),
            };
        }
    }

    /// <summary>What a delete removes, which fixes its statement's parameters.</summary>
    private enum DeleteTarget {
        /// <summary>An article: (viewer, slug).</summary>
        Article,
        /// <summary>A comment: (comment id, slug, viewer).</summary>
        Comment,
    }

    /// <summary>Deletes: one statement returns a status column (204, 403 or 404); no row means the target does not exist.</summary>
    private sealed class StatusOp : WriteOp {
        /// <summary>Prepared statement name.</summary>
        private readonly string _name;
        /// <summary>The one statement.</summary>
        private readonly WriteStatement[] _own;
        /// <summary>What the statement deletes, which picks the parameter order.</summary>
        private readonly DeleteTarget _target;

        /// <summary>Creates a delete op named <paramref name="name"/> for the statement <paramref name="sql"/>, which deletes a <paramref name="target"/>.</summary>
        public StatusOp(string name, string sql, DeleteTarget target) {
            _name = name;
            _target = target;
            _own = [new(name, sql, target == DeleteTarget.Article ? [PgOid.Int8, PgOid.Text] : [PgOid.Int8, PgOid.Text, PgOid.Int8])];
        }

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => _own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams p = sink.Add(_name);
            if (_target == DeleteTarget.Article) {
                p.AddInt8(job.Viewer);
                p.AddText(job.Slug!);
            } else {
                p.AddInt8(job.CommentId);
                p.AddText(job.Slug!);
                p.AddInt8(job.Viewer);
            }
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            job.Status = PgBinary.ReadInt4(row[0]);
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) {
            if (job.Rows == 0) {
                return Error(job, 404, "not found");
            }

            return job.Status switch {
                204 => 204,
                403 => Error(job, 403, "only the author can delete this"),
                _ => Error(job, 404, "not found"),
            };
        }
    }

    /// <summary>Favorite and unfavorite: one statement changes the row and returns the full article as it is afterwards, so the response needs no second read.</summary>
    private sealed class ArticleChangeOp : WriteOp {
        /// <summary>Prepared statement name.</summary>
        private readonly string _name;
        /// <summary>The one statement.</summary>
        private readonly WriteStatement[] _own;

        /// <summary>Creates the op named <paramref name="name"/> for the statement <paramref name="sql"/>.</summary>
        public ArticleChangeOp(string name, string sql) {
            _name = name;
            _own = [new(name, sql, [PgOid.Int8, PgOid.Text])];
        }

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => _own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams change = sink.Add(_name);
            change.AddInt8(job.Viewer);
            change.AddText(job.Slug!);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            JsonWriter w = job.Out.Body;
            w.StartObject();
            w.PropertyName("article"u8);
            ArticleJson.WriteArticle(w, row, 1, withBody: true);
            w.EndObject();
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) => job.Rows > 0 ? 200 : Error(job, 404, "article not found");
    }

    /// <summary>POST comments: the article lookup and insert are one statement; no row means no such article.</summary>
    private sealed class CreateCommentOp : WriteOp {
        /// <summary>The one statement.</summary>
        private static readonly WriteStatement[] Own =
            [new("w_create_comment", WriteSql.CreateComment, [PgOid.Int8, PgOid.Text, PgOid.Text])];

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => Own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams p = sink.Add("w_create_comment");
            p.AddInt8(job.Viewer);
            p.AddText(job.Slug!);
            p.AddText(job.Body!);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            JsonWriter w = job.Out.Body;
            w.StartObject();
            w.PropertyName("comment"u8);
            w.StartObject();
            w.PropertyName("id"u8);
            w.WriteLong(PgBinary.ReadInt8(row[0]));
            w.PropertyName("createdAt"u8);
            w.WriteTimestamp(PgBinary.ReadTimestamptz(row[2]));
            w.PropertyName("updatedAt"u8);
            w.WriteTimestamp(PgBinary.ReadTimestamptz(row[3]));
            w.PropertyName("body"u8);
            w.WriteString(row[1]);
            w.PropertyName("author"u8);
            w.StartObject();
            w.PropertyName("username"u8);
            w.WriteString(row[4]);
            w.PropertyName("bio"u8);
            UserFamily.Nullable(w, row, 5);
            w.PropertyName("image"u8);
            UserFamily.Nullable(w, row, 6);
            w.PropertyName("following"u8);
            w.WriteBool(false);  // SPEC.md: a new comment's author is shown with following false
            w.EndObject();
            w.EndObject();
            w.EndObject();
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) => job.Rows > 0 ? 201 : Error(job, 404, "article not found");
    }

    /// <summary>Follow and unfollow: one statement changes the row and returns the profile with the viewer's new flag.</summary>
    private sealed class FollowOp : WriteOp {
        /// <summary>Prepared statement name.</summary>
        private readonly string _name;
        /// <summary>The one statement.</summary>
        private readonly WriteStatement[] _own;

        /// <summary>Creates the op named <paramref name="name"/> for the statement <paramref name="sql"/>.</summary>
        public FollowOp(string name, string sql) {
            _name = name;
            _own = [new(name, sql, [PgOid.Int8, PgOid.Text])];
        }

        /// <inheritdoc />
        public override IReadOnlyList<WriteStatement> Statements => _own;

        /// <inheritdoc />
        public override void Encode(WriteJob job, IStatementSink sink) {
            PgParams change = sink.Add(_name);
            change.AddInt8(job.Viewer);
            change.AddText(job.Username!);
        }

        /// <inheritdoc />
        public override void OnRow(WriteJob job, int statement, in PgRow row) {
            if (job.Rows++ > 0) {
                return;
            }

            JsonWriter w = job.Out.Body;
            w.StartObject();
            w.PropertyName("profile"u8);
            ArticleJson.WriteProfile(w, row, 0, 3);
            w.EndObject();
        }

        /// <inheritdoc />
        public override int Complete(WriteJob job) => job.Rows > 0 ? 200 : Error(job, 404, "profile not found");
    }
}

/// <summary>The SQL of the write kinds. Placeholders follow the parameter order of each kind's Encode.</summary>
internal static class WriteSql {
    /// <summary>The SQL expression for SPEC.md SLUGIFY(x), where <paramref name="x"/> is a SQL expression.</summary>
    private static string Slugify(string x) => "trim(both '-' from lower(regexp_replace(" + x + ", '[^A-Za-z0-9]+', '-', 'g')))";

    /// <summary>Probe: does the viewer ($1) follow the author of article a.</summary>
    private const string ViewerFollowsAuthor =
        "(SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL";

    /// <summary>$1 username, $2 email, $3 password hash. A taken username or email inserts nothing, which the app reports as 422.</summary>
    public const string Register =
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) " +
        "ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image";

    /// <summary>
    /// $1 user id, $2 email, $3 username, $4 password hash, $5 bio, $6 image; NULL leaves a column unchanged.
    /// The guard keeps a clash with another user out of the UPDATE, so the common case raises no error. Status 422 marks a clash.
    /// A race with a concurrent change can still raise 23505, which aborts the group; the rerun maps it to 422.
    /// </summary>
    public const string UpdateUser =
        "WITH me AS (SELECT u.id FROM users u WHERE u.id = $1), " +
        "clash AS (SELECT 1 FROM users o WHERE o.id <> $1 AND (o.email = $2 OR o.username = $3) LIMIT 1), " +
        "upd AS (UPDATE users x SET email = COALESCE($2, x.email), username = COALESCE($3, x.username), " +
        "password_hash = COALESCE($4, x.password_hash), bio = COALESCE($5, x.bio), image = COALESCE($6, x.image) " +
        "FROM me WHERE x.id = me.id AND NOT EXISTS (SELECT 1 FROM clash) " +
        "RETURNING x.id, x.username, x.email, x.bio, x.image) " +
        "SELECT CASE WHEN upd.id IS NULL THEN 422 ELSE 200 END, upd.username, upd.email, upd.bio, upd.image " +
        "FROM me LEFT JOIN upd ON upd.id = me.id";

    /// <summary>
    /// $1 author id, $2 title, $3 description, $4 body, $5 tag names. The id comes from the sequence and goes into the slug
    /// (SPEC.md). Tags exist already (one shared insert per transaction); this links them and returns the full article,
    /// reading the tag names from the tags table so their order is the database's.
    /// </summary>
    public static readonly string CreateArticle =
        "WITH n AS MATERIALIZED (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id, clock_timestamp() AS t), " +
        "a AS (INSERT INTO articles (id, slug, author_id, title, description, body, created_at, updated_at) " +
        "SELECT n.id, " + Slugify("$2") + " || '-' || n.id, $1, $2, $3, $4, n.t, n.t FROM n " +
        "RETURNING id, slug, title, description, body, created_at, updated_at, author_id), " +
        "ins AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, tg.id FROM a CROSS JOIN tags tg " +
        "WHERE tg.name = ANY($5::text[]) RETURNING article_id) " +
        "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " +
        "ARRAY(SELECT tg.name FROM tags tg WHERE tg.name = ANY($5::text[]) ORDER BY tg.name) AS tag_list, " +
        "0::int8 AS favorites_count, false AS favorited, u.username, u.bio, u.image, " + ViewerFollowsAuthor + " AS following " +
        "FROM a JOIN users u ON u.id = a.author_id";

    /// <summary>
    /// $1 viewer, $2 slug, $3 title, $4 description, $5 body; NULL leaves a column unchanged. The first column is a status:
    /// 403 when the viewer is not the author, 404 when the row vanished, else 200 with the full article from RETURNING.
    /// No row at all means no article has the slug.
    /// </summary>
    public static readonly string UpdateArticle =
        "WITH cur AS (SELECT c.id, c.author_id, clock_timestamp() AS t FROM articles c WHERE c.slug = $2), " +
        "upd AS (UPDATE articles x SET title = COALESCE($3, x.title), description = COALESCE($4, x.description), " +
        "body = COALESCE($5, x.body), " +
        "slug = CASE WHEN $3::text IS NULL THEN x.slug ELSE " + Slugify("$3") + " || '-' || x.id END, updated_at = cur.t " +
        "FROM cur WHERE x.id = cur.id AND cur.author_id = $1 " +
        "RETURNING x.id, x.slug, x.title, x.description, x.body, x.created_at, x.updated_at, x.author_id) " +
        "SELECT CASE WHEN cur.author_id <> $1 THEN 403 WHEN a.id IS NULL THEN 404 ELSE 200 END, " +
        "a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " +
        ArticleSql.Tail(ViewerFollowsAuthor, "$1") + " " +
        "FROM cur LEFT JOIN upd a ON a.id = cur.id LEFT JOIN users u ON u.id = a.author_id";

    /// <summary>$1 viewer, $2 slug. One status column: 204 deleted, 403 not the author, 404 gone. No row: no such slug.</summary>
    public const string DeleteArticle =
        "WITH a AS (SELECT s.id, s.author_id FROM articles s WHERE s.slug = $2), " +
        "d AS (DELETE FROM articles y USING a WHERE y.id = a.id AND a.author_id = $1 RETURNING y.id) " +
        "SELECT CASE WHEN a.author_id <> $1 THEN 403 WHEN d.id IS NULL THEN 404 ELSE 204 END " +
        "FROM a LEFT JOIN d ON d.id = a.id";

    /// <summary>
    /// $1 viewer, $2 slug. Already favorited inserts nothing and raises nothing. Returns the full article (a status column,
    /// then the read layout); no row means no article has the slug.
    /// </summary>
    public static readonly string Favorite = ChangeFavorite(
        "w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM a ON CONFLICT DO NOTHING RETURNING 1)", "+", "true");

    /// <summary>$1 viewer, $2 slug. Like <see cref="Favorite"/>, for removing the viewer's favorite.</summary>
    public static readonly string Unfavorite = ChangeFavorite(
        "w AS (DELETE FROM favorites f USING a WHERE f.article_id = a.id AND f.user_id = $1 RETURNING 1)", "-", "false");

    /// <summary>
    /// Builds the favorite or unfavorite statement. <paramref name="change"/> is the CTE w that makes the change. The main
    /// SELECT sees the snapshot from before it, so the count adds (<paramref name="sign"/> "+") or removes ("-") the rows w
    /// changed, and the viewer's own flag, <paramref name="favorited"/>, is known.
    /// </summary>
    private static string ChangeFavorite(string change, string sign, string favorited) =>
        "WITH a AS (SELECT s.id, s.slug, s.title, s.description, s.body, s.created_at, s.updated_at, s.author_id " +
        "FROM articles s WHERE s.slug = $2), " + change + " " +
        "SELECT 0::int8, a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " + ArticleSql.TagNames + ", " +
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) " + sign + " (SELECT count(*) FROM w) AS favorites_count, " +
        favorited + " AS favorited, u.username, u.bio, u.image, " + ViewerFollowsAuthor + " AS following " +
        "FROM a JOIN users u ON u.id = a.author_id";

    /// <summary>$1 viewer, $2 slug, $3 body. The comment is inserted from the slug lookup; no row means no article. Both timestamps are one clock reading.</summary>
    public const string CreateComment =
        "WITH a AS (SELECT s.id, clock_timestamp() AS t FROM articles s WHERE s.slug = $2), " +
        "c AS (INSERT INTO comments (article_id, author_id, body, created_at, updated_at) SELECT a.id, $1, $3, a.t, a.t FROM a " +
        "RETURNING id, body, created_at, updated_at, author_id) " +
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id";

    /// <summary>$1 comment id, $2 slug, $3 viewer. One status column: 204, 403 or 404. No row: no such comment on that article.</summary>
    public const string DeleteComment =
        "WITH c AS (SELECT c1.id, c1.author_id FROM comments c1 JOIN articles a ON a.id = c1.article_id " +
        "WHERE c1.id = $1 AND a.slug = $2), " +
        "d AS (DELETE FROM comments x USING c WHERE x.id = c.id AND c.author_id = $3 RETURNING x.id) " +
        "SELECT CASE WHEN c.author_id <> $3 THEN 403 WHEN d.id IS NULL THEN 404 ELSE 204 END " +
        "FROM c LEFT JOIN d ON d.id = c.id";

    /// <summary>
    /// $1 viewer, $2 username. Returns the profile (username, bio, image, following), with following true whether this
    /// statement inserted the row or it existed already. No row means no such user.
    /// </summary>
    public const string Follow =
        "WITH u AS (SELECT x.id, x.username, x.bio, x.image FROM users x WHERE x.username = $2), " +
        "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING) " +
        "SELECT u.username, u.bio, u.image, true FROM u";

    /// <summary>$1 viewer, $2 username. Like <see cref="Follow"/>; afterwards the viewer does not follow the user.</summary>
    public const string Unfollow =
        "WITH u AS (SELECT x.id, x.username, x.bio, x.image FROM users x WHERE x.username = $2), " +
        "w AS (DELETE FROM follows fo USING u WHERE fo.followee_id = u.id AND fo.follower_id = $1) " +
        "SELECT u.username, u.bio, u.image, false FROM u";
}
