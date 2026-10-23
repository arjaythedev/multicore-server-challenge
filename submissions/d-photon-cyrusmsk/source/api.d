/// The 19 Conduit endpoints (SPEC.md), served through photon-http.
///
/// Every handler reads its rows from Postgres while it is being served: no
/// response caches, no query caches, no in-memory table copies, no remembered
/// verifications. Responses are typed structs serialized by mir-ion and
/// written with `respondWith`, which sets `Content-Length` on the way out.
module conduit.api;

import photon.http : HttpHeader, HttpMethod, HttpProcessor, HttpRequest;
import std.socket : Socket;

import mir.algebraic : Algebraic;
import mir.deser.json : deserializeJson;
import mir.serde : serdeIgnoreUnexpectedKeys, serdeOptional;
import mir.ser.json : serializeJson;

import std.array : Appender;
import std.string : indexOf;

import conduit.auth;
import conduit.bcrypt;
import conduit.db;
import conduit.diag : logError;

import core.atomic : atomicStore;
import core.time : MonoTime;

import dpq2.args : QueryParams;
import dpq2.value : Value;
import dpq2.result : Answer, Row, asArray, ResponseException;
import dpq2.conv.to_d_types : as;

import std.datetime : SysTime;
import std.format : format;
import std.typecons : Nullable;

/// A nullable string in responses: `Algebraic` serializes `null`, whereas
/// `Nullable!string` would serialize as `""`.
alias MaybeString = Algebraic!(string, typeof(null));

/// The database pool of the worker thread that serves this request. A
/// connection belongs to the thread that opened it, so each thread sets its
/// own pool once, in `workerMain`.
static Db pool;

/// Called once per worker thread, from that thread.
void setPool(Db db) nothrow
{
    pool = db;
}

// ---------------------------------------------------------------------------
// photon-http request/response adapters

/// Request bodies are deserialized straight into these typed structs by
/// mir-ion: no JSON DOM, and a type error is a 422.
@serdeIgnoreUnexpectedKeys
private struct UserPayload
{
    string username;
    string email;
    string password;
}

@serdeIgnoreUnexpectedKeys
private struct UserBody
{
    UserPayload user;
}

@serdeIgnoreUnexpectedKeys
private struct LoginPayload
{
    string email;
    string password;
}

@serdeIgnoreUnexpectedKeys
private struct LoginBody
{
    LoginPayload user;
}

@serdeIgnoreUnexpectedKeys
private struct UpdateUserPayload
{
    @serdeOptional Nullable!string email;
    @serdeOptional Nullable!string username;
    @serdeOptional Nullable!string password;
    @serdeOptional Nullable!string bio;
    @serdeOptional Nullable!string image;
}

@serdeIgnoreUnexpectedKeys
private struct UpdateUserBody
{
    UpdateUserPayload user;
}

@serdeIgnoreUnexpectedKeys
private struct ArticlePayload
{
    string title;
    string description;
    string body;
    @serdeOptional string[] tagList;
}

@serdeIgnoreUnexpectedKeys
private struct ArticleBody
{
    ArticlePayload article;
}

@serdeIgnoreUnexpectedKeys
private struct UpdateArticlePayload
{
    @serdeOptional Nullable!string title;
    @serdeOptional Nullable!string description;
    @serdeOptional Nullable!string body;
}

@serdeIgnoreUnexpectedKeys
private struct UpdateArticleBody
{
    UpdateArticlePayload article;
}

@serdeIgnoreUnexpectedKeys
private struct CommentPayload
{
    string body;
}

@serdeIgnoreUnexpectedKeys
private struct CommentBody
{
    CommentPayload comment;
}

private bool readBody(T)(HTTPServerRequest req, HTTPServerResponse res, out T value)
{
    try
        value = deserializeJson!T(req.bodyText);
    catch (Exception)
    {
        writeError(res, 422, "invalid body");
        return false;
    }
    return true;
}

private struct HTTPServerRequest
{
    HttpMethod method;
    const(char)[] path;
    const(char)[][const(char)[]] query;
    const(char)[][string] params;
    HttpHeader[] headers;
    const(char)[] body;

    @property const(char)[] bodyText() const
    {
        return body;
    }
}

private HttpHeader[] jsonHeaders = [
    HttpHeader("Content-Type", "application/json; charset=utf-8"),
];

/// Thread-local scratch, reset at the start of every request. Slices handed to
/// the serializer point here and are consumed before the next request runs.
private Appender!(char[]) jsonBuffer;
private char[16_384] tsBuffer;
private size_t tsUsed;
private string[1024] tagBuffer;
private size_t tagUsed;

private void resetRequestArenas()
{
    tsUsed = 0;
    tagUsed = 0;
}

/// A response's slices are built and serialized in one synchronous segment.
/// Reset the cursor after the last await so an older in-flight handler cannot
/// push this request's writes past the arena.
private void beginResponse()
{
    tsUsed = 0;
    tagUsed = 0;
}

private final class HTTPServerResponse
{
    private HttpProcessor processor;
    private int status = 200;
    private bool written;

    this(HttpProcessor processor)
    {
        this.processor = processor;
    }

    void writeJsonBody(T)(T body, int status, bool chunked)
    {
        jsonBuffer.clear();
        serializeJson(jsonBuffer, body);
        processor.respondWith(jsonBuffer.data, status, jsonHeaders);
        written = true;
    }

    void reset()
    {
        status = 200;
        written = false;
    }

    @property void statusCode(int code)
    {
        status = code;
    }

    @property bool headerWritten() const
    {
        return written;
    }

    void writeVoidBody()
    {
        respond("", status);
    }

    private void respond(const(char)[] body, int code)
    {
        processor.respondWith(body, code, jsonHeaders);
        written = true;
    }
}

/// Case-insensitive header lookup; photon-http keeps the original spelling.
/// The returned slice lives in the request buffers, so it is valid for `handle`.
private const(char)[] headerValue(const HTTPServerRequest req, string name)
{
    foreach (ref header; req.headers)
        if (ieq(header.key, name))
            return header.value;
    return null;
}

private bool ieq(const(char)[] a, const(char)[] b) pure nothrow @safe
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char ca = a[i];
        char cb = b[i];
        if (ca >= 'A' && ca <= 'Z')
            ca += 'a' - 'A';
        if (cb >= 'A' && cb <= 'Z')
            cb += 'a' - 'A';
        if (ca != cb)
            return false;
    }
    return true;
}

/// Percent-decodes a path segment or query value. `+` means space only in a
/// form-encoded query; in a path it is a literal plus. Text with no escape
/// sequence is returned as a slice of the request buffer.
private const(char)[] decodeComponent(const(char)[] text, bool plusIsSpace = true)
{
    bool needsDecode;
    foreach (c; text)
        if (c == '%' || (plusIsSpace && c == '+'))
        {
            needsDecode = true;
            break;
        }
    if (!needsDecode)
        return text;

    char[] out_;
    out_.reserve(text.length);
    for (size_t i = 0; i < text.length; ++i)
    {
        const c = text[i];
        if (c == '+' && plusIsSpace)
            out_ ~= ' ';
        else if (c == '%' && i + 2 < text.length)
        {
            const hi = hexValue(text[i + 1]);
            const lo = hexValue(text[i + 2]);
            if (hi >= 0 && lo >= 0)
            {
                out_ ~= cast(char)(hi * 16 + lo);
                i += 2;
            }
            else
                out_ ~= c;
        }
        else
            out_ ~= c;
    }
    return out_.idup;
}

private const(char)[] decodePath(const(char)[] text)
{
    return decodeComponent(text, false);
}

/// Reinterprets a request-lifetime slice as a `string` for dpq2. libpq copies
/// the bytes while the query is sent, before `handle` returns.
private string dbArg(const(char)[] text) @trusted
{
    return cast(string) text;
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

private const(char)[][const(char)[]] parseQuery(const(char)[] text)
{
    const(char)[][const(char)[]] result;
    size_t start;
    while (start <= text.length)
    {
        size_t end = start;
        while (end < text.length && text[end] != '&')
            ++end;
        const pair = text[start .. end];
        if (pair.length)
        {
            const eq = pair.indexOf('=');
            const key = eq < 0 ? pair : pair[0 .. eq];
            const value = eq < 0 ? pair[0 .. 0] : pair[eq + 1 .. $];
            result[decodeComponent(key)] = decodeComponent(value);
        }
        if (end == text.length)
            break;
        start = end + 1;
    }
    return result;
}

/// Splits a path on `/` into a fixed buffer. Deeper paths return the buffer
/// length and match no route.
private size_t splitPath(const(char)[] path, out const(char)[][8] segments)
{
    if (path.length == 0 || path[0] != '/')
    {
        segments[0] = path;
        return 1;
    }
    size_t n = 1;
    size_t start = 1;
    segments[0] = path[0 .. 0];
    foreach (i; 1 .. path.length)
    {
        if (path[i] == '/')
        {
            if (n == segments.length)
                return segments.length;
            segments[n++] = path[start .. i];
            start = i + 1;
        }
    }
    if (n == segments.length)
        return segments.length;
    segments[n++] = path[start .. $];
    return n;
}

/// Struct responses serialize directly, without a JSON DOM in between.
private void writeJson(T)(HTTPServerResponse res, int status, T body)
{
    res.writeJsonBody(body, status, true);
}

private struct ErrorList
{
    string[] body;
}

private struct ErrorResponse
{
    ErrorList errors;
}

private void writeError(HTTPServerResponse res, int status, string message)
{
    writeJson(res, status, ErrorResponse(ErrorList([message])));
}

private void writeNoContent(HTTPServerResponse res)
{
    res.statusCode = 204;
    res.writeVoidBody();
}

/// Runs a statement on a pooled connection; the connection is returned to the
/// pool before the answer is used, which is fine: the answer owns its data.
private Answer execOne(QueryParams params)
{
    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    return conn.execPrepared(params);
}

// ---------------------------------------------------------------------------
// auth

private struct Viewer
{
    long id;
    const(char)[] token;
    bool present;
}

/// Reads the `Authorization` header and verifies the token: HS256 signature
/// and `exp`, checked on every request.
private Viewer viewerOf(HTTPServerRequest req)
{
    auto header = headerValue(req, "Authorization");
    if (header is null)
        return Viewer(0, null, false);
    if (header.length <= 6 || header[0 .. 6] != "Token ")
        return Viewer(0, null, true);
    const token = header[6 .. $];
    long id;
    if (!verifyToken(token, id))
        return Viewer(0, null, true);
    return Viewer(id, token, true);
}

/// A missing or invalid token is a 401.
private bool requireAuth(HTTPServerResponse res, HTTPServerRequest req, out long viewer, out const(char)[] token)
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

/// A required non-empty string, or 422.
private bool reqString(HTTPServerResponse res, string value, string name)
{
    if (value.length == 0)
    {
        writeError(res, 422, name ~ " must be a non-empty string");
        return false;
    }
    return true;
}

/// An optional string: null (or absent) leaves it unset, a string sets it.
private bool optString(HTTPServerResponse res, Nullable!string source, string name,
        bool nonEmpty, out bool present, out string value)
{
    present = !source.isNull;
    if (present)
    {
        value = source.get;
        if (nonEmpty && value.length == 0)
        {
            writeError(res, 422, name ~ " must be a non-empty string");
            return false;
        }
    }
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
    if (s.length == 0)
        return false;
    ulong parsed;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        const digit = cast(ulong)(c - '0');
        if (parsed > (cast(ulong) long.max - digit) / 10)
            return false;
        parsed = parsed * 10 + digit;
    }
    value = cast(long) parsed;
    return true;
}

// ---------------------------------------------------------------------------
// rows to JSON

/// Writes a two-digit decimal field.
private void put2(char[] out_, size_t pos, int value)
{
    out_[pos] = cast(char)('0' + (value / 10) % 10);
    out_[pos + 1] = cast(char)('0' + value % 10);
}

/// Writes a four-digit decimal field.
private void put4(char[] out_, size_t pos, int value)
{
    out_[pos] = cast(char)('0' + (value / 1000) % 10);
    out_[pos + 1] = cast(char)('0' + (value / 100) % 10);
    out_[pos + 2] = cast(char)('0' + (value / 10) % 10);
    out_[pos + 3] = cast(char)('0' + value % 10);
}

/// A UTC timestamp as SPEC.md wants it: RFC 3339, exactly 3 fractional digits.
private string formatTs(SysTime time)
{
    auto utc = time.toUTC();
    if (tsUsed + 24 > tsBuffer.length)
        return format!"%04d-%02d-%02dT%02d:%02d:%02d.%03dZ"(
            utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second,
            utc.fracSecs.total!"msecs");

    const start = tsUsed;
    auto out_ = tsBuffer[start .. start + 24];
    put4(out_, 0, utc.year);
    out_[4] = '-';
    put2(out_, 5, utc.month);
    out_[7] = '-';
    put2(out_, 8, utc.day);
    out_[10] = 'T';
    put2(out_, 11, utc.hour);
    out_[13] = ':';
    put2(out_, 14, utc.minute);
    out_[16] = ':';
    put2(out_, 17, utc.second);
    out_[19] = '.';
    const millis = cast(int) utc.fracSecs.total!"msecs";
    out_[20] = cast(char)('0' + (millis / 100) % 10);
    out_[21] = cast(char)('0' + (millis / 10) % 10);
    out_[22] = cast(char)('0' + millis % 10);
    out_[23] = 'Z';
    tsUsed += 24;
    return cast(string) out_;
}

/// A text cell as a slice of the answer: no copy. The answer outlives the
/// response being written, so the slice is always valid.
private string cellText(immutable(Value) cell) @trusted
{
    return cast(string) cell.data;
}

private MaybeString cellNullable(immutable(Value) cell) @trusted
{
    return cell.isNull ? MaybeString(null) : MaybeString(cast(string) cell.data);
}

// Responses are typed structs holding slices of the answer: no JSON DOM, no
// intermediate copies. `writeJsonBody` serializes the struct directly.
struct ProfileOut
{
    string username;
    MaybeString bio;
    MaybeString image;
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
    MaybeString bio;
    MaybeString image;
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
    if (tagUsed + array.length > tagBuffer.length)
    {
        auto tags = new string[](array.length);
        foreach (i; 0 .. array.length)
            tags[i] = cellText(array[i]);
        return tags;
    }
    const start = tagUsed;
    tagUsed += array.length;
    foreach (i; 0 .. array.length)
        tagBuffer[start + i] = cellText(array[i]);
    return tagBuffer[start .. tagUsed];
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

private UserOut userOut(Row row, const(char)[] token)
{
    UserOut user;
    user.username = cellText(row[1]);
    user.email = cellText(row[2]);
    user.bio = cellNullable(row[3]);
    user.image = cellNullable(row[4]);
    user.token = token.idup;
    return user;
}

/// Runs a statement whose unique violations (a taken username or email) are a
/// 422. `ok` is false when the response was already written.
private Answer execUnique(HTTPServerResponse res, QueryParams params, out bool ok)
{
    try
    {
        ok = true;
        return execOne(params);
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

/// A concurrent delete can turn an otherwise valid write into an FK failure.
private bool isForeignKey(Exception e, string constraint)
{
    auto response = cast(ResponseException) e;
    if (!response)
        return false;
    try
        return response.result.resultErrorField('C') == "23503" &&
            response.result.resultErrorField('n') == constraint;
    catch (Exception)
        return false;
}

// ---------------------------------------------------------------------------
// users

/// POST /api/users
private void register(HTTPServerRequest req, HTTPServerResponse res)
{
    UserBody body;
    if (!readBody(req, res, body))
        return;
    string username = body.user.username;
    string email = body.user.email;
    string password = body.user.password;
    if (!reqString(res, username, "username"))
        return;
    if (!reqString(res, email, "email"))
        return;
    if (!reqString(res, password, "password"))
        return;

    auto hash = hashPasswordOffload(password);
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
    LoginBody body;
    if (!readBody(req, res, body))
        return;
    string email = body.user.email;
    string password = body.user.password;
    if (!reqString(res, email, "email"))
        return;
    if (!reqString(res, password, "password"))
        return;

    QueryParams params;
    params.preparedStatementName = Name.userByEmail;
    params.argsVariadic(email);
    auto answer = execOne(params);
    const storedHash = answer.length ? answer[0][5].as!string : dummyPasswordHash();
    const valid = verifyPasswordOffload(password, storedHash);
    if (answer.length == 0 || !valid)
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
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;

    QueryParams params;
    params.preparedStatementName = Name.userById;
    params.argsVariadic(viewer);
    auto answer = execOne(params);
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
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;
    UpdateUserBody body;
    if (!readBody(req, res, body))
        return;

    string email, username, password, bio, image;
    bool hasEmail, hasUsername, hasPassword, hasBio, hasImage;
    if (!optString(res, body.user.email, "email", true, hasEmail, email))
        return;
    if (!optString(res, body.user.username, "username", true, hasUsername, username))
        return;
    if (!optString(res, body.user.password, "password", true, hasPassword, password))
        return;
    if (!optString(res, body.user.bio, "bio", false, hasBio, bio))
        return;
    if (!optString(res, body.user.image, "image", false, hasImage, image))
        return;

    Nullable!string hash;
    if (hasPassword)
    {
        auto hashed = hashPasswordOffload(password);
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
    params.argsVariadic(viewer, dbArg(req.params["username"]));
    auto answer = execOne(params);
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
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;

    QueryParams lookup;
    lookup.preparedStatementName = Name.userByUsername;
    lookup.argsVariadic(dbArg(req.params["username"]));
    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    auto found = conn.execPrepared(lookup);
    if (found.length == 0)
    {
        writeError(res, 404, "profile not found");
        return;
    }
    const followee = found[0][0].as!long;
    QueryParams change;
    change.preparedStatementName = follow ? Name.insertFollow : Name.deleteFollow;
    change.argsVariadic(viewer, followee);
    try
        conn.execPrepared(change);
    catch (Exception e)
    {
        if (isForeignKey(e, "follows_follower_id_fkey"))
        {
            writeError(res, 401, "unauthorized");
            return;
        }
        if (isForeignKey(e, "follows_followee_id_fkey"))
        {
            writeError(res, 404, "profile not found");
            return;
        }
        throw e;
    }

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
    const(char)[] filter;
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
        page.argsVariadic(viewer, limit, offset, dbArg(filter));
        count.preparedStatementName = Name.countByTag;
        count.argsVariadic(dbArg(filter));
        break;
    case ListKind.author:
        page.preparedStatementName = Name.listByAuthor;
        page.argsVariadic(viewer, limit, offset, dbArg(filter));
        count.preparedStatementName = Name.countByAuthor;
        count.argsVariadic(dbArg(filter));
        break;
    case ListKind.favorited:
        page.preparedStatementName = Name.listByFavorite;
        page.argsVariadic(viewer, limit, offset, dbArg(filter));
        count.preparedStatementName = Name.countByFavorite;
        count.argsVariadic(dbArg(filter));
        break;
    }

    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    auto answers = execPipeline(conn, [page, count]);
    auto rows = answers[0];
    auto total = answers[1];
    beginResponse();
    auto articles = new ArticleListOut[](rows.length);
    foreach (i; 0 .. rows.length)
        articles[i] = listArticle(rows[i]);
    writeJson(res, 200, ArticlesOut(articles, total[0][0].as!long));
}

/// GET /api/articles/feed
private void feed(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    const(char)[] token;
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

    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    auto answers = execPipeline(conn, [page, count]);
    auto rows = answers[0];
    auto total = answers[1];
    beginResponse();
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
    params.argsVariadic(viewer, dbArg(req.params["slug"]));
    auto answer = execOne(params);
    if (answer.length == 0)
    {
        writeError(res, 404, "article not found");
        return;
    }
    beginResponse();
    writeJson(res, 200, ArticleOut(fullArticle(answer[0])));
}

/// Rolls back without masking the original failure.
private void rollbackQuietly(ConduitConnection conn) nothrow
{
    try
        execSimple(conn, "ROLLBACK");
    catch (Exception rollbackError)
        logError("conduit: rollback failed: ", rollbackError);
}

/// POST /api/articles
private void createArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;
    ArticleBody payload;
    if (!readBody(req, res, payload))
        return;
    string title = payload.article.title;
    string description = payload.article.description;
    string body = payload.article.body;
    if (!reqString(res, title, "title"))
        return;
    if (!reqString(res, description, "description"))
        return;
    if (!reqString(res, body, "body"))
        return;

    string[] tags;
    foreach (item; payload.article.tagList)
    {
        if (item.length == 0)
        {
            writeError(res, 422, "tagList must be an array of non-empty strings");
            return;
        }
        tags ~= item;
    }

    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    bool committed;
    scope (exit)
    {
        if (!committed)
            rollbackQuietly(conn);
    }
    execSimple(conn, "BEGIN");

    QueryParams insert;
    insert.preparedStatementName = Name.insertArticleWithTags;
    insert.argsVariadic(viewer, title, description, body, tags);
    auto created = conn.execPrepared(insert);
    if (created.length != 1)
    {
        writeError(res, 500, "internal error");
        return;
    }
    const id = created[0][0].as!long;

    QueryParams link;
    link.preparedStatementName = Name.insertArticleTags;
    link.argsVariadic(id, tags);
    conn.execPrepared(link);

    execSimple(conn, "COMMIT");
    committed = true;

    QueryParams full;
    full.preparedStatementName = Name.articleById;
    full.argsVariadic(viewer, id);
    auto answer = conn.execPrepared(full);
    if (answer.length != 1)
    {
        writeError(res, 404, "article not found");
        return;
    }
    beginResponse();
    writeJson(res, 201, ArticleOut(fullArticle(answer[0])));
}

/// PUT /api/articles/:slug
private void updateArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;
    UpdateArticleBody payload;
    if (!readBody(req, res, payload))
        return;
    string title, description, body;
    bool hasTitle, hasDescription, hasBody;
    if (!optString(res, payload.article.title, "title", true, hasTitle, title))
        return;
    if (!optString(res, payload.article.description, "description", true, hasDescription, description))
        return;
    if (!optString(res, payload.article.body, "body", true, hasBody, body))
        return;

    auto conn = pool.acquire();
    scope (exit) pool.release(conn);

    QueryParams owner;
    owner.preparedStatementName = Name.articleOwner;
    owner.argsVariadic(dbArg(req.params["slug"]));
    auto found = conn.execPrepared(owner);
    if (found.length == 0)
    {
        writeError(res, 404, "article not found");
        return;
    }
    if (found[0][1].as!long != viewer)
    {
        writeError(res, 403, "not the author");
        return;
    }
    const id = found[0][0].as!long;

    QueryParams params;
    params.preparedStatementName = Name.updateArticle;
    params.argsVariadic(id,
        hasTitle ? Nullable!string(title) : Nullable!string.init,
        hasDescription ? Nullable!string(description) : Nullable!string.init,
        hasBody ? Nullable!string(body) : Nullable!string.init);
    QueryParams full;
    full.preparedStatementName = Name.articleById;
    full.argsVariadic(viewer, id);
    auto answers = execPipeline(conn, [params, full]);
    if (answers[1].length == 0)
    {
        writeError(res, 404, "article not found");
        return;
    }
    beginResponse();
    writeJson(res, 200, ArticleOut(fullArticle(answers[1][0])));
}

/// DELETE /api/articles/:slug
private void deleteArticle(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;

    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    QueryParams owner;
    owner.preparedStatementName = Name.articleOwner;
    owner.argsVariadic(dbArg(req.params["slug"]));
    auto found = conn.execPrepared(owner);
    if (found.length == 0)
    {
        writeError(res, 404, "article not found");
        return;
    }
    if (found[0][1].as!long != viewer)
    {
        writeError(res, 403, "not the author");
        return;
    }
    QueryParams params;
    params.preparedStatementName = Name.deleteArticle;
    params.argsVariadic(found[0][0].as!long);
    conn.execPrepared(params);
    writeNoContent(res);
}

/// POST and DELETE /api/articles/:slug/favorite
private void favorite(HTTPServerRequest req, HTTPServerResponse res, bool favorite)
{
    long viewer;
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;

    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    QueryParams change;
    change.preparedStatementName = favorite ? Name.insertFavoriteBySlug : Name.deleteFavoriteBySlug;
    change.argsVariadic(viewer, dbArg(req.params["slug"]));
    try
    {
        auto changed = conn.execPrepared(change);
        if (changed.length == 0)
        {
            writeError(res, 404, "article not found");
            return;
        }
        const id = changed[0][0].as!long;
        QueryParams full;
        full.preparedStatementName = Name.articleById;
        full.argsVariadic(viewer, id);
        auto answer = conn.execPrepared(full);
        if (answer.length == 0)
        {
            writeError(res, 404, "article not found");
            return;
        }
        beginResponse();
        writeJson(res, 200, ArticleOut(fullArticle(answer[0])));
    }
    catch (Exception e)
    {
        if (isForeignKey(e, "favorites_user_id_fkey"))
        {
            writeError(res, 401, "unauthorized");
            return;
        }
        if (isForeignKey(e, "favorites_article_id_fkey"))
        {
            writeError(res, 404, "article not found");
            return;
        }
        throw e;
    }
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

    QueryParams id;
    id.preparedStatementName = Name.articleIdBySlug;
    id.argsVariadic(dbArg(req.params["slug"]));
    QueryParams list;
    list.preparedStatementName = Name.commentsByArticleSlug;
    list.argsVariadic(viewer, dbArg(req.params["slug"]));
    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
    auto answers = execPipeline(conn, [id, list]);
    if (answers[0].length == 0)
    {
        writeError(res, 404, "article not found");
        return;
    }
    auto answer = answers[1];
    beginResponse();
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
    const(char)[] token;
    if (!requireAuth(res, req, viewer, token))
        return;
    CommentBody payload;
    if (!readBody(req, res, payload))
        return;
    string body = payload.comment.body;
    if (!reqString(res, body, "body"))
        return;

    QueryParams params;
    params.preparedStatementName = Name.insertCommentBySlug;
    params.argsVariadic(dbArg(req.params["slug"]), viewer, body);
    try
    {
        auto answer = execOne(params);
        if (answer.length == 0)
        {
            writeError(res, 404, "article not found");
            return;
        }
        beginResponse();
        writeJson(res, 201, CommentResponse(commentOut(answer[0], false)));
    }
    catch (Exception e)
    {
        if (isForeignKey(e, "comments_author_id_fkey"))
        {
            writeError(res, 401, "unauthorized");
            return;
        }
        if (isForeignKey(e, "comments_article_id_fkey"))
        {
            writeError(res, 404, "article not found");
            return;
        }
        throw e;
    }
}

/// DELETE /api/articles/:slug/comments/:id. A non-integer id is a 404.
private void deleteComment(HTTPServerRequest req, HTTPServerResponse res)
{
    long viewer;
    const(char)[] token;
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
    params.argsVariadic(commentId, dbArg(req.params["slug"]));
    auto conn = pool.acquire();
    scope (exit) pool.release(conn);
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
    auto answer = execOne(params);
    if (answer.length != 1 || answer[0][0].isNull)
    {
        writeJson(res, 200, TagsOut(tagBuffer[0 .. 0]));
        return;
    }
    beginResponse();
    if (answer[0][1].as!bool)
    {
        QueryParams rows;
        rows.preparedStatementName = Name.tagsAllRows;
        auto all = execOne(rows);
        beginResponse();
        if (all.length > tagBuffer.length)
        {
            auto names = new string[](all.length);
            foreach (i; 0 .. all.length)
                names[i] = cellText(all[i][0]);
            writeJson(res, 200, TagsOut(names));
            return;
        }
        foreach (i; 0 .. all.length)
            tagBuffer[tagUsed++] = cellText(all[i][0]);
        writeJson(res, 200, TagsOut(tagBuffer[0 .. tagUsed]));
        return;
    }
    beginResponse();
    auto raw = cellText(answer[0][0]);
    size_t count = 1;
    foreach (c; raw)
        if (c == '\x1f')
            ++count;
    if (count > tagBuffer.length)
    {
        auto names = new string[](count);
        size_t index;
        size_t begin;
        while (begin < raw.length)
        {
            size_t end = begin;
            while (end < raw.length && raw[end] != '\x1f')
                ++end;
            names[index++] = raw[begin .. end];
            begin = end + 1;
        }
        writeJson(res, 200, TagsOut(names));
        return;
    }
    size_t begin;
    while (begin < raw.length)
    {
        size_t end = begin;
        while (end < raw.length && raw[end] != '\x1f')
            ++end;
        tagBuffer[tagUsed++] = raw[begin .. end];
        begin = end + 1;
    }
    writeJson(res, 200, TagsOut(tagBuffer[0 .. tagUsed]));
}

// ---------------------------------------------------------------------------
// routing

/// photon-http has no router: match the 19 shapes directly. `/api/articles/feed`
/// is handled before `/api/articles/:slug`.
private void dispatch(HTTPServerRequest req, HTTPServerResponse res)
{
    const method = req.method;
    const path = req.path;
    const(char)[][8] segments;
    const count = splitPath(path, segments);
    const segment = segments[0 .. count];

    if (method == HttpMethod.POST && path == "/api/users")
        return register(req, res);
    if (method == HttpMethod.POST && path == "/api/users/login")
        return login(req, res);
    if (method == HttpMethod.GET && path == "/api/user")
        return currentUser(req, res);
    if (method == HttpMethod.PUT && path == "/api/user")
        return updateUser(req, res);

    if (count == 4 && segment[1] == "api" && segment[2] == "profiles")
    {
        req.params["username"] = decodePath(segment[3]);
        if (method == HttpMethod.GET)
            return getProfile(req, res);
    }
    if (count == 5 && segment[1] == "api" && segment[2] == "profiles"
            && segment[4] == "follow")
    {
        req.params["username"] = decodePath(segment[3]);
        if (method == HttpMethod.POST)
            return followProfile(req, res);
        if (method == HttpMethod.DELETE)
            return unfollowProfile(req, res);
    }

    if (method == HttpMethod.GET && path == "/api/articles/feed")
        return feed(req, res);
    if (method == HttpMethod.GET && path == "/api/articles")
        return listArticles(req, res);
    if (method == HttpMethod.POST && path == "/api/articles")
        return createArticle(req, res);

    if (count == 5 && segment[1] == "api" && segment[2] == "articles"
            && segment[4] == "comments")
    {
        req.params["slug"] = decodePath(segment[3]);
        if (method == HttpMethod.GET)
            return listComments(req, res);
        if (method == HttpMethod.POST)
            return createComment(req, res);
    }
    if (count == 6 && segment[1] == "api" && segment[2] == "articles"
            && segment[4] == "comments")
    {
        req.params["slug"] = decodePath(segment[3]);
        req.params["id"] = decodePath(segment[5]);
        if (method == HttpMethod.DELETE)
            return deleteComment(req, res);
    }
    if (count == 5 && segment[1] == "api" && segment[2] == "articles"
            && segment[4] == "favorite")
    {
        req.params["slug"] = decodePath(segment[3]);
        if (method == HttpMethod.POST)
            return favoriteArticle(req, res);
        if (method == HttpMethod.DELETE)
            return unfavoriteArticle(req, res);
    }
    if (count == 4 && segment[1] == "api" && segment[2] == "articles")
    {
        req.params["slug"] = decodePath(segment[3]);
        if (method == HttpMethod.GET)
            return getArticle(req, res);
        if (method == HttpMethod.PUT)
            return updateArticle(req, res);
        if (method == HttpMethod.DELETE)
            return deleteArticle(req, res);
    }

    if (method == HttpMethod.GET && path == "/api/tags")
        return tags(req, res);

    writeError(res, 404, "not found");
}

/// One processor per connection: it parses requests and dispatches them.
final class ConduitProcessor : HttpProcessor
{
    private shared(long)* activity;
    private HTTPServerResponse response;

    this(Socket socket, shared(long)* activity = null)
    {
        super(socket);
        this.activity = activity;
        response = new HTTPServerResponse(this);
    }

    override void handle(HttpRequest raw)
    {
        if (activity !is null)
            atomicStore(*activity, MonoTime.currTime.ticks);
        resetRequestArenas();
        response.reset();
        HTTPServerRequest req;
        req.method = raw.method;
        req.headers = raw.headers;
        req.body = cast(const(char)[]) raw.body_;

        const uri = cast(const(char)[]) raw.uri;
        const q = uri.indexOf('?');
        const path = q < 0 ? uri : uri[0 .. q];
        req.path = path;
        if (q >= 0)
            req.query = parseQuery(uri[q + 1 .. $]);

        try
            dispatch(req, response);
        catch (Exception e)
        {
            logError("conduit: request failed: ", e);
            if (!response.headerWritten)
                writeError(response, 500, "internal error");
        }
    }
}
