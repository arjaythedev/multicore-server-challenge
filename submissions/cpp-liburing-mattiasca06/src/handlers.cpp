// Routing and the 19 endpoints. Each handler is a coroutine that awaits Postgres segments and bcrypt jobs.
#include <ctime>
#include <cstdlib>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "auth.h"
#include "bufpool.h"
#include "codec.h"
#include "json_out.h"
#include "prof.h"
#include "worker.h"
#include "yyjson.h"

namespace {

inline bool is_null(const Res &r, int row, int col) { return r.null(row, col); }
inline std::string_view text(const Res &r, int row, int col) { return r.text(row, col); }
inline int64_t i64(const Res &r, int row, int col) { return codec::be64(r.raw(row, col)); }
inline bool boolean(const Res &r, int row, int col) { return r.raw(row, col)[0] != 0; }

Reply err(int status, const char *msg) {
    return {status, std::string(R"({"errors":{"body":[")") + msg + R"("]}})"};
}
Reply db_error() { return err(500, "database error"); }

void put(std::string &o, std::string_view s) { json::str(o, s.data(), s.size()); }
void put_nullable(std::string &o, const Res &r, int row, int col) {
    if (is_null(r, row, col)) json::lit(o, "null");
    else put(o, text(r, row, col));
}

// ---- authentication ----

enum class AuthState { Anon, Ok, Bad };

std::string_view token_of(const Request &rq) {
    std::string_view a = rq.auth;
    if (a.size() < 6 || strncasecmp(a.data(), "Token ", 6) != 0) return {};
    a.remove_prefix(6);
    while (!a.empty() && a.front() == ' ') a.remove_prefix(1);
    while (!a.empty() && a.back() == ' ') a.remove_suffix(1);
    return a;
}

AuthState authenticate(const Request &rq, int64_t &viewer) {
    viewer = 0;
    if (!rq.has_auth) return AuthState::Anon;
    std::string_view t = token_of(rq);
    if (t.empty() || !g_jwt.verify(t, time(nullptr), viewer)) return AuthState::Bad;
    return AuthState::Ok;
}

// ---- request JSON ----

struct Doc {
    // Small bodies are parsed in this inline pool (no malloc); anything bigger falls back to the heap.
    alignas(8) char pool[4096];
    yyjson_alc alc;
    yyjson_doc *d;
    explicit Doc(const std::string &s) : d(parse(s)) {}
    yyjson_doc *parse(const std::string &s) {
        PROF_SCOPE(kJsonIn);
        if (yyjson_read_max_memory_usage(s.size(), 0) <= sizeof pool && yyjson_alc_pool_init(&alc, pool, sizeof pool))
            return yyjson_read_opts(const_cast<char *>(s.data()), s.size(), 0, &alc, nullptr);
        return yyjson_read(s.data(), s.size(), 0);
    }
    ~Doc() { yyjson_doc_free(d); }
    Doc(const Doc &) = delete;
    // The object under the given top-level key, or null.
    yyjson_val *inner(const char *key) const {
        yyjson_val *root = d ? yyjson_doc_get_root(d) : nullptr;
        if (!yyjson_is_obj(root)) return nullptr;
        yyjson_val *o = yyjson_obj_get(root, key);
        return yyjson_is_obj(o) ? o : nullptr;
    }
};

// An optional string field: absent or null -> Missing; a string without NUL bytes -> Ok; anything else -> Bad.
struct StrField {
    enum { Missing, Ok, Bad } st = Missing;
    std::string v;
    bool present_nonempty() const { return st == Ok && !v.empty(); }
    Param param() const { return st == Ok ? Param(v) : Param(nullptr); }
};

StrField str_field(yyjson_val *obj, const char *key) {
    StrField f;
    yyjson_val *v = yyjson_obj_get(obj, key);
    if (!v || yyjson_is_null(v)) return f;
    if (!yyjson_is_str(v)) {
        f.st = StrField::Bad;
        return f;
    }
    const char *s = yyjson_get_str(v);
    size_t n = yyjson_get_len(v);
    if (memchr(s, 0, n)) {
        f.st = StrField::Bad;
        return f;
    }
    f.st = StrField::Ok;
    f.v.assign(s, n);
    return f;
}

// ---- response JSON ----

void user_json(std::string &o, const Res &r, int row, std::string_view token) {
    json::lit(o, R"({"user":{"email":)");
    put(o, text(r, row, 2));
    json::lit(o, R"(,"token":)");
    put(o, token);
    json::lit(o, R"(,"username":)");
    put(o, text(r, row, 1));
    json::lit(o, R"(,"bio":)");
    put_nullable(o, r, row, 3);
    json::lit(o, R"(,"image":)");
    put_nullable(o, r, row, 4);
    json::lit(o, "}}");
}

void author_json(std::string &o, const Res &r, int row, int c_username, bool following) {
    json::lit(o, R"("author":{"username":)");
    put(o, text(r, row, c_username));
    json::lit(o, R"(,"bio":)");
    put_nullable(o, r, row, c_username + 1);
    json::lit(o, R"(,"image":)");
    put_nullable(o, r, row, c_username + 2);
    json::lit(o, R"(,"following":)");
    o += following ? "true" : "false";
    o += '}';
}

void profile_json(std::string &o, const Res &r, int row, int c_username, bool following) {
    json::lit(o, R"({"profile":{"username":)");
    put(o, text(r, row, c_username));
    json::lit(o, R"(,"bio":)");
    put_nullable(o, r, row, c_username + 1);
    json::lit(o, R"(,"image":)");
    put_nullable(o, r, row, c_username + 2);
    json::lit(o, R"(,"following":)");
    o += following ? "true" : "false";
    json::lit(o, "}}");
}

// Columns: id, slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count, favorited,
// username, bio, image, following.
void article_json(std::string &o, const Res &r, int row, bool full) {
    int c = 1;
    json::lit(o, R"({"slug":)");
    put(o, text(r, row, c++));
    json::lit(o, R"(,"title":)");
    put(o, text(r, row, c++));
    json::lit(o, R"(,"description":)");
    put(o, text(r, row, c++));
    if (full) {
        json::lit(o, R"(,"body":)");
        put(o, text(r, row, c++));
    }
    json::lit(o, R"(,"createdAt":")");
    codec::append_ts(o, i64(r, row, c++));
    json::lit(o, R"(","updatedAt":")");
    codec::append_ts(o, i64(r, row, c++));
    json::lit(o, R"(","tagList":[)");
    {
        const char *p = r.raw(row, c++);  // binary text[]: ndim, hasnull, elemtype, then dims, then elements
        int32_t ndim = codec::be32(p);
        if (ndim > 0) {
            int32_t n = codec::be32(p + 12);
            const char *e = p + 12 + 8 * ndim;
            if (n > 1 && g_sort_tags_in_app.load(std::memory_order_relaxed)) {
                std::string_view small[16];
                std::vector<std::string_view> big;
                std::string_view *tags = small;
                if (n > 16) big.resize(size_t(n)), tags = big.data();
                for (int32_t i = 0; i < n; i++) {
                    int32_t len = codec::be32(e);
                    e += 4;
                    std::string_view t(e, size_t(len));
                    e += len;
                    int32_t j = i;  // insertion sort, byte order
                    for (; j > 0 && tags[j - 1] > t; j--) tags[j] = tags[j - 1];
                    tags[j] = t;
                }
                for (int32_t i = 0; i < n; i++) {
                    if (i) o += ',';
                    put(o, tags[i]);
                }
            } else {
                for (int32_t i = 0; i < n; i++) {
                    int32_t len = codec::be32(e);
                    e += 4;
                    if (i) o += ',';
                    put(o, std::string_view(e, size_t(len)));
                    e += len;
                }
            }
        }
    }
    json::lit(o, R"(],"favorited":)");
    int favcount = c++;
    int favorited = c++;
    o += boolean(r, row, favorited) ? "true" : "false";
    json::lit(o, R"(,"favoritesCount":)");
    o += std::to_string(i64(r, row, favcount));
    o += ',';
    int c_user = c;
    author_json(o, r, row, c_user, boolean(r, row, c_user + 3));
    o += '}';
}

void comment_json(std::string &o, const Res &r, int row, bool following) {
    json::lit(o, R"({"id":)");
    o += std::to_string(i64(r, row, 0));
    json::lit(o, R"(,"createdAt":")");
    codec::append_ts(o, i64(r, row, 2));
    json::lit(o, R"(","updatedAt":")");
    codec::append_ts(o, i64(r, row, 3));
    json::lit(o, R"(","body":)");
    put(o, text(r, row, 1));
    o += ',';
    author_json(o, r, row, 4, following);
    o += '}';
}

// ---- small helpers ----

bool parse_i64(std::string_view s, int64_t &out) {
    if (s.empty() || s.size() > 18) return false;
    size_t i = 0;
    bool neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
        if (s.size() == 1) return false;
    }
    int64_t v = 0;
    for (; i < s.size(); i++) {
        if (s[i] < '0' || s[i] > '9') return false;
        v = v * 10 + (s[i] - '0');
    }
    out = neg ? -v : v;
    return true;
}

std::vector<std::pair<std::string, std::string>> parse_query(std::string_view q) {
    std::vector<std::pair<std::string, std::string>> out;
    while (!q.empty()) {
        size_t amp = q.find('&');
        std::string_view part = q.substr(0, amp);
        q = amp == std::string_view::npos ? std::string_view() : q.substr(amp + 1);
        if (part.empty()) continue;
        size_t eq = part.find('=');
        std::string k = codec::pct_decode(part.substr(0, eq), true);
        std::string v = eq == std::string_view::npos ? "" : codec::pct_decode(part.substr(eq + 1), true);
        out.emplace_back(std::move(k), std::move(v));
    }
    return out;
}

std::string pg_text_array(const std::vector<std::string> &v) {
    std::string o = "{";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) o += ',';
        o += '"';
        for (char ch : v[i]) {
            if (ch == '"' || ch == '\\') o += '\\';
            o += ch;
        }
        o += '"';
    }
    o += '}';
    return o;
}

}  // namespace

Task<Reply> Worker::route(const Request &rq) {
    std::string_view path = rq.path;
    if (path.substr(0, 5) != "/api/") co_return err(404, "not found");
    path.remove_prefix(5);
    // Segments are views into the path; one with a % escape is decoded into `decoded`, which is reserved up front
    // (a decoded segment is never longer than the path) so the views stay valid.
    constexpr size_t kMaxSeg = 8;
    std::string_view seg[kMaxSeg];
    std::string decoded;
    if (path.find('%') != std::string_view::npos) decoded.reserve(path.size());
    size_t n = 0;
    while (true) {
        size_t s = path.find('/');
        std::string_view part = path.substr(0, s);
        if (n == kMaxSeg) co_return err(404, "not found");  // no route has this many segments
        if (part.find('%') == std::string_view::npos) seg[n] = part;
        else {
            size_t at = decoded.size();
            decoded += codec::pct_decode(part, false);
            seg[n] = std::string_view(decoded).substr(at);
        }
        n++;
        if (s == std::string_view::npos) break;
        path.remove_prefix(s + 1);
    }
    if (n > 1 && seg[n - 1].empty()) n--;

    int64_t viewer = 0;
    AuthState st = authenticate(rq, viewer);
    const std::string &m = rq.method;
    bool get = m == "GET", post = m == "POST", put_ = m == "PUT", del = m == "DELETE";
    std::string_view s0 = seg[0];

    // Auth-required endpoints answer 401 unless a valid token came with the request; optional ones only reject a
    // token that is present but invalid.
    auto need_auth = [&] { return st != AuthState::Ok; };
    auto bad_auth = [&] { return st == AuthState::Bad; };

    if (s0 == "tags" && n == 1 && get) co_return co_await h_tags();
    if (s0 == "users") {
        if (n == 1 && post) co_return co_await h_register(rq);
        if (n == 2 && seg[1] == "login" && post) co_return co_await h_login(rq);
    } else if (s0 == "user" && n == 1) {
        if (get || put_) {
            if (need_auth()) co_return err(401, "unauthorized");
            if (get) co_return co_await h_get_user(rq, viewer);
            co_return co_await h_put_user(rq, viewer);
        }
    } else if (s0 == "profiles" && n >= 2) {
        if (n == 2 && get) {
            if (bad_auth()) co_return err(401, "unauthorized");
            co_return co_await h_profile(rq, std::string(seg[1]), viewer);
        }
        if (n == 3 && seg[2] == "follow" && (post || del)) {
            if (need_auth()) co_return err(401, "unauthorized");
            co_return co_await h_follow(rq, std::string(seg[1]), viewer, post);
        }
    } else if (s0 == "articles") {
        if (n == 1) {
            if (get) {
                if (bad_auth()) co_return err(401, "unauthorized");
                co_return co_await h_list(rq, viewer, false);
            }
            if (post) {
                if (need_auth()) co_return err(401, "unauthorized");
                co_return co_await h_create_article(rq, viewer);
            }
        } else if (n == 2) {
            if (seg[1] == "feed" && get) {
                if (need_auth()) co_return err(401, "unauthorized");
                co_return co_await h_list(rq, viewer, true);
            }
            if (get) {
                if (bad_auth()) co_return err(401, "unauthorized");
                co_return co_await h_article(std::string(seg[1]), viewer);
            }
            if (put_ || del) {
                if (need_auth()) co_return err(401, "unauthorized");
                // (no co_await inside ?: — GCC evaluates both arms)
                if (put_) co_return co_await h_update_article(rq, std::string(seg[1]), viewer);
                co_return co_await h_delete_article(std::string(seg[1]), viewer);
            }
        } else if (n == 3 && seg[2] == "favorite" && (post || del)) {
            if (need_auth()) co_return err(401, "unauthorized");
            co_return co_await h_favorite(std::string(seg[1]), viewer, post);
        } else if (n == 3 && seg[2] == "comments") {
            if (get) {
                if (bad_auth()) co_return err(401, "unauthorized");
                co_return co_await h_comments(std::string(seg[1]), viewer);
            }
            if (post) {
                if (need_auth()) co_return err(401, "unauthorized");
                co_return co_await h_add_comment(rq, std::string(seg[1]), viewer);
            }
        } else if (n == 4 && seg[2] == "comments" && del) {
            if (need_auth()) co_return err(401, "unauthorized");
            co_return co_await h_delete_comment(std::string(seg[1]), std::string(seg[3]), viewer);
        }
    }
    co_return err(404, "not found");
}

// The query list of every db()/db_write() call is built in its own statement: GCC 13 (Ubuntu 24.04) hits an internal
// compiler error on a braced list of Query temporaries inside a co_await expression.
Task<Reply> Worker::h_tags() {
    QVec qv1{Query("tags", {})};
    Rows rows = co_await db(std::move(qv1));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    std::string body;
    take_buf(body); body.reserve(32 + size_t(rows[0].rows()) * 16);
    body = R"({"tags":[)";
    const Res &r = rows[0];
    for (int i = 0; i < r.rows(); i++) {
        if (i) body += ',';
        put(body, text(r, i, 0));
    }
    json::lit(body, "]}");
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_register(const Request &rq) {
    Doc doc(rq.body);
    yyjson_val *u = doc.inner("user");
    if (!u) co_return err(422, "invalid body");
    StrField username = str_field(u, "username"), email = str_field(u, "email"), password = str_field(u, "password");
    if (!username.present_nonempty() || !email.present_nonempty() || !password.present_nonempty())
        co_return err(422, "username, email and password are required");
    if (password.v.size() > 72) co_return err(422, "password too long");

    BcryptResult br = co_await bcrypt_hash(password.v);
    if (!br.ok) co_return err(500, "hashing failed");
    QVec qv2{Query("user_register", {username.v, email.v, br.hash})};
    Rows rows = co_await db_write(std::move(qv2), true);
    if (!rows.ok || rows.r.size() != 1) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (r.p->status != PgStatus::Ok)
        co_return sqlstate(r) == "23505" ? err(422, "username or email already taken") : db_error();
    std::string body;
    user_json(body, r, 0, g_jwt.sign(i64(r, 0, 0), time(nullptr)));
    co_return Reply{201, std::move(body)};
}

Task<Reply> Worker::h_login(const Request &rq) {
    Doc doc(rq.body);
    yyjson_val *u = doc.inner("user");
    if (!u) co_return err(422, "invalid body");
    StrField email = str_field(u, "email"), password = str_field(u, "password");
    if (!email.present_nonempty() || !password.present_nonempty()) co_return err(422, "email and password are required");

    QVec qv3{Query("user_login", {email.v})};
    Rows rows = co_await db(std::move(qv3));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (r.rows() == 0) co_return err(401, "invalid credentials");
    BcryptResult br = co_await bcrypt_verify(password.v, std::string(text(r, 0, 5)));
    if (!br.ok) co_return err(401, "invalid credentials");
    std::string body;
    user_json(body, r, 0, g_jwt.sign(i64(r, 0, 0), time(nullptr)));
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_get_user(const Request &rq, int64_t viewer) {
    QVec qv4{Query("user_by_id", {viewer})};
    Rows rows = co_await db(std::move(qv4));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    if (rows[0].rows() == 0) co_return err(401, "unauthorized");
    std::string body;
    user_json(body, rows[0], 0, token_of(rq));
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_put_user(const Request &rq, int64_t viewer) {
    Doc doc(rq.body);
    yyjson_val *u = doc.inner("user");
    if (!u) co_return err(422, "invalid body");
    StrField email = str_field(u, "email"), username = str_field(u, "username"), password = str_field(u, "password"),
             bio = str_field(u, "bio"), image = str_field(u, "image");
    for (const StrField *f : {&email, &username, &password, &bio, &image})
        if (f->st == StrField::Bad) co_return err(422, "invalid field");
    for (const StrField *f : {&email, &username, &password})
        if (f->st == StrField::Ok && f->v.empty()) co_return err(422, "must not be empty");
    if (password.v.size() > 72) co_return err(422, "password too long");

    Param hash = nullptr;
    if (password.st == StrField::Ok) {
        BcryptResult br = co_await bcrypt_hash(password.v);
        if (!br.ok) co_return err(500, "hashing failed");
        hash = Param(br.hash);
    }
    QVec qv5{Query("user_update", {viewer, email.param(), username.param(), hash, bio.param(), image.param()})};
    Rows rows = co_await db_write(std::move(qv5), true);
    if (!rows.ok || rows.r.size() != 1) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (r.p->status != PgStatus::Ok)
        co_return sqlstate(r) == "23505" ? err(422, "username or email already taken") : db_error();
    if (r.rows() == 0) co_return err(401, "unauthorized");
    std::string body;
    user_json(body, r, 0, token_of(rq));
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_profile(const Request &, std::string name, int64_t viewer) {
    QVec qv6{Query("profile", {viewer, name})};
    Rows rows = co_await db(std::move(qv6));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (r.rows() == 0) co_return err(404, "profile not found");
    std::string body;
    profile_json(body, r, 0, 1, boolean(r, 0, 4));
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_follow(const Request &, std::string name, int64_t viewer, bool follow) {
    QVec qv7{Query(follow ? "follow_slug" : "unfollow_slug", {viewer, name})};
    Rows rows = co_await db_write(std::move(qv7));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (r.rows() == 0) co_return err(404, "profile not found");
    std::string body;
    profile_json(body, r, 0, 0, follow);
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_list(const Request &rq, int64_t viewer, bool feed) {
    int64_t limit = 20, offset = 0;
    std::string tag, author, favorited;
    for (auto &[k, v] : parse_query(rq.query)) {
        if (k == "limit") {
            if (!parse_i64(v, limit) || limit < 1 || limit > 100) co_return err(422, "invalid limit");
        } else if (k == "offset") {
            if (!parse_i64(v, offset) || offset < 0) co_return err(422, "invalid offset");
        } else if (k == "tag") {
            tag = v;
        } else if (k == "author") {
            author = v;
        } else if (k == "favorited") {
            favorited = v;
        }
    }

    QVec qs;
    if (feed) {
        qs.push_back(Query("feed", {viewer, limit, offset}));
    } else if (!tag.empty()) {
        qs.push_back(Query("list_tag", {viewer, limit, offset, tag}));
        qs.push_back(Query("count_tag", {tag}));
    } else if (!author.empty()) {
        qs.push_back(Query("list_author", {viewer, limit, offset, author}));
        qs.push_back(Query("count_author", {author}));
    } else if (!favorited.empty()) {
        qs.push_back(Query("list_fav", {viewer, limit, offset, favorited}));
        qs.push_back(Query("count_fav", {favorited}));
    } else {
        qs.push_back(Query("list_all", {viewer, limit, offset}));
        qs.push_back(Query("count_all", {}));
    }
    Rows rows = co_await db(std::move(qs));
    if (!rows.all_ok(feed ? 1 : 2)) [[unlikely]] co_return db_error();
    Res page = rows[0];
    int64_t total;
    if (feed) {
        // every feed row leads with the count; an empty page is one row whose id is NULL
        total = rows[0].rows() ? i64(rows[0], 0, 0) : 0;
        page.col0 += 1;
    } else {
        total = i64(rows[1], 0, 0);
    }
    std::string body;
    take_buf(body); body.reserve(128 + size_t(page.rows()) * 700);  // ~one allocation instead of ~10 doublings
    body = R"({"articles":[)";
    bool first = true;
    for (int i = 0; i < page.rows(); i++) {
        if (feed && page.null(i, 0)) continue;
        if (!first) body += ',';
        first = false;
        article_json(body, page, i, false);
    }
    json::lit(body, R"(],"articlesCount":)");
    body += std::to_string(total);
    body += '}';
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_article(std::string slug, int64_t viewer) {
    QVec qv8{Query("article_by_slug", {viewer, slug})};
    Rows rows = co_await db(std::move(qv8));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    if (rows[0].rows() == 0) co_return err(404, "article not found");
    std::string body = R"({"article":)";
    article_json(body, rows[0], 0, true);
    body += '}';
    co_return Reply{200, std::move(body)};
}

Task<Reply> Worker::h_create_article(const Request &rq, int64_t viewer) {
    Doc doc(rq.body);
    yyjson_val *a = doc.inner("article");
    if (!a) co_return err(422, "invalid body");
    StrField title = str_field(a, "title"), description = str_field(a, "description"), body = str_field(a, "body");
    if (!title.present_nonempty() || !description.present_nonempty() || !body.present_nonempty())
        co_return err(422, "title, description and body are required");
    std::vector<std::string> tags;
    yyjson_val *tl = yyjson_obj_get(a, "tagList");
    if (tl && !yyjson_is_null(tl)) {
        if (!yyjson_is_arr(tl)) co_return err(422, "tagList must be an array");
        size_t i, max;
        yyjson_val *t;
        yyjson_arr_foreach(tl, i, max, t) {
            if (!yyjson_is_str(t) || yyjson_get_len(t) == 0 || memchr(yyjson_get_str(t), 0, yyjson_get_len(t)))
                co_return err(422, "tags must be non-empty strings");
            tags.emplace_back(yyjson_get_str(t), yyjson_get_len(t));
        }
    }

    // One segment, one implicit transaction: the article and its tags commit together. The later statements find
    // the new id through currval(), which is safe because a solo segment owns the write connection.
    QVec qs;
    qs.push_back(Query("article_create", {title.v, viewer, description.v, body.v}));
    if (!tags.empty()) {
        std::string lit = pg_text_array(tags);
        qs.push_back(Query("tags_insert", {lit}));
        qs.push_back(Query("article_tags_curr", {lit}));
    }
    size_t nq = qs.size();
    qs.push_back(Query("article_by_curr", {viewer}));  // read-back in the same segment sees the insert
    Rows ins = co_await db_write(std::move(qs), true);
    if (!ins.all_ok(nq + 1)) [[unlikely]] co_return db_error();
    const Res &res = ins[nq];
    if (res.rows() == 0) [[unlikely]] co_return db_error();
    std::string out;
    take_buf(out); out.reserve(1536);
    out = R"({"article":)";
    article_json(out, res, 0, true);
    out += '}';
    co_return Reply{201, std::move(out)};
}

Task<Reply> Worker::h_update_article(const Request &rq, std::string slug, int64_t viewer) {
    Doc doc(rq.body);
    yyjson_val *a = doc.inner("article");
    if (!a) co_return err(422, "invalid body");
    StrField title = str_field(a, "title"), description = str_field(a, "description"), body = str_field(a, "body");
    for (const StrField *f : {&title, &description, &body})
        if (f->st == StrField::Bad || (f->st == StrField::Ok && f->v.empty())) co_return err(422, "invalid field");

    // The update only matches the author's own article; the owner lookup in the same segment tells 403 from 404.
    QVec qv9{Query("article_update_full", {viewer, slug, title.param(), description.param(), body.param()}),
                                   Query("article_owner", {slug})};
    Rows rows = co_await db_write(std::move(qv9));
    if (!rows.all_ok(2)) [[unlikely]] co_return db_error();
    if (rows[0].rows() == 0) co_return rows[1].rows() == 0 ? err(404, "article not found") : err(403, "forbidden");
    std::string out;
    take_buf(out); out.reserve(1536);
    out = R"({"article":)";
    article_json(out, rows[0], 0, true);
    out += '}';
    co_return Reply{200, std::move(out)};
}

Task<Reply> Worker::h_delete_article(std::string slug, int64_t viewer) {
    QVec qv10{Query("article_delete_slug", {slug, viewer})};
    Rows rows = co_await db_write(std::move(qv10));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (i64(r, 0, 0) > 0) co_return Reply{204, {}};
    if (is_null(r, 0, 1)) co_return err(404, "article not found");
    co_return err(403, "forbidden");
}

Task<Reply> Worker::h_favorite(std::string slug, int64_t viewer, bool add) {
    // The read-back runs in the same segment, so it sees this request's own write; no row means no such article.
    QVec qv11{Query(add ? "fav_add_slug" : "fav_del_slug", {viewer, slug}), Query("article_by_slug", {viewer, slug})};
    Rows rows = co_await db_write(std::move(qv11));
    if (!rows.all_ok(2)) [[unlikely]] co_return db_error();
    if (rows[1].rows() == 0) co_return err(404, "article not found");
    std::string out;
    take_buf(out); out.reserve(1536);
    out = R"({"article":)";
    article_json(out, rows[1], 0, true);
    out += '}';
    co_return Reply{200, std::move(out)};
}

Task<Reply> Worker::h_comments(std::string slug, int64_t viewer) {
    QVec qv12{Query("comments_by_slug", {viewer, slug})};
    Rows rows = co_await db(std::move(qv12));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (r.rows() == 0) co_return err(404, "article not found");
    std::string out;
    take_buf(out); out.reserve(64 + size_t(r.rows()) * 450);
    out = R"({"comments":[)";
    for (int i = 0; i < r.rows() && !is_null(r, i, 0); i++) {
        if (i) out += ',';
        comment_json(out, r, i, boolean(r, i, 7));
    }
    json::lit(out, "]}");
    co_return Reply{200, std::move(out)};
}

Task<Reply> Worker::h_add_comment(const Request &rq, std::string slug, int64_t viewer) {
    Doc doc(rq.body);
    yyjson_val *c = doc.inner("comment");
    if (!c) co_return err(422, "invalid body");
    StrField body = str_field(c, "body");
    if (!body.present_nonempty()) co_return err(422, "body is required");

    QVec qv13{Query("comment_insert_slug", {slug, viewer, body.v})};
    Rows rows = co_await db_write(std::move(qv13));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    if (rows[0].rows() == 0) co_return err(404, "article not found");
    std::string out;
    take_buf(out); out.reserve(512);
    out = R"({"comment":)";
    comment_json(out, rows[0], 0, false);
    out += '}';
    co_return Reply{201, std::move(out)};
}

Task<Reply> Worker::h_delete_comment(std::string slug, std::string id, int64_t viewer) {
    int64_t cid;
    if (!parse_i64(id, cid) || cid < 0) co_return err(404, "comment not found");
    QVec qv14{Query("comment_delete_slug", {cid, slug, viewer})};
    Rows rows = co_await db_write(std::move(qv14));
    if (!rows.all_ok(1)) [[unlikely]] co_return db_error();
    const Res &r = rows[0];
    if (i64(r, 0, 0) > 0) co_return Reply{204, {}};
    if (is_null(r, 0, 1)) co_return err(404, "comment not found");
    co_return err(403, "forbidden");
}
