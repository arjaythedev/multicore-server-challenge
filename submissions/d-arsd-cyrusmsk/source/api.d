/// The 19 Conduit endpoints (SPEC.md).
///
/// Every handler reads its rows from Postgres while it is being served: no
/// response caches, no query caches, no in-memory table copies, no remembered
/// verifications. Responses are asdf-serialized `model` values handed to
/// arsd.cgi in one write; request bodies are asdf-deserialized into `model`
/// structs.
module conduit.api;

import arsd.cgi : Cgi;
import arsd.postgres;

import conduit.auth;
import conduit.bcrypt;
import conduit.db;
import conduit.model;

import asdf : deserialize, serializeToJson;

import std.array : appender;
import std.conv : to;
import std.stdio : stderr;
import std.typecons : Nullable;

/// The top-level request entry point. Any escaped throwable that has not yet
/// produced a response becomes a 500; one that already wrote is rethrown so
/// arsd aborts the connection.
void handle(Cgi cgi)
{
    try
        route(cgi);
    catch (Throwable t)
    {
        stderr.writeln("conduit: ", cgi.requestMethod, " ", cgi.pathInfo, ": ", t.msg);
        if (cgi.canOutputHeaders())
            replyError(cgi, 500, "internal error");
        else
            throw t;
    }
}

// ---------------------------------------------------------------------------
// response building

private void reply(Cgi cgi, int status, const(char)[] body)
{
    cgi.setResponseStatus(status);
    cgi.setResponseContentType("application/json");
    cgi.write(body, true);
}

/// Serializes `value` with asdf and writes it as the response body.
private void replyJson(T)(Cgi cgi, int status, auto ref T value)
{
    reply(cgi, status, serializeToJson(value));
}

private void replyError(Cgi cgi, int status, string message)
{
    replyJson(cgi, status, ErrorDto(ErrorBodyDto([message])));
}

private void replyNoContent(Cgi cgi)
{
    cgi.setResponseStatus(204);
    cgi.write("", true);
}

// ---------------------------------------------------------------------------
// rows to JSON

/// The cell's text, or null only when the column is SQL NULL.
///
/// A zero-length `text` value comes back from libpq as an empty slice, and
/// arsd's `copyCString` turns that into a null D string; `isNull` is the only
/// reliable NULL test, so an empty-but-present value is normalized to "".
private string cell(Row row, size_t column)
{
    auto datum = row[column];
    if (datum.isNull)
        return null;
    auto text = datum.toString();
    return text is null ? emptyString() : text;
}

/// A non-null zero-length string. The `""` literal (and `idup` of an empty
/// slice) may carry a null pointer, which would be mistaken for SQL NULL.
private string emptyString()
{
    static char[1] sentinel;
    return cast(string) sentinel[0 .. 0];
}

/// The cell's text for a nullable column that was tagged by the SQL in
/// `db.d`: NULL is stored as the two-byte marker "0x01 N", an empty string as
/// "0x01 V" (nothing after), and any other value as "0x01 V" + value. libpq
/// cannot otherwise tell a NULL and a zero-length string apart.
private string cellNullable(Row row, size_t column)
{
    auto text = cell(row, column);
    if (text.length >= 2 && text[0] == '\x01')
    {
        if (text[1] == 'N')
            return null;
        if (text[1] == 'V')
            return text[2 .. $];
    }
    return text;
}

private long cellLong(Row row, size_t column)
{
    return to!long(cell(row, column));
}

private bool cellBool(Row row, size_t column)
{
    auto s = row[column].toString();
    return s.length != 0 && s[0] == 't';
}

/// A user row: id, username, email, bio, image.
private UserDto userDto(Row row, string token)
{
    return UserDto(cell(row, 1), cell(row, 2), cellNullable(row, 3), cellNullable(row, 4), token);
}

/// The author profile inside an article or comment row, given the column of
/// its username (bio, image and following immediately follow).
private ProfileDto profileDto(Row row, size_t base)
{
    return ProfileDto(cell(row, base), cellNullable(row, base + 1),
        cellNullable(row, base + 2), cellBool(row, base + 3));
}

/// The `tag_list` column is a JSON array (SPEC.md's `json_agg`); asdf turns it
/// into a `string[]` so the response serializer emits it unchanged.
private string[] tagsFrom(string text)
{
    if (text is null || text.length < 2)
        return null;
    return text.deserialize!(string[]);
}

/// An article-list row (no body):
/// 0 id, 1 slug, 2 title, 3 description, 4 created, 5 updated, 6 tag list,
/// 7 favorites count, 8 favorited, 9 username, 10 bio, 11 image, 12 following.
private ArticleSummaryDto listArticleDto(Row row)
{
    return ArticleSummaryDto(
        cell(row, 1), cell(row, 2), cell(row, 3), tagsFrom(cell(row, 6)),
        cell(row, 4), cell(row, 5), cellBool(row, 8), cellLong(row, 7),
        profileDto(row, 9));
}

/// A full-article row (with body): the same as the list row with `body` at 4
/// and everything after shifted by one.
private ArticleDto fullArticleDto(Row row)
{
    return ArticleDto(
        cell(row, 1), cell(row, 2), cell(row, 3), cell(row, 4), tagsFrom(cell(row, 7)),
        cell(row, 5), cell(row, 6), cellBool(row, 9), cellLong(row, 8),
        profileDto(row, 10));
}

/// A comment row: 0 id, 1 body, 2 created, 3 updated, 4 username, 5 bio,
/// 6 image, 7 following.
private CommentDto commentDto(Row row, bool following)
{
    return CommentDto(cellLong(row, 0), cell(row, 2), cell(row, 3), cell(row, 1),
        ProfileDto(cell(row, 4), cellNullable(row, 5), cellNullable(row, 6), following));
}

// ---------------------------------------------------------------------------
// auth

private struct Viewer
{
    long id;
    string token;
    bool present;
}

private Viewer viewerOf(Cgi cgi)
{
    if (auto header = "authorization" in cgi.requestHeaders)
    {
        if ((*header).length <= 6 || (*header)[0 .. 6] != "Token ")
            return Viewer(0, null, true);
        auto token = (*header)[6 .. $].idup;
        long id;
        if (!verifyToken(token, id))
            return Viewer(0, null, true);
        return Viewer(id, token, true);
    }
    return Viewer(0, null, false);
}

/// A missing or invalid token is a 401.
private bool requireAuth(Cgi cgi, out long viewer, out string token)
{
    auto auth = viewerOf(cgi);
    viewer = auth.id;
    token = auth.token;
    if (!auth.present || auth.id == 0)
    {
        replyError(cgi, 401, "unauthorized");
        return false;
    }
    return true;
}

/// No header means anonymous; a present but invalid token is a 401.
private bool optionalAuth(Cgi cgi, out long viewer)
{
    auto auth = viewerOf(cgi);
    viewer = auth.id;
    if (auth.present && auth.id == 0)
    {
        replyError(cgi, 401, "unauthorized");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// request bodies

/// Deserializes a request body into `T` (an `{"user": {...}}`-style wrapper), or
/// writes a 422. A malformed body, a missing/extra wrapper, a member of the
/// wrong type, and a missing required member are all 422.
private bool parseBody(T)(Cgi cgi, out T value)
{
    try
        value = deserialize!T(cgi.postBody);
    catch (Exception)
    {
        replyError(cgi, 422, "invalid body");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// pages, ids, paths

/// `limit` (default 20, 1..100) and `offset` (default 0, >= 0), or 422.
private bool pageArgs(Cgi cgi, out long limit, out long offset)
{
    limit = 20;
    offset = 0;
    if (auto value = "limit" in cgi.get)
    {
        if (!parseDigits(*value, limit) || limit < 1 || limit > 100)
        {
            replyError(cgi, 422, "limit must be an integer 1..100");
            return false;
        }
    }
    if (auto value = "offset" in cgi.get)
    {
        if (!parseDigits(*value, offset) || offset < 0)
        {
            replyError(cgi, 422, "offset must be an integer >= 0");
            return false;
        }
    }
    return true;
}

/// ASCII digits only, no sign, no spaces, fitting in a long. Leading zeros are
/// fine; a value that overflows is not.
private bool parseDigits(const(char)[] s, out long value) pure nothrow @safe
{
    value = 0;
    if (s.length == 0 || s.length > 18)
        return false;
    long parsed;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        parsed = parsed * 10 + (c - '0');
    }
    value = parsed;
    return true;
}

/// Percent-decodes a path segment. Slugs and usernames with reserved characters
/// arrive encoded; plain ASCII is returned unchanged.
private string urlDecode(const(char)[] s)
{
    auto out_ = appender!(char[])();
    size_t i = 0;
    while (i < s.length)
    {
        if (s[i] == '%' && i + 2 < s.length && hexValue(s[i + 1]) >= 0 && hexValue(s[i + 2]) >= 0)
        {
            out_.put(cast(char)(hexValue(s[i + 1]) * 16 + hexValue(s[i + 2])));
            i += 3;
        }
        else
        {
            out_.put(s[i]);
            i++;
        }
    }
    return out_.data.idup;
}

private int hexValue(char c) pure nothrow @safe
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/// The article's id by slug, or 404.
private bool articleId(Cgi cgi, string slug, out long id)
{
    Variant[] args;
    args ~= vstr(slug);
    auto rs = dbConn().queryImpl(articleIdBySlug, args);
    if (rs.empty)
    {
        replyError(cgi, 404, "article not found");
        return false;
    }
    id = cellLong(rs.front, 0);
    return true;
}

/// The article by slug, or 404; the article's author, or 403.
private bool ownArticle(Cgi cgi, string slug, long viewer, out long id)
{
    Variant[] args;
    args ~= vstr(slug);
    auto rs = dbConn().queryImpl(articleOwner, args);
    if (rs.empty)
    {
        replyError(cgi, 404, "article not found");
        return false;
    }
    if (cellLong(rs.front, 1) != viewer)
    {
        replyError(cgi, 403, "not the author");
        return false;
    }
    id = cellLong(rs.front, 0);
    return true;
}

/// Builds `{"articles":[...],"articlesCount":N}`.
private void replyArticleList(Cgi cgi, ResultSet rows, long total)
{
    ArticleSummaryDto[] articles;
    while (!rows.empty)
    {
        articles ~= listArticleDto(rows.front);
        rows.popFront();
    }
    replyJson(cgi, 200, ArticleListDto(articles, total));
}

// ---------------------------------------------------------------------------
// users and auth

/// POST /api/users
private void register(Cgi cgi)
{
    RegisterDto body;
    if (!parseBody(cgi, body))
        return;
    auto username = body.user.username;
    auto email = body.user.email;
    auto password = body.user.password;
    if (username.length == 0)
    {
        replyError(cgi, 422, "username must be a non-empty string");
        return;
    }
    if (email.length == 0)
    {
        replyError(cgi, 422, "email must be a non-empty string");
        return;
    }
    if (password.length == 0)
    {
        replyError(cgi, 422, "password must be a non-empty string");
        return;
    }

    auto hash = hashPassword(password);
    if (hash is null)
    {
        replyError(cgi, 422, "password is too long");
        return;
    }

    Variant[] args;
    args ~= vstr(username);
    args ~= vstr(email);
    args ~= vstr(hash);
    ResultSet rs;
    try
        rs = dbConn().queryImpl(insertUser, args);
    catch (DatabaseException e)
    {
        if (isDuplicate(e))
        {
            replyError(cgi, 422, "username or email is already taken");
            return;
        }
        throw e;
    }
    if (rs.empty)
    {
        replyError(cgi, 422, "username or email is already taken");
        return;
    }

    auto row = rs.front;
    auto token = issueToken(cellLong(row, 0), nowUnix());
    replyJson(cgi, 201, UserWrapper(userDto(row, token)));
}

/// POST /api/users/login
private void login(Cgi cgi)
{
    LoginDto body;
    if (!parseBody(cgi, body))
        return;
    auto email = body.user.email;
    auto password = body.user.password;
    if (email.length == 0)
    {
        replyError(cgi, 422, "email must be a non-empty string");
        return;
    }
    if (password.length == 0)
    {
        replyError(cgi, 422, "password must be a non-empty string");
        return;
    }

    Variant[] args;
    args ~= vstr(email);
    auto rs = dbConn().queryImpl(userByEmail, args);
    if (rs.empty || !verifyPassword(password, cell(rs.front, 5)))
    {
        replyError(cgi, 401, "invalid email or password");
        return;
    }
    auto row = rs.front;
    auto token = issueToken(cellLong(row, 0), nowUnix());
    replyJson(cgi, 200, UserWrapper(userDto(row, token)));
}

/// GET /api/user
private void currentUser(Cgi cgi)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;

    Variant[] args;
    args ~= vlong(viewer);
    auto rs = dbConn().queryImpl(userById, args);
    if (rs.empty)
    {
        replyError(cgi, 401, "unauthorized");
        return;
    }
    replyJson(cgi, 200, UserWrapper(userDto(rs.front, token)));
}

/// PUT /api/user
private void updateUser(Cgi cgi)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;
    UserUpdateWrapper body;
    if (!parseBody(cgi, body))
        return;
    auto u = body.user;

    if (!u.email.isNull && u.email.get.length == 0)
    {
        replyError(cgi, 422, "email must be a non-empty string");
        return;
    }
    if (!u.username.isNull && u.username.get.length == 0)
    {
        replyError(cgi, 422, "username must be a non-empty string");
        return;
    }
    if (!u.password.isNull && u.password.get.length == 0)
    {
        replyError(cgi, 422, "password must be a non-empty string");
        return;
    }

    string hash;
    bool hasHash;
    if (!u.password.isNull)
    {
        hash = hashPassword(u.password.get);
        if (hash is null)
        {
            replyError(cgi, 422, "password is too long");
            return;
        }
        hasHash = true;
    }

    Variant[] args;
    args ~= vlong(viewer);
    args ~= u.email.isNull ? vnull() : vstr(u.email.get);
    args ~= u.username.isNull ? vnull() : vstr(u.username.get);
    args ~= hasHash ? vstr(hash) : vnull();
    args ~= u.bio.isNull ? vnull() : vstr(u.bio.get);
    args ~= u.image.isNull ? vnull() : vstr(u.image.get);
    ResultSet rs;
    try
        rs = dbConn().queryImpl(updateUserSql, args);
    catch (DatabaseException e)
    {
        if (isDuplicate(e))
        {
            replyError(cgi, 422, "username or email is already taken");
            return;
        }
        throw e;
    }
    if (rs.empty)
    {
        replyError(cgi, 401, "unauthorized");
        return;
    }
    replyJson(cgi, 200, UserWrapper(userDto(rs.front, token)));
}

// ---------------------------------------------------------------------------
// profiles

/// GET /api/profiles/:username
private void getProfile(Cgi cgi, string username)
{
    long viewer;
    if (!optionalAuth(cgi, viewer))
        return;

    Variant[] args;
    args ~= vlong(viewer);
    args ~= vstr(username);
    auto rs = dbConn().queryImpl(profile, args);
    if (rs.empty)
    {
        replyError(cgi, 404, "profile not found");
        return;
    }
    replyJson(cgi, 200, ProfileWrapper(profileDto(rs.front, 1)));
}

/// POST and DELETE /api/profiles/:username/follow
private void follow(Cgi cgi, string username, bool doFollow)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;

    Variant[] lookup;
    lookup ~= vstr(username);
    auto rs = dbConn().queryImpl(userByUsername, lookup);
    if (rs.empty)
    {
        replyError(cgi, 404, "profile not found");
        return;
    }
    auto row = rs.front;
    immutable followee = cellLong(row, 0);
    immutable name = cell(row, 1);
    immutable bio = cellNullable(row, 2);
    immutable image = cellNullable(row, 3);

    Variant[] change;
    change ~= vlong(viewer);
    change ~= vlong(followee);
    dbConn().queryImpl(doFollow ? insertFollow : deleteFollow, change);

    replyJson(cgi, 200, ProfileWrapper(ProfileDto(name, bio, image, doFollow)));
}

// ---------------------------------------------------------------------------
// articles

private enum ListKind
{
    all,
    tag,
    author,
    favorited,
}

/// GET /api/articles. With more than one filter, the first non-empty one in the
/// order tag, author, favorited applies.
private void listArticles(Cgi cgi)
{
    long viewer;
    if (!optionalAuth(cgi, viewer))
        return;
    long limit, offset;
    if (!pageArgs(cgi, limit, offset))
        return;

    ListKind kind = ListKind.all;
    string filter;
    if (auto value = "tag" in cgi.get)
    {
        filter = (*value).idup;
        kind = ListKind.tag;
    }
    if (!filter.length)
    {
        if (auto value = "author" in cgi.get)
        {
            filter = (*value).idup;
            kind = ListKind.author;
        }
    }
    if (!filter.length)
    {
        if (auto value = "favorited" in cgi.get)
        {
            filter = (*value).idup;
            kind = ListKind.favorited;
        }
    }
    if (!filter.length)
        kind = ListKind.all;

    string pageSql;
    string countSql;
    Variant[] pageArgs_;
    Variant[] countArgs;
    final switch (kind)
    {
    case ListKind.all:
        pageSql = listAll;
        pageArgs_ ~= vlong(viewer);
        pageArgs_ ~= vlong(limit);
        pageArgs_ ~= vlong(offset);
        countSql = countAll;
        break;
    case ListKind.tag:
        pageSql = listByTag;
        pageArgs_ ~= vlong(viewer);
        pageArgs_ ~= vlong(limit);
        pageArgs_ ~= vlong(offset);
        pageArgs_ ~= vstr(filter);
        countSql = countByTag;
        countArgs ~= vstr(filter);
        break;
    case ListKind.author:
        pageSql = listByAuthor;
        pageArgs_ ~= vlong(viewer);
        pageArgs_ ~= vlong(limit);
        pageArgs_ ~= vlong(offset);
        pageArgs_ ~= vstr(filter);
        countSql = countByAuthor;
        countArgs ~= vstr(filter);
        break;
    case ListKind.favorited:
        pageSql = listByFavorite;
        pageArgs_ ~= vlong(viewer);
        pageArgs_ ~= vlong(limit);
        pageArgs_ ~= vlong(offset);
        pageArgs_ ~= vstr(filter);
        countSql = countByFavorite;
        countArgs ~= vstr(filter);
        break;
    }

    auto conn = dbConn();
    auto rows = conn.queryImpl(pageSql, pageArgs_);
    auto total = conn.queryImpl(countSql, countArgs);
    replyArticleList(cgi, rows, cellLong(total.front, 0));
}

/// GET /api/articles/feed
private void feed(Cgi cgi)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;
    long limit, offset;
    if (!pageArgs(cgi, limit, offset))
        return;

    Variant[] args;
    args ~= vlong(viewer);
    args ~= vlong(limit);
    args ~= vlong(offset);
    auto conn = dbConn();
    auto rows = conn.queryImpl(listFeed, args);
    auto total = conn.queryImpl(countFeed, args);
    replyArticleList(cgi, rows, cellLong(total.front, 0));
}

/// GET /api/articles/:slug
private void getArticle(Cgi cgi, string slug)
{
    long viewer;
    if (!optionalAuth(cgi, viewer))
        return;

    Variant[] args;
    args ~= vlong(viewer);
    args ~= vstr(slug);
    auto rs = dbConn().queryImpl(articleBySlug, args);
    if (rs.empty)
    {
        replyError(cgi, 404, "article not found");
        return;
    }
    replyJson(cgi, 200, ArticleWrapper(fullArticleDto(rs.front)));
}

/// POST /api/articles
private void createArticle(Cgi cgi)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;
    ArticleCreateWrapper body_;
    if (!parseBody(cgi, body_))
        return;
    auto title = body_.article.title;
    auto description = body_.article.description;
    auto body = body_.article.body;
    if (title.length == 0)
    {
        replyError(cgi, 422, "title must be a non-empty string");
        return;
    }
    if (description.length == 0)
    {
        replyError(cgi, 422, "description must be a non-empty string");
        return;
    }
    if (body.length == 0)
    {
        replyError(cgi, 422, "body must be a non-empty string");
        return;
    }
    auto tags = body_.article.tagList;
    foreach (tag; tags)
    {
        if (tag.length == 0)
        {
            replyError(cgi, 422, "tagList must be an array of non-empty strings");
            return;
        }
    }

    auto conn = dbConn();
    conn.startTransaction();
    bool committed = false;
    scope(exit)
        if (!committed)
            rollbackQuietly(conn);

    Variant[] insert;
    insert ~= vlong(viewer);
    insert ~= vstr(title);
    insert ~= vstr(description);
    insert ~= vstr(body);
    auto created = conn.queryImpl(insertArticle, insert);
    if (created.empty)
    {
        replyError(cgi, 500, "internal error");
        return;
    }
    immutable id = cellLong(created.front, 0);

    if (tags.length)
    {
        auto array = pgTextArray(tags);
        Variant[] names;
        names ~= vstr(array);
        conn.queryImpl(insertTags, names);
        Variant[] links;
        links ~= vlong(id);
        links ~= vstr(array);
        conn.queryImpl(insertArticleTags, links);
    }
    conn.queryImpl("COMMIT");
    committed = true;

    Variant[] full;
    full ~= vlong(viewer);
    full ~= vlong(id);
    auto answer = conn.queryImpl(articleById, full);
    replyJson(cgi, 201, ArticleWrapper(fullArticleDto(answer.front)));
}

/// PUT /api/articles/:slug
private void updateArticle(Cgi cgi, string slug)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;
    ArticleUpdateWrapper body_;
    if (!parseBody(cgi, body_))
        return;
    auto a = body_.article;
    if (!a.title.isNull && a.title.get.length == 0)
    {
        replyError(cgi, 422, "title must be a non-empty string");
        return;
    }
    if (!a.description.isNull && a.description.get.length == 0)
    {
        replyError(cgi, 422, "description must be a non-empty string");
        return;
    }
    if (!a.body.isNull && a.body.get.length == 0)
    {
        replyError(cgi, 422, "body must be a non-empty string");
        return;
    }

    long id;
    if (!ownArticle(cgi, slug, viewer, id))
        return;

    Variant[] args;
    args ~= vlong(id);
    args ~= a.title.isNull ? vnull() : vstr(a.title.get);
    args ~= a.description.isNull ? vnull() : vstr(a.description.get);
    args ~= a.body.isNull ? vnull() : vstr(a.body.get);
    dbConn().queryImpl(updateArticleSql, args);

    Variant[] full;
    full ~= vlong(viewer);
    full ~= vlong(id);
    auto answer = dbConn().queryImpl(articleById, full);
    replyJson(cgi, 200, ArticleWrapper(fullArticleDto(answer.front)));
}

/// DELETE /api/articles/:slug
private void deleteArticle(Cgi cgi, string slug)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;

    long id;
    if (!ownArticle(cgi, slug, viewer, id))
        return;
    Variant[] args;
    args ~= vlong(id);
    dbConn().queryImpl(deleteArticleSql, args);
    replyNoContent(cgi);
}

// ---------------------------------------------------------------------------
// favorites

/// POST and DELETE /api/articles/:slug/favorite
private void favorite(Cgi cgi, string slug, bool doFavorite)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;

    long id;
    if (!articleId(cgi, slug, id))
        return;

    Variant[] change;
    change ~= vlong(viewer);
    change ~= vlong(id);
    auto conn = dbConn();
    conn.queryImpl(doFavorite ? insertFavorite : deleteFavorite, change);

    Variant[] full;
    full ~= vlong(viewer);
    full ~= vlong(id);
    auto answer = conn.queryImpl(articleById, full);
    replyJson(cgi, 200, ArticleWrapper(fullArticleDto(answer.front)));
}

// ---------------------------------------------------------------------------
// comments

/// GET /api/articles/:slug/comments
private void listComments(Cgi cgi, string slug)
{
    long viewer;
    if (!optionalAuth(cgi, viewer))
        return;

    long id;
    if (!articleId(cgi, slug, id))
        return;

    Variant[] args;
    args ~= vlong(viewer);
    args ~= vlong(id);
    auto rows = dbConn().queryImpl(commentsByArticle, args);

    CommentDto[] comments;
    while (!rows.empty)
    {
        auto row = rows.front;
        comments ~= commentDto(row, cellBool(row, 7));
        rows.popFront();
    }
    replyJson(cgi, 200, CommentListDto(comments));
}

/// POST /api/articles/:slug/comments
private void createComment(Cgi cgi, string slug)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;
    CommentCreateWrapper body_;
    if (!parseBody(cgi, body_))
        return;
    auto body = body_.comment.body;
    if (body.length == 0)
    {
        replyError(cgi, 422, "body must be a non-empty string");
        return;
    }

    long id;
    if (!articleId(cgi, slug, id))
        return;

    Variant[] args;
    args ~= vlong(id);
    args ~= vlong(viewer);
    args ~= vstr(body);
    auto answer = dbConn().queryImpl(insertComment, args);
    if (answer.empty)
    {
        replyError(cgi, 500, "internal error");
        return;
    }
    replyJson(cgi, 201, CommentWrapper(commentDto(answer.front, false)));
}

/// DELETE /api/articles/:slug/comments/:id. A non-integer id is a 404.
private void deleteComment(Cgi cgi, string slug, string rawId)
{
    long viewer;
    string token;
    if (!requireAuth(cgi, viewer, token))
        return;

    long commentId;
    if (!parseDigits(rawId, commentId))
    {
        replyError(cgi, 404, "comment not found");
        return;
    }

    Variant[] lookup;
    lookup ~= vlong(commentId);
    lookup ~= vstr(slug);
    auto conn = dbConn();
    auto rs = conn.queryImpl(commentOwner, lookup);
    if (rs.empty)
    {
        replyError(cgi, 404, "comment not found");
        return;
    }
    if (cellLong(rs.front, 0) != viewer)
    {
        replyError(cgi, 403, "not the author");
        return;
    }

    Variant[] remove;
    remove ~= vlong(commentId);
    conn.queryImpl(deleteCommentSql, remove);
    replyNoContent(cgi);
}

// ---------------------------------------------------------------------------
// tags

/// GET /api/tags
private void tags(Cgi cgi)
{
    auto rs = dbConn().queryImpl(tagsAll);
    string[] tags;
    while (!rs.empty)
    {
        tags ~= cell(rs.front, 0);
        rs.popFront();
    }
    replyJson(cgi, 200, TagsDto(tags));
}

// ---------------------------------------------------------------------------
// routing

private void route(Cgi cgi)
{
    import std.string : startsWith;

    immutable path = cgi.pathInfo;
    immutable method = cgi.requestMethod;

    if (path == "/api/tags")
    {
        if (method == Cgi.RequestMethod.GET)
            return tags(cgi);
        return notFound(cgi);
    }
    if (path == "/api/users")
    {
        if (method == Cgi.RequestMethod.POST)
            return register(cgi);
        return notFound(cgi);
    }
    if (path == "/api/users/login")
    {
        if (method == Cgi.RequestMethod.POST)
            return login(cgi);
        return notFound(cgi);
    }
    if (path == "/api/user")
    {
        if (method == Cgi.RequestMethod.GET)
            return currentUser(cgi);
        if (method == Cgi.RequestMethod.PUT)
            return updateUser(cgi);
        return notFound(cgi);
    }
    if (path == "/api/articles/feed")
    {
        if (method == Cgi.RequestMethod.GET)
            return feed(cgi);
        return notFound(cgi);
    }
    if (path == "/api/articles")
    {
        if (method == Cgi.RequestMethod.GET)
            return listArticles(cgi);
        if (method == Cgi.RequestMethod.POST)
            return createArticle(cgi);
        return notFound(cgi);
    }
    if (startsWith(path, "/api/profiles/"))
    {
        auto rest = path["/api/profiles/".length .. $];
        if (rest.length > "/follow".length && startsWith(rest[$ - "/follow".length .. $], "/follow"))
        {
            auto username = urlDecode(rest[0 .. $ - "/follow".length]);
            if (method == Cgi.RequestMethod.POST)
                return follow(cgi, username, true);
            if (method == Cgi.RequestMethod.DELETE)
                return follow(cgi, username, false);
            return notFound(cgi);
        }
        if (method == Cgi.RequestMethod.GET)
            return getProfile(cgi, urlDecode(rest));
        return notFound(cgi);
    }
    if (startsWith(path, "/api/articles/"))
    {
        return routeArticle(cgi, path["/api/articles/".length .. $], method);
    }
    notFound(cgi);
}

/// Everything under `/api/articles/<slug>...`.
private void routeArticle(Cgi cgi, const(char)[] rest, Cgi.RequestMethod method)
{
    import std.string : indexOf, startsWith;

    immutable slash = rest.indexOf('/');
    if (slash < 0)
    {
        auto slug = urlDecode(rest);
        if (method == Cgi.RequestMethod.GET)
            return getArticle(cgi, slug);
        if (method == Cgi.RequestMethod.PUT)
            return updateArticle(cgi, slug);
        if (method == Cgi.RequestMethod.DELETE)
            return deleteArticle(cgi, slug);
        return notFound(cgi);
    }

    auto slug = urlDecode(rest[0 .. slash]);
    auto tail = rest[slash + 1 .. $];
    if (tail == "comments")
    {
        if (method == Cgi.RequestMethod.GET)
            return listComments(cgi, slug);
        if (method == Cgi.RequestMethod.POST)
            return createComment(cgi, slug);
        return notFound(cgi);
    }
    if (tail == "favorite")
    {
        if (method == Cgi.RequestMethod.POST)
            return favorite(cgi, slug, true);
        if (method == Cgi.RequestMethod.DELETE)
            return favorite(cgi, slug, false);
        return notFound(cgi);
    }
    if (startsWith(tail, "comments/"))
    {
        if (method == Cgi.RequestMethod.DELETE)
            return deleteComment(cgi, slug, urlDecode(tail["comments/".length .. $]));
        return notFound(cgi);
    }
    notFound(cgi);
}

private void notFound(Cgi cgi)
{
    replyError(cgi, 404, "not found");
}
