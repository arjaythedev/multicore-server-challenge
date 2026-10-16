/**
 * The 19 Conduit endpoints (SPEC.md).
 *
 * Every handler reads its rows from Postgres while it is being served - there are
 * no response caches, query caches, in-memory table copies, or remembered JWT
 * verifications in this file. What is shared between requests is only patterns:
 * prepared statements, connections, and code.
 */
module conduit.api;

import vibe.core.log;
import vibe.http.server;
import vibe.stream.operations : readAllUTF8;

import conduit.body;
import conduit.bcrypt;
import conduit.db;
import conduit.db : Name, lastStatement;
import conduit.jwt;
import conduit.json;

import dpq2;
import dpq2.args : QueryParams;
import dpq2.result : Answer, ResponseException;

import std.array : Appender, appender;
import std.conv : to;
import std.string : indexOf;
import std.typecons : Nullable;

/// The per-thread database pool. A vibe.d Postgres connection belongs to the
/// thread (and fiber pool) that opened it, so this has to be thread-local.
static Db g_db;

/// Called once per thread, from that thread.
void setDb(Db db) @trusted nothrow
{
    g_db = db;
}

/// Prepares a statement call. The result comes back as text, which for these
/// queries is what the JSON response wants almost verbatim.
QueryParams params(Args...)(string stmt, Args args)
{
    QueryParams p;
    p.sqlCommand = stmt;
    p.resultFormat = ValueFormat.TEXT;
    static if (Args.length > 0)
        p.argsVariadic(args);
    return p;
}

// ---------------------------------------------------------------------------
// request handling

/// vibe.d entry point for every connection.
void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    try dispatch(req, res);
    catch (Exception e) {
        logError("request failed in %s: %s", lastStatement, e.msg);
        try sendError(res, 500, "internal error");
        catch (Exception) {
        }
    }
}

private void dispatch(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    const(char)[] path = req.requestURI;
    immutable q = path.indexOf('?');
    if (q >= 0) path = path[0 .. cast(size_t) q];

    // tolerate an absolute request target ("GET http://host/api/...").
    if (path.length >= 7 && path[0 .. 7] == "http://") {
        immutable slash = path.indexOf('/', 7);
        path = slash < 0 ? "/" : path[cast(size_t) slash .. $];
    }

    if (path.length < 4 || path[0 .. 4] != "/api") {
        sendError(res, 404, "not found");
        return;
    }

    switch (req.method) {
    case HTTPMethod.GET:
        routeGet(req, res, path);
        return;
    case HTTPMethod.POST:
        routePost(req, res, path);
        return;
    case HTTPMethod.PUT:
        routePut(req, res, path);
        return;
    case HTTPMethod.DELETE:
        routeDelete(req, res, path);
        return;
    default:
        sendError(res, 404, "not found");
        return;
    }
}

/// True when `path` is `prefix` plus exactly one non-empty segment.
private bool segment(const(char)[] path, const(char)[] prefix, out const(char)[] rest) pure nothrow @safe
{
    if (path.length <= prefix.length || path[0 .. prefix.length] != prefix) return false;
    rest = path[prefix.length .. $];
    return rest.length > 0 && rest.indexOf('/') < 0;
}

/// True when `path` is `prefix` plus exactly two non-empty segments.
private bool twoSegments(const(char)[] path, const(char)[] prefix, out const(char)[] first,
        out const(char)[] second) pure nothrow @safe
{
    if (path.length <= prefix.length || path[0 .. prefix.length] != prefix) return false;
    auto rest = path[prefix.length .. $];
    immutable slash = rest.indexOf('/');
    if (slash <= 0 || cast(size_t) slash + 1 >= rest.length) return false;
    first = rest[0 .. cast(size_t) slash];
    second = rest[cast(size_t) slash + 1 .. $];
    return second.indexOf('/') < 0;
}

/// True when `path` is `prefix` plus exactly three non-empty segments.
private bool threeSegments(const(char)[] path, const(char)[] prefix, out const(char)[] first,
        out const(char)[] second, out const(char)[] third) pure nothrow @safe
{
    if (path.length <= prefix.length || path[0 .. prefix.length] != prefix) return false;
    auto rest = path[prefix.length .. $];
    immutable s1 = rest.indexOf('/');
    if (s1 <= 0 || cast(size_t) s1 + 1 >= rest.length) return false;
    auto tail = rest[cast(size_t) s1 + 1 .. $];
    immutable s2 = tail.indexOf('/');
    if (s2 <= 0 || cast(size_t) s2 + 1 >= tail.length) return false;
    first = rest[0 .. cast(size_t) s1];
    second = tail[0 .. cast(size_t) s2];
    third = tail[cast(size_t) s2 + 1 .. $];
    return third.indexOf('/') < 0;
}

private void routeGet(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] path)
@trusted
{
    if (path == "/api/tags") return sendTags(req, res);
    if (path == "/api/user") return sendCurrentUser(req, res);
    if (path == "/api/articles") return sendArticleList(req, res);
    if (path == "/api/articles/feed") return sendFeed(req, res);

    const(char)[] a, b;
    if (twoSegments(path, "/api/articles/", a, b) && b == "comments")
        return sendComments(req, res, a);
    if (segment(path, "/api/articles/", a)) return sendArticle(req, res, a);
    if (segment(path, "/api/profiles/", a)) return sendProfile(req, res, a);
    sendError(res, 404, "not found");
}

private void routePost(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] path)
@trusted
{
    if (path == "/api/users") return sendRegister(req, res);
    if (path == "/api/users/login") return sendLogin(req, res);
    if (path == "/api/articles") return createArticle(req, res);

    const(char)[] a, b;
    if (twoSegments(path, "/api/articles/", a, b) && b == "favorite")
        return favoriteArticle(req, res, a, true);
    if (twoSegments(path, "/api/articles/", a, b) && b == "comments")
        return createComment(req, res, a);
    if (twoSegments(path, "/api/profiles/", a, b) && b == "follow")
        return followProfile(req, res, a, true);
    sendError(res, 404, "not found");
}

private void routePut(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] path)
@trusted
{
    if (path == "/api/user") return updateUser(req, res);
    const(char)[] a;
    if (segment(path, "/api/articles/", a)) return updateArticle(req, res, a);
    sendError(res, 404, "not found");
}

private void routeDelete(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] path)
@trusted
{
    const(char)[] a, b, c;  // slug, sub-path, comment id
    if (twoSegments(path, "/api/profiles/", a, b) && b == "follow")
        return followProfile(req, res, a, false);
    if (twoSegments(path, "/api/articles/", a, b) && b == "favorite")
        return favoriteArticle(req, res, a, false);
    if (threeSegments(path, "/api/articles/", a, b, c) && b == "comments")
        return deleteComment(req, res, a, c);
    if (segment(path, "/api/articles/", a)) return deleteArticle(req, res, a);
    sendError(res, 404, "not found");
}

// ---------------------------------------------------------------------------
// responses

private void sendBody(HTTPServerResponse res, int status, const(char)[] body) @safe
{
    res.writeBody(cast(const(ubyte)[]) body, status, "application/json");
}

void sendError(HTTPServerResponse res, int status, const(char)[] message) @safe
{
    auto b = JsonBuf.init;
    b.put(`{"errors":{"body":[`);
    b.putJsonString(message);
    b.put(`]}}`);
    sendBody(res, status, b[]);
}

private void sendNoContent(HTTPServerResponse res) @safe
{
    res.statusCode = 204;
    res.writeVoidBody();
}

// ---------------------------------------------------------------------------
// auth

private struct Viewer
{
    long id;
    const(char)[] token;
    bool present;
}

/// Reads the Authorization header and verifies the token. The signature and exp
/// are checked on every request.
private Viewer viewerOf(HTTPServerRequest req) @safe
{
    auto h = "Authorization" in req.headers;
    if (h is null) return Viewer(0, null, false);
    const(char)[] scheme = "Token ";
    if ((*h).length <= scheme.length || (*h)[0 .. scheme.length] != scheme)
        return Viewer(0, null, true);
    const(char)[] tok = (*h)[scheme.length .. $];
    long id;
    if (!verifyToken(tok, id)) return Viewer(0, null, true);
    return Viewer(id, tok, true);
}

/// True when the request presents a valid token; otherwise a 401 is written.
private bool requireAuth(HTTPServerResponse res, HTTPServerRequest req, out long viewer,
        out const(char)[] token) @safe
{
    auto v = viewerOf(req);
    viewer = v.id;
    token = v.token;
    if (!v.present || v.id == 0) {
        sendError(res, 401, "unauthorized");
        return false;
    }
    return true;
}

/// True when the request is anonymous or presents a valid token.
private bool optionalAuth(HTTPServerResponse res, HTTPServerRequest req, out long viewer) @safe
{
    auto v = viewerOf(req);
    viewer = v.id;
    if (v.present && v.id == 0) {
        sendError(res, 401, "unauthorized");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// request bodies

/// Reads the wrapper object of a request body (for example `{"user": {...}}`),
/// or writes a 422 and returns false.
private bool readWrapper(HTTPServerResponse res, HTTPServerRequest req, const(char)[] wrapper,
        out const(char)[] inner) @safe
{
    string body;
    try body = req.bodyReader.readAllUTF8();
    catch (Exception e) {
        logDebug("failed to read request body: %s", e.msg);
        sendError(res, 422, "invalid body");
        return false;
    }
    if (!findWrapper(body, wrapper, inner)) {
        sendError(res, 422, "invalid body");
        return false;
    }
    return true;
}

/// A string member's raw value, "missing" when absent or null.
private enum Field
{
    missing,
    nullValue,
    text,
    other
}

private Field field(const(char)[] object, const(char)[] key, out const(char)[] raw) @safe
{
    auto o = JsonObject.init;
    if (!o.parseObject(object)) return Field.other;
    Member m;
    while (o.next(m)) {
        if (m.name == key) {
            raw = m.value;
            switch (kindOf(raw)) {
                case JsonKind.text: return Field.text;
                case JsonKind.nullValue: return Field.nullValue;
                default: return Field.other;
            }
        }
    }
    return Field.missing;
}

/// A required non-empty string member, or 422.
private bool requiredString(HTTPServerResponse res, const(char)[] object, const(char)[] key,
        out Appender!(char[]) value) @safe
{
    const(char)[] raw;
    immutable f = field(object, key, raw);
    if (f != Field.text || raw.length == 2) {
        sendError(res, 422, key ~ " must be a non-empty string");
        return false;
    }
    if (!decodeString(raw, value)) {
        sendError(res, 422, key ~ " must be a non-empty string");
        return false;
    }
    return true;
}

/// An optional string member: absent or null leaves it unset, a string sets it,
/// anything else is a 422.
private bool optionalString(HTTPServerResponse res, const(char)[] object, const(char)[] key,
        bool nonEmpty, out bool present, out Appender!(char[]) value) @safe
{
    const(char)[] raw;
    immutable f = field(object, key, raw);
    if (f == Field.missing || f == Field.nullValue) {
        present = false;
        return true;
    }
    if (f != Field.text || (nonEmpty && raw.length == 2)) {
        sendError(res, 422, key ~ " must be a non-empty string");
        return false;
    }
    if (!decodeString(raw, value)) {
        sendError(res, 422, key ~ " must be a non-empty string");
        return false;
    }
    present = true;
    return true;
}

/// Runs a statement whose unique violations (a taken username or email) are a
/// 422. `ok` is false when the response was already written.
private Answer execOrTaken(HTTPServerResponse res, QueryParams p, out bool ok) @trusted
{
    try {
        ok = true;
        return g_db.exec(p);
    } catch (Exception e) {
        ok = false;
        if (isDuplicate(e)) {
            sendError(res, 422, "username or email is already taken");
            return null;
        }
        throw e;
    }
}

/// True when a statement failed on a unique constraint (SPEC.md: 422).
private bool isDuplicate(Exception e) @trusted
{
    auto re = cast(ResponseException) e;
    if (re is null) return false;
    try {
        return re.result.resultErrorField('C') == "23505";
    } catch (Exception) {
        return false;
    }
}

// ---------------------------------------------------------------------------
// pages

/// Parses limit (default 20, 1..100) and offset (default 0, >= 0).
private bool pageArgs(HTTPServerResponse res, HTTPServerRequest req, out long limit,
        out long offset) @safe
{
    limit = 20;
    offset = 0;
    auto q = req.query;
    if (auto pv = "limit" in q) {
        if (!parseDigits(*pv, limit) || limit < 1 || limit > 100) {
            sendError(res, 422, "limit must be an integer 1..100");
            return false;
        }
    }
    if (auto pv = "offset" in q) {
        if (!parseDigits(*pv, offset) || offset < 0) {
            sendError(res, 422, "offset must be an integer >= 0");
            return false;
        }
    }
    return true;
}

/// ASCII digits only, no sign, no spaces, fitting in a long.
private bool parseDigits(const(char)[] s, out long value) pure nothrow @safe
{
    value = 0;
    if (s.length == 0 || s.length > 18) return false;
    long v;
    foreach (c; s) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (c - '0');
    }
    value = v;
    return true;
}

// ---------------------------------------------------------------------------
// JSON helpers for rows

/// Writes a nullable text column as `null` or a JSON string.
private void putNullable(ref JsonBuf b, immutable(Row) row, size_t col) @trusted
{
    auto v = row[col];
    if (v.isNull) {
        b.putNull();
        return;
    }
    b.putJsonString(cast(const(char)[]) v.data);
}

private void putText(ref JsonBuf b, immutable(Row) row, size_t col) @trusted
{
    b.putJsonString(cast(const(char)[]) row[col].data);
}

private void putTimestamp(ref JsonBuf b, immutable(Row) row, size_t col) @trusted
{
    auto t = cast(const(char)[]) row[col].data;
    if (t.length < 19 || t[10] != ' ') {
        // Not a timestamptz rendering: keep the response well-formed.
        b.putJsonString(t);
        return;
    }
    b.putByte('"');
    b.putTimestamp(t);
    b.putByte('"');
}

private void putBool(ref JsonBuf b, immutable(Row) row, size_t col) @trusted
{
    auto t = cast(const(char)[]) row[col].data;
    b.putBool(t.length == 1 && t[0] == 't');
}

/// Writes a bigint column as a JSON integer (Postgres text digits).
private void putIntColumn(ref JsonBuf b, immutable(Row) row, size_t col) @trusted
{
    b.put(cast(const(char)[]) row[col].data);
}

private void putArray(ref JsonBuf b, immutable(Row) row, size_t col) @trusted
{
    // Postgres renders an empty ARRAY(...) as "{}", but a changed query could
    // return NULL, and an article's tag list is an array either way.
    auto v = row[col];
    if (v.isNull) {
        b.put("[]");
        return;
    }
    b.putStringArray(cast(const(char)[]) v.data);
}

/// The author object shared by articles and comments.
private void putProfile(ref JsonBuf b, immutable(Row) row, size_t usernameCol) @trusted
{
    b.put(`{"username":`);
    putText(b, row, usernameCol);
    b.put(`,"bio":`);
    putNullable(b, row, usernameCol + 1);
    b.put(`,"image":`);
    putNullable(b, row, usernameCol + 2);
    b.put(`,"following":`);
    putBool(b, row, usernameCol + 3);
    b.putByte('}');
}

// ---------------------------------------------------------------------------
// users

/// POST /api/users
private void sendRegister(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    const(char)[] inner;
    if (!readWrapper(res, req, "user", inner)) return;

    auto username = appender!(char[]);
    auto email = appender!(char[]);
    auto password = appender!(char[]);
    if (!requiredString(res, inner, "username", username)) return;
    if (!requiredString(res, inner, "email", email)) return;
    if (!requiredString(res, inner, "password", password)) return;

    auto hash = hashPassword(password.data);
    if (hash is null) {
        sendError(res, 422, "password is too long");
        return;
    }

    bool ok;
    auto ans = execOrTaken(res, params(Name.insertUser, username.data, email.data, hash), ok);
    if (!ok) return;
    if (ans.length != 1) {
        sendError(res, 500, "internal error");
        return;
    }
    immutable id = parseId(ans[0]);

    auto b = JsonBuf.init;
    b.put(`{"user":{"username":`);
    putText(b, ans[0], 1);
    b.put(`,"email":`);
    putText(b, ans[0], 2);
    b.put(`,"bio":`);
    putNullable(b, ans[0], 3);
    b.put(`,"image":`);
    putNullable(b, ans[0], 4);
    b.put(`,"token":`);
    b.putJsonString(issueToken(id, nowUnix()));
    b.put(`}}`);
    sendBody(res, 201, b[]);
}

/// POST /api/users/login
private void sendLogin(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    const(char)[] inner;
    if (!readWrapper(res, req, "user", inner)) return;

    auto email = appender!(char[]);
    auto password = appender!(char[]);
    if (!requiredString(res, inner, "email", email)) return;
    if (!requiredString(res, inner, "password", password)) return;

    auto ans = g_db.exec(params(Name.userByEmail, email.data));
    if (ans.length == 0) {
        sendError(res, 401, "invalid email or password");
        return;
    }
    immutable row = ans[0];
    const(char)[] stored = cast(const(char)[]) row[5].data;
    if (!verifyPassword(password.data, stored)) {
        sendError(res, 401, "invalid email or password");
        return;
    }
    immutable id = parseId(row);

    auto b = JsonBuf.init;
    b.put(`{"user":{"username":`);
    putText(b, row, 1);
    b.put(`,"email":`);
    putText(b, row, 2);
    b.put(`,"bio":`);
    putNullable(b, row, 3);
    b.put(`,"image":`);
    putNullable(b, row, 4);
    b.put(`,"token":`);
    b.putJsonString(issueToken(id, nowUnix()));
    b.put(`}}`);
    sendBody(res, 200, b[]);
}

/// GET /api/user
private void sendCurrentUser(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    auto ans = g_db.exec(params(Name.userById, viewer));
    if (ans.length == 0) {
        sendError(res, 401, "unauthorized");
        return;
    }
    auto b = JsonBuf.init;
    b.put(`{"user":{"username":`);
    putText(b, ans[0], 1);
    b.put(`,"email":`);
    putText(b, ans[0], 2);
    b.put(`,"bio":`);
    putNullable(b, ans[0], 3);
    b.put(`,"image":`);
    putNullable(b, ans[0], 4);
    b.put(`,"token":`);
    b.putJsonString(token);
    b.put(`}}`);
    sendBody(res, 200, b[]);
}

/// PUT /api/user
private void updateUser(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    const(char)[] inner;
    if (!readWrapper(res, req, "user", inner)) return;

    auto email = appender!(char[]);
    auto username = appender!(char[]);
    auto password = appender!(char[]);
    auto bio = appender!(char[]);
    auto image = appender!(char[]);
    bool haveEmail, haveUsername, havePassword, haveBio, haveImage;
    if (!optionalString(res, inner, "email", true, haveEmail, email)) return;
    if (!optionalString(res, inner, "username", true, haveUsername, username)) return;
    if (!optionalString(res, inner, "password", true, havePassword, password)) return;
    if (!optionalString(res, inner, "bio", false, haveBio, bio)) return;
    if (!optionalString(res, inner, "image", false, haveImage, image)) return;

    string hash = null;
    if (havePassword) {
        hash = hashPassword(password.data);
        if (hash is null) {
            sendError(res, 422, "password is too long");
            return;
        }
    }

    bool ok;
    auto ans = execOrTaken(res, params(Name.updateUser, viewer,
            haveEmail ? someText(email.data) : noText,
            haveUsername ? someText(username.data) : noText,
            havePassword ? someText(hash) : noText,
            haveBio ? someText(bio.data) : noText,
            haveImage ? someText(image.data) : noText), ok);
    if (!ok) return;
    if (ans.length != 1) {
        sendError(res, 401, "unauthorized");
        return;
    }

    auto b = JsonBuf.init;
    b.put(`{"user":{"username":`);
    putText(b, ans[0], 1);
    b.put(`,"email":`);
    putText(b, ans[0], 2);
    b.put(`,"bio":`);
    putNullable(b, ans[0], 3);
    b.put(`,"image":`);
    putNullable(b, ans[0], 4);
    b.put(`,"token":`);
    b.putJsonString(token);
    b.put(`}}`);
    sendBody(res, 200, b[]);
}

/// A set argument for the COALESCE(...) updates. The cast only drops `const`,
/// because the driver reads the value while the query runs.
private Nullable!string someText(const(char)[] s) @trusted
{
    return Nullable!string(cast(string) s);
}

/// An absent argument for the COALESCE(...) updates.
private Nullable!string noText()
{
    return Nullable!string.init;
}

// ---------------------------------------------------------------------------
// profiles

/// GET /api/profiles/:username
private void sendProfile(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] username)
@trusted
{
    long viewer;
    if (!optionalAuth(res, req, viewer)) return;

    auto ans = g_db.exec(params(Name.profile, viewer, username));
    if (ans.length == 0) {
        sendError(res, 404, "profile not found");
        return;
    }
    auto b = JsonBuf.init;
    b.put(`{"profile":{`);
    // same shape as an article's author
    b.put(`"username":`);
    putText(b, ans[0], 1);
    b.put(`,"bio":`);
    putNullable(b, ans[0], 2);
    b.put(`,"image":`);
    putNullable(b, ans[0], 3);
    b.put(`,"following":`);
    putBool(b, ans[0], 4);
    b.put(`}}`);
    sendBody(res, 200, b[]);
}

/// POST and DELETE /api/profiles/:username/follow
private void followProfile(scope HTTPServerRequest req, scope HTTPServerResponse res,
        const(char)[] username, bool follow)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    auto ans = g_db.exec(params(Name.userByUsername, username));
    if (ans.length == 0) {
        sendError(res, 404, "profile not found");
        return;
    }
    immutable followee = parseId(ans[0]);

    if (follow)
        g_db.exec(params(Name.insertFollow, viewer, followee));
    else
        g_db.exec(params(Name.deleteFollow, viewer, followee));

    auto b = JsonBuf.init;
    b.put(`{"profile":{"username":`);
    putText(b, ans[0], 1);
    b.put(`,"bio":`);
    putNullable(b, ans[0], 2);
    b.put(`,"image":`);
    putNullable(b, ans[0], 3);
    b.put(`,"following":`);
    b.putBool(follow);
    b.put(`}}`);
    sendBody(res, 200, b[]);
}

// ---------------------------------------------------------------------------
// articles

private enum ListKind
{
    all,
    tag,
    author,
    favorited
}

/// GET /api/articles
private void sendArticleList(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    long viewer;
    if (!optionalAuth(res, req, viewer)) return;

    long limit, offset;
    if (!pageArgs(res, req, limit, offset)) return;

    // SPEC.md: "If more than one is given, only the first in that order applies",
    // and an empty value counts as not given.
    auto q = req.query;
    ListKind kind = ListKind.all;
    const(char)[] filter;
    if (auto pv = "tag" in q) {
        filter = *pv;
        kind = ListKind.tag;
    }
    if (filter.length == 0) {
        if (auto pv = "author" in q) {
            filter = *pv;
            kind = ListKind.author;
        }
    }
    if (filter.length == 0) {
        if (auto pv = "favorited" in q) {
            filter = *pv;
            kind = ListKind.favorited;
        }
    }
    if (filter.length == 0) kind = ListKind.all;

    auto pCount = params(Name.countAll);
    auto pList = params(Name.listAll, viewer, limit, offset);
    final switch (kind) {
    case ListKind.all:
        break;
    case ListKind.tag:
        pCount = params(Name.countByTag, filter);
        pList = params(Name.listByTag, viewer, limit, offset, filter);
        break;
    case ListKind.author:
        pCount = params(Name.countByAuthor, filter);
        pList = params(Name.listByAuthor, viewer, limit, offset, filter);
        break;
    case ListKind.favorited:
        pCount = params(Name.countByFavorite, filter);
        pList = params(Name.listByFavorite, viewer, limit, offset, filter);
        break;
    }

    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    auto pair = g_db.execPair(pList, pCount);
    b.put(`{"articles":`);
    appendListRows(b, pair.a);
    b.put(`,"articlesCount":`);
    appendCountRows(b, pair.b);
    b.putByte('}');
    sendBody(res, 200, b[]);
}

/// GET /api/articles/feed
private void sendFeed(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    long limit, offset;
    if (!pageArgs(res, req, limit, offset)) return;

    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    auto pair = g_db.execPair(params(Name.listFeed, viewer, limit, offset),
            params(Name.countFeed, viewer));
    b.put(`{"articles":`);
    appendListRows(b, pair.a);
    b.put(`,"articlesCount":`);
    appendCountRows(b, pair.b);
    b.putByte('}');
    sendBody(res, 200, b[]);
}

/// GET /api/articles/:slug
private void sendArticle(scope HTTPServerRequest req, scope HTTPServerResponse res,
        const(char)[] slug)
@trusted
{
    long viewer;
    if (!optionalAuth(res, req, viewer)) return;

    auto ans = g_db.exec(params(Name.articleBySlug, viewer, slug));
    if (ans.length == 0) {
        sendError(res, 404, "article not found");
        return;
    }
    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    b.put(`{"article":`);
    appendArticle(b, ans[0], true);
    b.putByte('}');
    sendBody(res, 200, b[]);
}

private void appendArticle(ref JsonBuf b, immutable(Row) row, bool withBody) @trusted
{
    b.put(`{"slug":`);
    putText(b, row, 1);
    b.put(`,"title":`);
    putText(b, row, 2);
    b.put(`,"description":`);
    putText(b, row, 3);
    if (withBody) {
        b.put(`,"body":`);
        putText(b, row, 4);
    }
    b.put(`,"tagList":`);
    putArray(b, row, withBody ? 7 : 6);
    b.put(`,"createdAt":`);
    putTimestamp(b, row, withBody ? 5 : 4);
    b.put(`,"updatedAt":`);
    putTimestamp(b, row, withBody ? 6 : 5);
    b.put(`,"favorited":`);
    putBool(b, row, withBody ? 9 : 8);
    b.put(`,"favoritesCount":`);
    putIntColumn(b, row, withBody ? 8 : 7);
    b.put(`,"author":`);
    putProfile(b, row, withBody ? 10 : 9);
    b.putByte('}');
}

/// Writes the list endpoint's "articles" array.
private void appendListRows(ref JsonBuf b, immutable(Answer) ans) @trusted
{
    b.putByte('[');
    foreach (i; 0 .. ans.length) {
        if (i) b.putByte(',');
        appendArticle(b, ans[i], false);
    }
    b.putByte(']');
}

/// Writes a list endpoint's "articlesCount".
private void appendCountRows(ref JsonBuf b, immutable(Answer) ans) @trusted
{
    if (ans.length == 1) putIntColumn(b, ans[0], 0);
    else b.putInt(0);
}

/// POST /api/articles
private void createArticle(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    const(char)[] inner;
    if (!readWrapper(res, req, "article", inner)) return;

    auto title = appender!(char[]);
    auto description = appender!(char[]);
    auto body = appender!(char[]);
    if (!requiredString(res, inner, "title", title)) return;
    if (!requiredString(res, inner, "description", description)) return;
    if (!requiredString(res, inner, "body", body)) return;

    // tagList is optional; when present it must be an array of non-empty strings.
    string[] tags;
    {
        const(char)[] raw;
        auto f = field(inner, "tagList", raw);
        if (f != Field.missing) {
            if (f == Field.nullValue) {
                // null tagList: no tags
            } else {
                if (kindOf(raw) != JsonKind.array) {
                    sendError(res, 422, "tagList must be an array of non-empty strings");
                    return;
                }
                auto arr = JsonArray(raw);
                while (true) {
                    const(char)[] item;
                    if (!arr.next(item)) break;
                    if (kindOf(item) != JsonKind.text || item.length == 2) {
                        sendError(res, 422, "tagList must be an array of non-empty strings");
                        return;
                    }
                    auto t = appender!(char[]);
                    if (!decodeString(item, t)) {
                        sendError(res, 422, "tagList must be an array of non-empty strings");
                        return;
                    }
                    tags ~= t.data.idup;
                }
            }
        }
    }

    // The slug is SLUGIFY(title) || '-' || id: the title is slugified here so that
    // Postgres never runs a regexp_replace, and the id is appended in SQL.
    auto slug = appender!(char[]);
    slugify(title.data, slug);

    immutable id = insertArticle(viewer, slug.data, title.data, description.data, body.data, tags);
    if (id == 0) {
        sendError(res, 500, "internal error");
        return;
    }

    auto ans = g_db.exec(params(Name.articleById, viewer, id));
    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    b.put(`{"article":`);
    appendArticle(b, ans[0], true);
    b.putByte('}');
    sendBody(res, 201, b[]);
}

/// Inserts the article, its tags and its tag links in one statement (one implicit
/// transaction), and returns the new article id.
private long insertArticle(long viewer, const(char)[] slug, const(char)[] title,
        const(char)[] description, const(char)[] body, string[] tags) @trusted
{
    auto ans = g_db.exec(params(Name.insertArticle, slug, viewer, title, description, body, tags));
    if (ans.length != 1) return 0;
    return parseId(ans[0]);
}

/// POST and DELETE /api/articles/:slug/favorite
private void favoriteArticle(scope HTTPServerRequest req, scope HTTPServerResponse res,
        const(char)[] slug, bool favorite)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    auto ans = g_db.exec(params(Name.articleIdBySlug, slug));
    if (ans.length == 0) {
        sendError(res, 404, "article not found");
        return;
    }
    immutable id = parseId(ans[0]);

    if (favorite)
        g_db.exec(params(Name.insertFavorite, viewer, id));
    else
        g_db.exec(params(Name.deleteFavorite, viewer, id));

    auto full = g_db.exec(params(Name.articleById, viewer, id));
    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    b.put(`{"article":`);
    appendArticle(b, full[0], true);
    b.putByte('}');
    sendBody(res, 200, b[]);
}

/// PUT /api/articles/:slug
private void updateArticle(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] slug)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    const(char)[] inner;
    if (!readWrapper(res, req, "article", inner)) return;

    auto title = appender!(char[]);
    auto description = appender!(char[]);
    auto body = appender!(char[]);
    bool haveTitle, haveDescription, haveBody;
    if (!optionalString(res, inner, "title", true, haveTitle, title)) return;
    if (!optionalString(res, inner, "description", true, haveDescription, description)) return;
    if (!optionalString(res, inner, "body", true, haveBody, body)) return;

    auto ans = g_db.exec(params(Name.articleOwner, slug));
    if (ans.length == 0) {
        sendError(res, 404, "article not found");
        return;
    }
    immutable row = ans[0];
    if (parseColumn(row, 1) != viewer) {
        sendError(res, 403, "not the author");
        return;
    }
    immutable id = parseId(row);

    // A new title changes the slug to SLUGIFY(title) || '-' || id, as in the
    // reference SQL.
    string newSlug;
    if (haveTitle) {
        auto s = appender!(char[]);
        slugify(title.data, s);
        s.put('-');
        s.put(id.to!string);
        newSlug = s.data.idup;
    }

    g_db.exec(params(Name.updateArticle, id,
            haveTitle ? someText(newSlug) : noText,
            haveTitle ? someText(title.data) : noText,
            haveDescription ? someText(description.data) : noText,
            haveBody ? someText(body.data) : noText));

    auto full = g_db.exec(params(Name.articleById, viewer, id));
    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    b.put(`{"article":`);
    appendArticle(b, full[0], true);
    b.putByte('}');
    sendBody(res, 200, b[]);
}

/// DELETE /api/articles/:slug
private void deleteArticle(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] slug)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    auto ans = g_db.exec(params(Name.articleOwner, slug));
    if (ans.length == 0) {
        sendError(res, 404, "article not found");
        return;
    }
    immutable row = ans[0];
    if (parseColumn(row, 1) != viewer) {
        sendError(res, 403, "not the author");
        return;
    }
    g_db.exec(params(Name.deleteArticle, parseId(row)));
    sendNoContent(res);
}

// ---------------------------------------------------------------------------
// comments

/// GET /api/articles/:slug/comments
private void sendComments(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] slug)
@trusted
{
    long viewer;
    if (!optionalAuth(res, req, viewer)) return;

    auto ids = g_db.exec(params(Name.articleIdBySlug, slug));
    if (ids.length == 0) {
        sendError(res, 404, "article not found");
        return;
    }
    immutable id = parseId(ids[0]);

    auto ans = g_db.exec(params(Name.commentsByArticle, viewer, id));
    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    b.put(`{"comments":[`);
    foreach (i; 0 .. ans.length) {
        if (i) b.putByte(',');
        auto row = ans[i];
        b.put(`{"id":`);
        putIntColumn(b, row, 0);
        b.put(`,"body":`);
        putText(b, row, 1);
        b.put(`,"createdAt":`);
        putTimestamp(b, row, 2);
        b.put(`,"updatedAt":`);
        putTimestamp(b, row, 3);
        b.put(`,"author":`);
        putProfile(b, row, 4);
        b.putByte('}');
    }
    b.put(`]}`);
    sendBody(res, 200, b[]);
}

/// POST /api/articles/:slug/comments
private void createComment(scope HTTPServerRequest req, scope HTTPServerResponse res, const(char)[] slug)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    const(char)[] inner;
    if (!readWrapper(res, req, "comment", inner)) return;
    auto body = appender!(char[]);
    if (!requiredString(res, inner, "body", body)) return;

    auto ids = g_db.exec(params(Name.articleIdBySlug, slug));
    if (ids.length == 0) {
        sendError(res, 404, "article not found");
        return;
    }
    immutable id = parseId(ids[0]);

    auto ans = g_db.exec(params(Name.insertComment, id, viewer, body.data));
    if (ans.length != 1) {
        sendError(res, 500, "internal error");
        return;
    }
    auto row = ans[0];
    auto b = JsonBuf.init;
    b.put(`{"comment":{"id":`);
    putIntColumn(b, row, 0);
    b.put(`,"body":`);
    putText(b, row, 1);
    b.put(`,"createdAt":`);
    putTimestamp(b, row, 2);
    b.put(`,"updatedAt":`);
    putTimestamp(b, row, 3);
    b.put(`,"author":`);
    // insertComment has no following column; write the author inline
    b.put(`{"username":`);
    putText(b, row, 4);
    b.put(`,"bio":`);
    putNullable(b, row, 5);
    b.put(`,"image":`);
    putNullable(b, row, 6);
    b.put(`,"following":false}`);
    b.put(`}}`);
    sendBody(res, 201, b[]);
}

/// DELETE /api/articles/:slug/comments/:id
private void deleteComment(scope HTTPServerRequest req, scope HTTPServerResponse res,
        const(char)[] slug, const(char)[] idText)
@trusted
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token)) return;

    long commentId;
    if (!parseDigits(idText, commentId)) {
        sendError(res, 404, "comment not found");
        return;
    }

    auto ans = g_db.exec(params(Name.commentOwner, commentId, slug));
    if (ans.length == 0) {
        sendError(res, 404, "comment not found");
        return;
    }
    if (parseColumn(ans[0], 0) != viewer) {
        sendError(res, 403, "not the author");
        return;
    }
    g_db.exec(params(Name.deleteComment, commentId));
    sendNoContent(res);
}

// ---------------------------------------------------------------------------
// tags

/// GET /api/tags
private void sendTags(scope HTTPServerRequest req, scope HTTPServerResponse res)
@trusted
{
    auto ans = g_db.exec(params(Name.tags));
    auto b = JsonBuf.init;
    b.reserve(4 * 1024);
    b.put(`{"tags":[`);
    foreach (i; 0 .. ans.length) {
        if (i) b.putByte(',');
        putText(b, ans[i], 0);
    }
    b.put(`]}`);
    sendBody(res, 200, b[]);
}

// ---------------------------------------------------------------------------
// row helpers

private long parseId(immutable(Row) row) @trusted
{
    return parseColumn(row, 0);
}

private long parseColumn(immutable(Row) row, size_t col) @trusted
{
    auto v = row[col];
    auto text = cast(const(char)[]) v.data;
    long n = 0;
    foreach (c; text)
        if (c >= '0' && c <= '9') n = n * 10 + (c - '0');
    return n;
}

// ---------------------------------------------------------------------------
// slugify

/// SLUGIFY(x): trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))
/// Postgres works on characters; working on bytes gives the same output because a
/// multi-byte character's bytes are all non-alphanumeric and are collapsed into
/// one '-' either way.
private void slugify(const(char)[] s, ref Appender!(char[]) sink) @safe
{
    ptrdiff_t start = 0, end = cast(ptrdiff_t) s.length;
    while (start < end && !isAlnum(s[cast(size_t) start])) start++;
    while (end > start && !isAlnum(s[cast(size_t)(end - 1)])) end--;

    bool pendingDash = false;
    foreach (i; cast(size_t) start .. cast(size_t) end) {
        immutable c = s[i];
        if (isAlnum(c)) {
            if (pendingDash) {
                sink.put('-');
                pendingDash = false;
            }
            sink.put(c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c);
        } else {
            pendingDash = true;
        }
    }
}

private bool isAlnum(char c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z';
}

// ---------------------------------------------------------------------------
// misc

private long nowUnix() @trusted nothrow
{
    import std.datetime : Clock, UTC;

    return cast(long) Clock.currTime(UTC()).toUnixTime();
}

@safe unittest
{
    import std.format : format;

    // slugify must match Postgres's SLUGIFY byte for byte
    static void check(string s, string want)
    {
        auto out_ = appender!(char[]);
        slugify(s, out_);
        assert(out_.data == want, format!"sluggify(%s) = %s, want %s"(s, out_.data, want));
    }

    check("Hello, World! 2026", "hello-world-2026");
    check("  Conformance -- Renamed Title!  ", "conformance-renamed-title");
    check("abc", "abc");
    check("---", "");
    check("", "");
    check("Ünïcode Tëst", "n-code-t-st");
    check("a__b", "a-b");
    check("MiXeD CaSe", "mixed-case");
}
