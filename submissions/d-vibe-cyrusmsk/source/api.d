/// The 19 Conduit endpoints (SPEC.md), served through vibe.d's URLRouter.
///
/// Every handler reads its rows from Postgres while it is being served: no
/// response caches, no query caches, no in-memory table copies, no remembered
/// verifications. Responses are built with vibe.data.json and written with
/// `writeJsonBody`, which sets `Content-Length` on the way out.
module conduit.api;

import vibe.core.log;
import vibe.http.router;
import vibe.http.server;
import vibe.data.json;
import vibe.db.postgresql;
import vibe.stream.operations : readAllUTF8;

import conduit.auth;
import conduit.bcrypt;
import conduit.db;

import std.datetime : SysTime;
import std.format : format;
import std.typecons : Nullable;

/// The database pool of the worker thread that serves this request. A vibe.d
/// connection belongs to the thread that opened it, so each thread sets its
/// own pool once, in `workerMain`.
static Db pool;

/// Called once per worker thread, from that thread.
void setPool(Db db) nothrow
{
    pool = db;
}

/// Registers the 19 endpoints. `/api/articles/feed` comes before
/// `/api/articles/:slug`, otherwise "feed" would match `:slug`.
void registerRoutes(URLRouter router)
{
    router.post("/api/users", &register);
    router.post("/api/users/login", &login);
    router.get("/api/user", &currentUser);
    router.put("/api/user", &updateUser);

    router.get("/api/profiles/:username", &getProfile);
    router.post("/api/profiles/:username/follow", &followProfile);
    router.delete_("/api/profiles/:username/follow", &unfollowProfile);

    router.get("/api/articles/feed", &feed);
    router.get("/api/articles", &listArticles);
    router.post("/api/articles", &createArticle);
    router.get("/api/articles/:slug/comments", &listComments);
    router.post("/api/articles/:slug/comments", &createComment);
    router.delete_("/api/articles/:slug/comments/:id", &deleteComment);
    router.post("/api/articles/:slug/favorite", &favoriteArticle);
    router.delete_("/api/articles/:slug/favorite", &unfavoriteArticle);
    router.get("/api/articles/:slug", &getArticle);
    router.put("/api/articles/:slug", &updateArticle);
    router.delete_("/api/articles/:slug", &deleteArticle);

    router.get("/api/tags", &tags);
}

/// vibe.d's own error path (unknown paths, malformed requests, uncaught
/// exceptions): the same `{"errors": {"body": [...]}}` shape as every error.
void errorPage(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
{
    if (res.headerWritten)
        return;
    if (error.code >= 500)
        logError("%s %s -> %s: %s", req.method, req.requestURI, error.code, error.message);
    writeError(res, error.code, error.message.length ? error.message : "error");
}

// ---------------------------------------------------------------------------
// responses

private void writeJson(HTTPServerResponse res, int status, Json body)
{
    // Chunked: a single serialization pass. The default counts the body first
    // (a full extra serialization) to set Content-Length; chunk framing on a
    // buffered stream costs far less than serializing twice.
    res.writeJsonBody(body, status, true);
}

/// Struct responses serialize directly, without a JSON DOM in between.
private void writeJson(T)(HTTPServerResponse res, int status, T body)
    if (!is(T == Json))
{
    res.writeJsonBody(body, status, true);
}

private void writeError(HTTPServerResponse res, int status, string message)
{
    writeJson(res, status, Json(["errors": Json(["body": Json([Json(message)])])]));
}

private void writeNoContent(HTTPServerResponse res)
{
    res.statusCode = 204;
    res.writeVoidBody();
}

// ---------------------------------------------------------------------------
// auth

private struct Viewer
{
    long id;
    string token;
    bool present;
}

/// Reads the `Authorization` header and verifies the token: HS256 signature
/// and `exp`, checked on every request.
private Viewer viewerOf(HTTPServerRequest req)
{
    auto header = "Authorization" in req.headers;
    if (!header)
        return Viewer(0, null, false);
    if ((*header).length <= 6 || (*header)[0 .. 6] != "Token ")
        return Viewer(0, null, true);
    string token = (*header)[6 .. $];
    long id;
    if (!verifyToken(token, id))
        return Viewer(0, null, true);
    return Viewer(id, token, true);
}

/// A missing or invalid token is a 401.
private bool requireAuth(HTTPServerResponse res, HTTPServerRequest req, out long viewer, out string token)
{
    auto auth = viewerOf(req);
    viewer = auth.id;
    token = auth.token;
    if (!auth.present || auth.id == 0)
    {
        writeError(res, 401, "unauthorized");
        return false;
    }
    return true;
}

/// No header means anonymous; a present but invalid token is a 401.
private bool optionalAuth(HTTPServerResponse res, HTTPServerRequest req, out long viewer)
{
    auto auth = viewerOf(req);
    viewer = auth.id;
    if (auth.present && auth.id == 0)
    {
        writeError(res, 401, "unauthorized");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// request bodies

/// Reads the wrapper object of a request body (`{"user": {...}}`), or writes
/// a 422. Anything malformed, missing, or not an object is a 422.
private bool readWrapper(HTTPServerRequest req, HTTPServerResponse res, string wrapper, out Json inner)
{
    Json top;
    try
        top = parseJsonString(req.bodyReader.readAllUTF8());
    catch (Exception)
    {
        writeError(res, 422, "invalid body");
        return false;
    }
    if (top.type != Json.Type.object)
    {
        writeError(res, 422, "invalid body");
        return false;
    }
    auto members = top.get!(Json[string]);
    auto found = wrapper in members;
    if (!found || (*found).type != Json.Type.object)
    {
        writeError(res, 422, "invalid body");
        return false;
    }
    inner = *found;
    return true;
}

/// A member's value: absent (or null) reads as missing, a string reads as
/// itself, anything else is invalid.
private struct Field
{
    bool present;
    string value;
    bool valid = true;
}

private Field field(Json obj, string key)
{
    auto members = obj.get!(Json[string]);
    auto found = key in members;
    if (!found)
        return Field(false, null, true);
    if ((*found).type == Json.Type.null_)
        return Field(false, null, true);
    if ((*found).type != Json.Type.string)
        return Field(false, null, false);
    return Field(true, (*found).get!string, true);
}

/// A required non-empty string member, or 422.
private bool reqString(HTTPServerResponse res, Json obj, string key, out string value)
{
    auto f = field(obj, key);
    if (!f.valid || !f.present || f.value.length == 0)
    {
        writeError(res, 422, key ~ " must be a non-empty string");
        return false;
    }
    value = f.value;
    return true;
}

/// An optional string member: absent or null leaves it unset, a string sets
/// it, anything else is a 422.
private bool optString(HTTPServerResponse res, Json obj, string key, bool nonEmpty,
        out bool present, out string value)
{
    auto f = field(obj, key);
    if (!f.valid || (nonEmpty && f.present && f.value.length == 0))
    {
        writeError(res, 422, key ~ " must be a non-empty string");
        return false;
    }
    present = f.present;
    value = f.value;
    return true;
}

// ---------------------------------------------------------------------------
// pages and ids

/// `limit` (default 20, 1..100) and `offset` (default 0, >= 0), or 422.
private bool pageArgs(HTTPServerResponse res, HTTPServerRequest req, out long limit, out long offset)
{
    limit = 20;
    offset = 0;
    auto query = req.query;
    if (auto value = "limit" in query)
    {
        if (!parseDigits(*value, limit) || limit < 1 || limit > 100)
        {
            writeError(res, 422, "limit must be an integer 1..100");
            return false;
        }
    }
    if (auto value = "offset" in query)
    {
        if (!parseDigits(*value, offset) || offset < 0)
        {
            writeError(res, 422, "offset must be an integer >= 0");
            return false;
        }
    }
    return true;
}

/// ASCII digits only, no sign, no spaces, fitting in a long. Leading zeros are
/// fine (`limit=05`); a value that overflows is not.
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

// ---------------------------------------------------------------------------
// rows to JSON

/// A UTC timestamp as SPEC.md wants it: RFC 3339, exactly 3 fractional digits.
private string formatTs(SysTime time)
{
    auto utc = time.toUTC();
    return format!"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"(
        utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second,
        utc.fracSecs.total!"msecs");
}

/// A text cell as a slice of the answer: no copy. The answer outlives the
/// response being written, so the slice is always valid.
private string cellText(immutable(Value) cell) @trusted
{
    return cast(string) cell.data;
}

private Nullable!string cellNullable(immutable(Value) cell) @trusted
{
    return cell.isNull ? Nullable!string.init : Nullable!string(cast(string) cell.data);
}

// Responses are typed structs holding slices of the answer: no JSON DOM, no
// intermediate copies. `writeJsonBody` serializes the struct directly.
struct ProfileOut
{
    string username;
    Nullable!string bio;
    Nullable!string image;
    bool following;
}

struct ArticleListOut
{
    string slug;
    string title;
    string description;
    string[] tagList;
    string createdAt;
    string updatedAt;
    bool favorited;
    long favoritesCount;
    ProfileOut author;
}

struct ArticleFullOut
{
    string slug;
    string title;
    string description;
    string body;
    string[] tagList;
    string createdAt;
    string updatedAt;
    bool favorited;
    long favoritesCount;
    ProfileOut author;
}

struct ArticlesOut
{
    ArticleListOut[] articles;
    long articlesCount;
}

struct ArticleOut
{
    ArticleFullOut article;
}

struct UserOut
{
    string username;
    string email;
    Nullable!string bio;
    Nullable!string image;
    string token;
}

struct UserResponse
{
    UserOut user;
}

struct ProfileResponse
{
    ProfileOut profile;
}

struct CommentOut
{
    long id;
    string createdAt;
    string updatedAt;
    string body;
    ProfileOut author;
}

struct CommentResponse
{
    CommentOut comment;
}

struct CommentsOut
{
    CommentOut[] comments;
}

struct TagsOut
{
    string[] tags;
}

/// The author object shared by articles and comments.
private ProfileOut profileOut(Row row, size_t username)
{
    ProfileOut profile;
    profile.username = cellText(row[username]);
    profile.bio = cellNullable(row[username + 1]);
    profile.image = cellNullable(row[username + 2]);
    profile.following = row[username + 3].as!bool;
    return profile;
}

/// A Postgres `text[]` as an array of strings.
private string[] tagList(Row row, size_t column)
{
    auto array = row[column].asArray;
    auto tags = new string[](array.length);
    foreach (i; 0 .. array.length)
        tags[i] = cellText(array[i]);
    return tags;
}

/// An article row. The column layout is the reference SQL's: id, slug, title,
/// description, [body,] created, updated, tag list, favorites count,
/// favorited, author columns.
private ArticleFullOut fullArticle(Row row)
{
    ArticleFullOut article;
    article.slug = cellText(row[1]);
    article.title = cellText(row[2]);
    article.description = cellText(row[3]);
    article.body = cellText(row[4]);
    article.tagList = tagList(row, 7);
    article.createdAt = formatTs(row[5].as!SysTime);
    article.updatedAt = formatTs(row[6].as!SysTime);
    article.favoritesCount = row[8].as!long;
    article.favorited = row[9].as!bool;
    article.author = profileOut(row, 10);
    return article;
}

private ArticleListOut listArticle(Row row)
{
    ArticleListOut article;
    article.slug = cellText(row[1]);
    article.title = cellText(row[2]);
    article.description = cellText(row[3]);
    article.tagList = tagList(row, 6);
    article.createdAt = formatTs(row[4].as!SysTime);
    article.updatedAt = formatTs(row[5].as!SysTime);
    article.favoritesCount = row[7].as!long;
    article.favorited = row[8].as!bool;
    article.author = profileOut(row, 9);
    return article;
}

private CommentOut commentOut(Row row, bool following)
{
    CommentOut comment;
    comment.id = row[0].as!long;
    comment.createdAt = formatTs(row[2].as!SysTime);
    comment.updatedAt = formatTs(row[3].as!SysTime);
    comment.body = cellText(row[1]);
    comment.author.username = cellText(row[4]);
    comment.author.bio = cellNullable(row[5]);
    comment.author.image = cellNullable(row[6]);
    comment.author.following = following;
    return comment;
}

private UserOut userOut(Row row, string token)
{
    UserOut user;
    user.username = cellText(row[1]);
    user.email = cellText(row[2]);
    user.bio = cellNullable(row[3]);
    user.image = cellNullable(row[4]);
    user.token = token;
    return user;
}

/// Runs a statement whose unique violations (a taken username or email) are a
/// 422. `ok` is false when the response was already written.
private Answer execUnique(HTTPServerResponse res, QueryParams params, out bool ok)
{
    try
    {
        ok = true;
        return pool.lockConnection.execPrepared(params);
    }
    catch (Exception e)
    {
        ok = false;
        if (isDuplicate(e))
        {
            writeError(res, 422, "username or email is already taken");
            return null;
        }
        throw e;
    }
}

/// True when a statement failed on a unique constraint (SPEC.md: 422).
private bool isDuplicate(Exception e)
{
    auto response = cast(ResponseException) e;
    if (!response)
        return false;
    try
        return response.result.resultErrorField('C') == "23505";
    catch (Exception)
        return false;
}

// ---------------------------------------------------------------------------
// users

/// POST /api/users
private void register(HTTPServerRequest req, HTTPServerResponse res)
{
    Json inner;
    if (!readWrapper(req, res, "user", inner))
        return;
    string username, email, password;
    if (!reqString(res, inner, "username", username))
        return;
    if (!reqString(res, inner, "email", email))
        return;
    if (!reqString(res, inner, "password", password))
        return;

    auto hash = hashPassword(password);
    if (!hash)
    {
        writeError(res, 422, "password is too long");
        return;
    }

    QueryParams params;
    params.preparedStatementName = Name.insertUser;
    params.argsVariadic(username, email, hash);
    bool ok;
    auto answer = execUnique(res, params, ok);
    if (!ok)
        return;
    if (answer.length != 1)
    {
        writeError(res, 500, "internal error");
        return;
    }
    writeJson(res, 201, UserResponse(userOut(answer[0], issueToken(answer[0][0].as!long, nowUnix()))));
}

/// POST /api/users/login
private void login(HTTPServerRequest req, HTTPServerResponse res)
{
    Json inner;
    if (!readWrapper(req, res, "user", inner))
        return;
    string email, password;
    if (!reqString(res, inner, "email", email))
        return;
    if (!reqString(res, inner, "password", password))
        return;

    QueryParams params;
    params.preparedStatementName = Name.userByEmail;
    params.argsVariadic(email);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length == 0 || !verifyPassword(password, answer[0][5].as!string))
    {
        writeError(res, 401, "invalid email or password");
        return;
    }
    writeJson(res, 200, UserResponse(userOut(answer[0], issueToken(answer[0][0].as!long, nowUnix()))));
}

/// GET /api/user
private void currentUser(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;

    QueryParams params;
    params.preparedStatementName = Name.userById;
    params.argsVariadic(viewer);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length == 0)
    {
        writeError(res, 401, "unauthorized");
        return;
    }
    writeJson(res, 200, UserResponse(userOut(answer[0], token)));
}

/// PUT /api/user
private void updateUser(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;
    Json inner;
    if (!readWrapper(req, res, "user", inner))
        return;

    string email, username, password, bio, image;
    bool hasEmail, hasUsername, hasPassword, hasBio, hasImage;
    if (!optString(res, inner, "email", true, hasEmail, email))
        return;
    if (!optString(res, inner, "username", true, hasUsername, username))
        return;
    if (!optString(res, inner, "password", true, hasPassword, password))
        return;
    if (!optString(res, inner, "bio", false, hasBio, bio))
        return;
    if (!optString(res, inner, "image", false, hasImage, image))
        return;

    Nullable!string hash;
    if (hasPassword)
    {
        auto hashed = hashPassword(password);
        if (!hashed)
        {
            writeError(res, 422, "password is too long");
            return;
        }
        hash = hashed;
    }

    QueryParams params;
    params.preparedStatementName = Name.updateUser;
    params.argsVariadic(viewer,
        hasEmail ? Nullable!string(email) : Nullable!string.init,
        hasUsername ? Nullable!string(username) : Nullable!string.init,
        hash,
        hasBio ? Nullable!string(bio) : Nullable!string.init,
        hasImage ? Nullable!string(image) : Nullable!string.init);
    bool ok;
    auto answer = execUnique(res, params, ok);
    if (!ok)
        return;
    if (answer.length == 0)
    {
        writeError(res, 401, "unauthorized");
        return;
    }
    writeJson(res, 200, UserResponse(userOut(answer[0], token)));
}

// ---------------------------------------------------------------------------
// profiles

/// GET /api/profiles/:username
private void getProfile(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    if (!optionalAuth(res, req, viewer))
        return;

    QueryParams params;
    params.preparedStatementName = Name.profile;
    params.argsVariadic(viewer, req.params["username"]);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length == 0)
    {
        writeError(res, 404, "profile not found");
        return;
    }
    writeJson(res, 200, ProfileResponse(profileOut(answer[0], 1)));
}

/// POST and DELETE /api/profiles/:username/follow
private void follow(HTTPServerRequest req, HTTPServerResponse res, bool follow)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;

    QueryParams lookup;
    lookup.preparedStatementName = Name.userByUsername;
    lookup.argsVariadic(req.params["username"]);
    auto conn = pool.lockConnection;
    auto found = conn.execPrepared(lookup);
    if (found.length == 0)
    {
        writeError(res, 404, "profile not found");
        return;
    }
    auto followee = found[0][0].as!long;

    QueryParams change;
    change.preparedStatementName = follow ? Name.insertFollow : Name.deleteFollow;
    change.argsVariadic(viewer, followee);
    conn.execPrepared(change);

    ProfileOut profile;
    profile.username = cellText(found[0][1]);
    profile.bio = cellNullable(found[0][2]);
    profile.image = cellNullable(found[0][3]);
    profile.following = follow;
    writeJson(res, 200, ProfileResponse(profile));
}

private void followProfile(HTTPServerRequest req, HTTPServerResponse res)
{
    follow(req, res, true);
}

private void unfollowProfile(HTTPServerRequest req, HTTPServerResponse res)
{
    follow(req, res, false);
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

/// GET /api/articles. With more than one filter, the first non-empty one in
/// the order tag, author, favorited applies.
private void listArticles(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    if (!optionalAuth(res, req, viewer))
        return;
    long limit, offset;
    if (!pageArgs(res, req, limit, offset))
        return;

    auto query = req.query;
    ListKind kind = ListKind.all;
    string filter;
    if (auto value = "tag" in query)
    {
        filter = *value;
        kind = ListKind.tag;
    }
    if (!filter.length)
    {
        if (auto value = "author" in query)
        {
            filter = *value;
            kind = ListKind.author;
        }
    }
    if (!filter.length)
    {
        if (auto value = "favorited" in query)
        {
            filter = *value;
            kind = ListKind.favorited;
        }
    }
    if (!filter.length)
        kind = ListKind.all;

    QueryParams page, count;
    final switch (kind)
    {
    case ListKind.all:
        page.preparedStatementName = Name.listAll;
        page.argsVariadic(viewer, limit, offset);
        count.preparedStatementName = Name.countAll;
        break;
    case ListKind.tag:
        page.preparedStatementName = Name.listByTag;
        page.argsVariadic(viewer, limit, offset, filter);
        count.preparedStatementName = Name.countByTag;
        count.argsVariadic(filter);
        break;
    case ListKind.author:
        page.preparedStatementName = Name.listByAuthor;
        page.argsVariadic(viewer, limit, offset, filter);
        count.preparedStatementName = Name.countByAuthor;
        count.argsVariadic(filter);
        break;
    case ListKind.favorited:
        page.preparedStatementName = Name.listByFavorite;
        page.argsVariadic(viewer, limit, offset, filter);
        count.preparedStatementName = Name.countByFavorite;
        count.argsVariadic(filter);
        break;
    }

    auto conn = pool.lockConnection;
    auto answers = execPipeline(conn, [page, count]);
    auto rows = answers[0];
    auto total = answers[1];
    auto articles = new ArticleListOut[](rows.length);
    foreach (i; 0 .. rows.length)
        articles[i] = listArticle(rows[i]);
    writeJson(res, 200, ArticlesOut(articles, total[0][0].as!long));
}

/// GET /api/articles/feed
private void feed(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;
    long limit, offset;
    if (!pageArgs(res, req, limit, offset))
        return;

    QueryParams page, count;
    page.preparedStatementName = Name.listFeed;
    page.argsVariadic(viewer, limit, offset);
    count.preparedStatementName = Name.countFeed;
    count.argsVariadic(viewer);

    auto conn = pool.lockConnection;
    auto answers = execPipeline(conn, [page, count]);
    auto rows = answers[0];
    auto total = answers[1];
    auto articles = new ArticleListOut[](rows.length);
    foreach (i; 0 .. rows.length)
        articles[i] = listArticle(rows[i]);
    writeJson(res, 200, ArticlesOut(articles, total[0][0].as!long));
}

/// GET /api/articles/:slug
private void getArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    if (!optionalAuth(res, req, viewer))
        return;

    QueryParams params;
    params.preparedStatementName = Name.articleBySlug;
    params.argsVariadic(viewer, req.params["slug"]);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length == 0)
    {
        writeError(res, 404, "article not found");
        return;
    }
    writeJson(res, 200, ArticleOut(fullArticle(answer[0])));
}

/// POST /api/articles
private void createArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;
    Json inner;
    if (!readWrapper(req, res, "article", inner))
        return;
    string title, description, body;
    if (!reqString(res, inner, "title", title))
        return;
    if (!reqString(res, inner, "description", description))
        return;
    if (!reqString(res, inner, "body", body))
        return;

    string[] tags;
    {
        auto members = inner.get!(Json[string]);
        if (auto raw = "tagList" in members)
        {
            if ((*raw).type == Json.Type.null_)
            {
            }
            else if ((*raw).type != Json.Type.array)
            {
                writeError(res, 422, "tagList must be an array of non-empty strings");
                return;
            }
            else
            {
                foreach (item; (*raw).get!(Json[]))
                {
                    if (item.type != Json.Type.string || item.get!string.length == 0)
                    {
                        writeError(res, 422, "tagList must be an array of non-empty strings");
                        return;
                    }
                    tags ~= item.get!string;
                }
            }
        }
    }

    auto conn = pool.lockConnection;
    conn.exec("BEGIN");
    scope (failure)
    {
        try
            conn.exec("ROLLBACK");
        catch (Exception rollbackError)
            logError("rollback failed: %s", rollbackError.msg);
    }

    QueryParams insert;
    insert.preparedStatementName = Name.insertArticle;
    insert.argsVariadic(viewer, title, description, body);
    auto created = conn.execPrepared(insert);
    if (created.length != 1)
    {
        writeError(res, 500, "internal error");
        return;
    }
    auto id = created[0][0].as!long;
    if (tags.length)
    {
        QueryParams names;
        names.preparedStatementName = Name.insertTags;
        names.argsVariadic(tags);
        conn.execPrepared(names);
        QueryParams links;
        links.preparedStatementName = Name.insertArticleTags;
        links.argsVariadic(id, tags);
        conn.execPrepared(links);
    }
    conn.exec("COMMIT");

    QueryParams full;
    full.preparedStatementName = Name.articleById;
    full.argsVariadic(viewer, id);
    auto answer = conn.execPrepared(full);
    writeJson(res, 201, ArticleOut(fullArticle(answer[0])));
}

/// The article by slug, or 404; the article's author, or 403.
private bool ownArticle(HTTPServerResponse res, string slug, long viewer, out long id)
{
    QueryParams params;
    params.preparedStatementName = Name.articleOwner;
    params.argsVariadic(slug);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length == 0)
    {
        writeError(res, 404, "article not found");
        return false;
    }
    if (answer[0][1].as!long != viewer)
    {
        writeError(res, 403, "not the author");
        return false;
    }
    id = answer[0][0].as!long;
    return true;
}

/// PUT /api/articles/:slug
private void updateArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;
    Json inner;
    if (!readWrapper(req, res, "article", inner))
        return;
    string title, description, body;
    bool hasTitle, hasDescription, hasBody;
    if (!optString(res, inner, "title", true, hasTitle, title))
        return;
    if (!optString(res, inner, "description", true, hasDescription, description))
        return;
    if (!optString(res, inner, "body", true, hasBody, body))
        return;

    long id;
    if (!ownArticle(res, req.params["slug"], viewer, id))
        return;

    QueryParams params;
    params.preparedStatementName = Name.updateArticle;
    params.argsVariadic(id,
        hasTitle ? Nullable!string(title) : Nullable!string.init,
        hasDescription ? Nullable!string(description) : Nullable!string.init,
        hasBody ? Nullable!string(body) : Nullable!string.init);
    pool.lockConnection.execPrepared(params);

    QueryParams full;
    full.preparedStatementName = Name.articleById;
    full.argsVariadic(viewer, id);
    auto answer = pool.lockConnection.execPrepared(full);
    writeJson(res, 200, ArticleOut(fullArticle(answer[0])));
}

/// DELETE /api/articles/:slug
private void deleteArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;

    long id;
    if (!ownArticle(res, req.params["slug"], viewer, id))
        return;
    QueryParams params;
    params.preparedStatementName = Name.deleteArticle;
    params.argsVariadic(id);
    pool.lockConnection.execPrepared(params);
    writeNoContent(res);
}

/// The article id by slug, or 404.
private bool articleId(HTTPServerResponse res, string slug, out long id)
{
    QueryParams params;
    params.preparedStatementName = Name.articleIdBySlug;
    params.argsVariadic(slug);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length == 0)
    {
        writeError(res, 404, "article not found");
        return false;
    }
    id = answer[0][0].as!long;
    return true;
}

/// POST and DELETE /api/articles/:slug/favorite
private void favorite(HTTPServerRequest req, HTTPServerResponse res, bool favorite)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;

    long id;
    if (!articleId(res, req.params["slug"], id))
        return;
    QueryParams change;
    change.preparedStatementName = favorite ? Name.insertFavorite : Name.deleteFavorite;
    change.argsVariadic(viewer, id);

    auto conn = pool.lockConnection;
    conn.execPrepared(change);
    QueryParams full;
    full.preparedStatementName = Name.articleById;
    full.argsVariadic(viewer, id);
    auto answer = conn.execPrepared(full);
    writeJson(res, 200, ArticleOut(fullArticle(answer[0])));
}

private void favoriteArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    favorite(req, res, true);
}

private void unfavoriteArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    favorite(req, res, false);
}

// ---------------------------------------------------------------------------
// comments

/// GET /api/articles/:slug/comments
private void listComments(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    if (!optionalAuth(res, req, viewer))
        return;

    long id;
    if (!articleId(res, req.params["slug"], id))
        return;
    QueryParams params;
    params.preparedStatementName = Name.commentsByArticle;
    params.argsVariadic(viewer, id);
    auto answer = pool.lockConnection.execPrepared(params);
    auto comments = new CommentOut[](answer.length);
    foreach (i; 0 .. answer.length)
    {
        auto row = answer[i];
        comments[i] = commentOut(row, row[7].as!bool);
    }
    writeJson(res, 200, CommentsOut(comments));
}

/// POST /api/articles/:slug/comments
private void createComment(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;
    Json inner;
    if (!readWrapper(req, res, "comment", inner))
        return;
    string body;
    if (!reqString(res, inner, "body", body))
        return;

    long id;
    if (!articleId(res, req.params["slug"], id))
        return;
    QueryParams params;
    params.preparedStatementName = Name.insertComment;
    params.argsVariadic(id, viewer, body);
    auto answer = pool.lockConnection.execPrepared(params);
    if (answer.length != 1)
    {
        writeError(res, 500, "internal error");
        return;
    }
    writeJson(res, 201, CommentResponse(commentOut(answer[0], false)));
}

/// DELETE /api/articles/:slug/comments/:id. A non-integer id is a 404.
private void deleteComment(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    string token;
    if (!requireAuth(res, req, viewer, token))
        return;

    long commentId;
    if (!parseDigits(req.params["id"], commentId))
    {
        writeError(res, 404, "comment not found");
        return;
    }
    QueryParams params;
    params.preparedStatementName = Name.commentOwner;
    params.argsVariadic(commentId, req.params["slug"]);
    auto conn = pool.lockConnection;
    auto answer = conn.execPrepared(params);
    if (answer.length == 0)
    {
        writeError(res, 404, "comment not found");
        return;
    }
    if (answer[0][0].as!long != viewer)
    {
        writeError(res, 403, "not the author");
        return;
    }
    QueryParams remove;
    remove.preparedStatementName = Name.deleteComment;
    remove.argsVariadic(commentId);
    conn.execPrepared(remove);
    writeNoContent(res);
}

// ---------------------------------------------------------------------------
// tags

/// GET /api/tags
private void tags(HTTPServerRequest req, HTTPServerResponse res)
{
    QueryParams params;
    params.preparedStatementName = Name.tagsAll;
    auto answer = pool.lockConnection.execPrepared(params);
    auto names = new string[](answer.length);
    foreach (i; 0 .. answer.length)
        names[i] = cellText(answer[i][0]);
    writeJson(res, 200, TagsOut(names));
}
