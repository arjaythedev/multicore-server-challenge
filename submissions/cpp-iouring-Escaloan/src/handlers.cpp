// Endpoint logic: routing, authentication, validation, statement parameters, and JSON responses streamed from
// binary result rows. Validation order follows the reference server: auth (401), then request shape (422),
// then database lookups (404 / 403).
#include <cstring>

#include "auth.hpp"
#include "json_read.hpp"
#include "server.hpp"
#include "util.hpp"

namespace {

thread_local json::Doc t_doc;

enum : std::uint8_t {
  kFlagExists = 1,      // write path: the target row existed (first statement returned a row)
  kFlagListOpen = 2,    // list/comments JSON prefix written
  kFlagNeedComma = 4,   // an element was written; the next one needs a comma
};

enum class AuthMode : std::uint8_t { None, Optional, Required };

AuthMode auth_mode(Route r) {
  switch (r) {
    case Route::Register:
    case Route::Login:
    case Route::Tags:
      return AuthMode::None;
    case Route::GetProfile:
    case Route::ListArticles:
    case Route::GetArticle:
    case Route::GetComments:
      return AuthMode::Optional;
    default:
      return AuthMode::Required;
  }
}

// ---- routing ----
struct Segs {
  std::string_view v[7];
  int n = 0;
};

// Splits "/api/..." into segments after "api". Returns false if the path does not start with /api/ or has too many.
bool split_path(std::string_view path, Segs& out) {
  if (!path.starts_with("/api/")) return false;
  path.remove_prefix(5);
  while (true) {
    std::size_t slash = path.find('/');
    if (out.n == 7) return false;
    out.v[out.n++] = path.substr(0, slash);
    if (slash == std::string_view::npos) return true;
    path.remove_prefix(slash + 1);
  }
}

// Route from method + segments. Wildcard values are returned (still percent-encoded) in w1/w2.
Route route_of(http::Method m, const Segs& s, std::string_view& w1, std::string_view& w2) {
  using http::Method;
  if (s.n == 0) return Route::None;
  std::string_view a = s.v[0];
  if (a == "articles") {
    if (s.n == 1) return m == Method::Get ? Route::ListArticles : m == Method::Post ? Route::CreateArticle : Route::None;
    w1 = s.v[1];
    if (w1.empty()) return Route::None;
    if (s.n == 2) {
      if (m == Method::Get) return w1 == "feed" ? Route::Feed : Route::GetArticle;
      if (m == Method::Put) return Route::UpdateArticle;
      if (m == Method::Delete) return Route::DeleteArticle;
      return Route::None;
    }
    if (s.n == 3) {
      if (s.v[2] == "favorite")
        return m == Method::Post ? Route::Favorite : m == Method::Delete ? Route::Unfavorite : Route::None;
      if (s.v[2] == "comments")
        return m == Method::Get ? Route::GetComments : m == Method::Post ? Route::CreateComment : Route::None;
      return Route::None;
    }
    if (s.n == 4 && s.v[2] == "comments" && m == Method::Delete && !s.v[3].empty()) {
      w2 = s.v[3];
      return Route::DeleteComment;
    }
    return Route::None;
  }
  if (a == "tags") return s.n == 1 && m == Method::Get ? Route::Tags : Route::None;
  if (a == "user") {
    if (s.n != 1) return Route::None;
    return m == Method::Get ? Route::GetUser : m == Method::Put ? Route::PutUser : Route::None;
  }
  if (a == "profiles") {
    if (s.n < 2 || s.v[1].empty()) return Route::None;
    w1 = s.v[1];
    if (s.n == 2) return m == Method::Get ? Route::GetProfile : Route::None;
    if (s.n == 3 && s.v[2] == "follow")
      return m == Method::Post ? Route::Follow : m == Method::Delete ? Route::Unfollow : Route::None;
    return Route::None;
  }
  if (a == "users") {
    if (s.n == 1) return m == Method::Post ? Route::Register : Route::None;
    if (s.n == 2 && s.v[1] == "login") return m == Method::Post ? Route::Login : Route::None;
  }
  return Route::None;
}

// Percent-decodes a view that points into the request's own buffer, in place.
bool decode_view(std::string_view& v, bool plus_is_space) {
  char* p = const_cast<char*>(v.data());
  long n = http::percent_decode_inplace(p, v.size(), plus_is_space);
  if (n < 0) return false;
  v = std::string_view(p, std::size_t(n));
  return true;
}

// ---- query string (Go's url.Query semantics: first value wins, malformed pairs are dropped) ----
struct ListQuery {
  bool has_limit = false, has_offset = false;
  std::string_view limit, offset, tag, author, favorited;
  bool has_tag = false, has_author = false, has_favorited = false;
};

void parse_query(std::string_view q, ListQuery& out) {
  while (!q.empty()) {
    std::size_t amp = q.find('&');
    std::string_view pair = q.substr(0, amp);
    q = amp == std::string_view::npos ? std::string_view{} : q.substr(amp + 1);
    if (pair.empty()) continue;
    std::size_t eq = pair.find('=');
    std::string_view k = pair.substr(0, eq), v = eq == std::string_view::npos ? std::string_view{} : pair.substr(eq + 1);
    if (k.find(';') != std::string_view::npos || v.find(';') != std::string_view::npos) continue;  // Go rejects ';'
    if (!decode_view(k, true) || !decode_view(v, true)) continue;
    if (k == "limit" && !out.has_limit) { out.has_limit = true; out.limit = v; }
    else if (k == "offset" && !out.has_offset) { out.has_offset = true; out.offset = v; }
    else if (k == "tag" && !out.has_tag) { out.has_tag = true; out.tag = v; }
    else if (k == "author" && !out.has_author) { out.has_author = true; out.author = v; }
    else if (k == "favorited" && !out.has_favorited) { out.has_favorited = true; out.favorited = v; }
  }
}

bool limit_offset(const ListQuery& q, Request* r) {
  r->limit = 20;
  r->offset = 0;
  if (q.has_limit) {
    std::int64_t n;
    if (!util::parse_uint(q.limit, n) || n < 1 || n > 100) return false;
    r->limit = n;
  }
  if (q.has_offset) {
    std::int64_t n;
    if (!util::parse_uint(q.offset, n)) return false;
    r->offset = n;
  }
  return true;
}

// ---- request bodies (the reference's readWrapper / optString / reqString) ----
const json::Node* wrapper(std::string_view body, std::string_view key) {
  if (!t_doc.parse(const_cast<char*>(body.data()), body.size())) return nullptr;
  const json::Node* root = t_doc.root();
  if (!root || root->type != json::Type::Object) return nullptr;
  const json::Node* inner = t_doc.get(root, key);
  if (!inner || inner->type != json::Type::Object) return nullptr;
  return inner;
}

// Absent or null -> present=false. A string -> its value. Anything else, or empty when non_empty -> error.
bool opt_string(const json::Node* obj, std::string_view key, bool non_empty, std::string_view& out, bool& present) {
  const json::Node* n = t_doc.get(obj, key);
  present = false;
  if (!n || n->type == json::Type::Null) return true;
  if (n->type != json::Type::String) return false;
  if (non_empty && n->len == 0) return false;
  out = json::as_string(n);
  present = true;
  return true;
}
bool req_string(const json::Node* obj, std::string_view key, std::string_view& out) {
  bool present;
  return opt_string(obj, key, true, out, present) && present;
}

// ---- JSON response pieces ----
// Writes a nullable text column.
bool col_text_nullable(JsonOut& o, pg::Row& row) {
  const char* v;
  std::int32_t n;
  if (!row.next(v, n)) return false;
  if (n < 0) o.null();
  else o.str(v, std::size_t(n));
  return true;
}
bool col_text(JsonOut& o, pg::Row& row) {
  const char* v;
  std::int32_t n;
  if (!row.next(v, n) || n < 0) return false;
  o.str(v, std::size_t(n));
  return true;
}
bool col_ts(JsonOut& o, pg::Row& row) {
  const char* v;
  std::int32_t n;
  if (!row.next(v, n) || n != 8) return false;
  o.pg_timestamp(pg::dec_int8(v));
  return true;
}
bool col_bool(JsonOut& o, pg::Row& row) {
  const char* v;
  std::int32_t n;
  if (!row.next(v, n) || n != 1) return false;
  o.boolean(pg::dec_bool(v));
  return true;
}
bool col_int8(pg::Row& row, std::int64_t& out) {
  const char* v;
  std::int32_t n;
  if (!row.next(v, n) || n != 8) return false;
  out = pg::dec_int8(v);
  return true;
}
bool col_skip(pg::Row& row) {
  const char* v;
  std::int32_t n;
  return row.next(v, n);
}
bool col_tags(JsonOut& o, pg::Row& row) {
  const char* v;
  std::int32_t n;
  if (!row.next(v, n)) return false;
  o.ch('[');
  if (n >= 0) {
    pg::TextArray a;
    if (!a.init(v, n)) return false;
    const char* s;
    std::int32_t l;
    bool first = true;
    while (a.next(s, l)) {
      if (!s) continue;
      if (!first) o.ch(',');
      first = false;
      o.str(s, std::size_t(l));
    }
  }
  o.ch(']');
  return true;
}

// Profile object from username, bio, image [, following column | constant].
bool write_author(JsonOut& o, pg::Row& row, int following_const) {
  o.lit("{\"username\":");
  if (!col_text(o, row)) return false;
  o.lit(",\"bio\":");
  if (!col_text_nullable(o, row)) return false;
  o.lit(",\"image\":");
  if (!col_text_nullable(o, row)) return false;
  o.lit(",\"following\":");
  if (following_const < 0) {
    if (!col_bool(o, row)) return false;
  } else {
    o.boolean(following_const != 0);
  }
  o.ch('}');
  return true;
}

// Article object; the row cursor is at `slug` (id already consumed).
bool write_article(JsonOut& o, pg::Row& row, bool with_body) {
  o.reserve(std::size_t(row.end - row.p) + 256);
  o.lit("{\"slug\":");
  if (!col_text(o, row)) return false;
  o.lit(",\"title\":");
  if (!col_text(o, row)) return false;
  o.lit(",\"description\":");
  if (!col_text(o, row)) return false;
  if (with_body) {
    o.lit(",\"body\":");
    if (!col_text(o, row)) return false;
  }
  o.lit(",\"createdAt\":");
  if (!col_ts(o, row)) return false;
  o.lit(",\"updatedAt\":");
  if (!col_ts(o, row)) return false;
  // tags come after timestamps in the row but JSON order is free
  o.lit(",\"tagList\":");
  if (!col_tags(o, row)) return false;
  std::int64_t fc;
  if (!col_int8(row, fc)) return false;
  o.lit(",\"favoritesCount\":");
  o.i64(fc);
  o.lit(",\"favorited\":");
  if (!col_bool(o, row)) return false;
  o.lit(",\"author\":");
  if (!write_author(o, row, -1)) return false;
  o.ch('}');
  return true;
}

// User object from id, username, email, bio, image with the given token.
bool write_user(JsonOut& o, pg::Row& row, std::string_view token, std::int64_t* id_out, bool issue_token, std::int64_t now) {
  std::int64_t id;
  if (!col_int8(row, id)) return false;
  if (id_out) *id_out = id;
  const char *uv, *ev;
  std::int32_t un, en;
  if (!row.next(uv, un) || un < 0 || !row.next(ev, en) || en < 0) return false;
  o.reserve(std::size_t(row.end - row.p) + std::size_t(un + en) + auth::kMaxTokenLen + 96);
  o.lit("{\"user\":{\"email\":");
  o.str(ev, std::size_t(en));
  o.lit(",\"token\":");
  if (issue_token) {
    char tok[auth::kMaxTokenLen];
    std::size_t tl = auth::issue(id, now, tok);
    o.str(tok, tl);
  } else {
    o.str(token);
  }
  o.lit(",\"username\":");
  o.str(uv, std::size_t(un));
  o.lit(",\"bio\":");
  if (!col_text_nullable(o, row)) return false;
  o.lit(",\"image\":");
  if (!col_text_nullable(o, row)) return false;
  o.lit("}}");
  return true;
}

std::size_t list_initial_bytes(const Request* r) { return 512 + std::size_t(r->limit) * 768; }

void fail_row(Request* r) { r->out.failed = true; }

// ---- validation helpers per route ----
void bad(Loop& L, Request* r, std::string_view msg) { respond_error(L, r, 422, msg); }

// Copies tag views out of the per-thread JSON document into the request (heap, rare path).
bool collect_tags(const json::Node* arr, Request* r) {
  int n = 0;
  for (const json::Node* t = t_doc.first_child(arr); t; t = t_doc.next(t)) {
    if (t->type != json::Type::String || t->len == 0) return false;
    ++n;
  }
  if (n == 0) return true;
  r->tags = static_cast<std::string_view*>(std::malloc(sizeof(std::string_view) * std::size_t(n)));
  if (!r->tags) return false;
  int i = 0;
  for (const json::Node* t = t_doc.first_child(arr); t; t = t_doc.next(t)) r->tags[i++] = json::as_string(t);
  r->n_tags = n;
  return true;
}

void start_route(Loop& L, Request* r, std::string_view w1, std::string_view w2, std::string_view query,
                 std::string_view body) {
  switch (r->route) {
    case Route::Tags:
      enqueue_read(L, r, sql::kTags);
      return;
    case Route::GetUser:
      enqueue_read(L, r, sql::kUserById);
      return;
    case Route::GetProfile:
      r->s[0] = w1;
      enqueue_read(L, r, sql::kProfile);
      return;
    case Route::GetArticle:
      r->s[0] = w1;
      enqueue_read(L, r, sql::kArticleBySlug);
      return;
    case Route::GetComments:
      r->s[0] = w1;
      enqueue_read(L, r, sql::kComments);
      return;
    case Route::ListArticles:
    case Route::Feed: {
      ListQuery q;
      parse_query(query, q);
      if (!limit_offset(q, r)) {
        bad(L, r, "limit must be 1-100 and offset >= 0");
        return;
      }
      if (r->route == Route::Feed) {
        enqueue_read(L, r, sql::kFeed);
        return;
      }
      // The first non-empty filter in the order tag, author, favorited applies.
      if (q.has_tag && !q.tag.empty()) {
        r->s[0] = q.tag;
        enqueue_read(L, r, sql::kListTag);
      } else if (q.has_author && !q.author.empty()) {
        r->s[0] = q.author;
        enqueue_read(L, r, sql::kListAuthor);
      } else if (q.has_favorited && !q.favorited.empty()) {
        r->s[0] = q.favorited;
        enqueue_read(L, r, sql::kListFavorited);
      } else {
        enqueue_read(L, r, r->offset > cfg::kDeepOffset ? sql::kListAllDeep : sql::kListAll);
      }
      return;
    }
    case Route::Register: {
      const json::Node* u = wrapper(body, "user");
      if (!u) return bad(L, r, "invalid body");
      if (!req_string(u, "username", r->s[0]) || !req_string(u, "email", r->s[1]) || !req_string(u, "password", r->s[2]))
        return bad(L, r, "username, email and password are required");
      if (r->s[2].size() > 72) return bad(L, r, "password is too long");
      bcrypt_submit_hash(L, r, r->s[2]);
      return;
    }
    case Route::Login: {
      const json::Node* u = wrapper(body, "user");
      if (!u) return bad(L, r, "invalid body");
      if (!req_string(u, "email", r->s[0]) || !req_string(u, "password", r->s[1]))
        return bad(L, r, "email and password are required");
      enqueue_read(L, r, sql::kUserByEmail);
      return;
    }
    case Route::PutUser: {
      const json::Node* u = wrapper(body, "user");
      if (!u) return bad(L, r, "invalid body");
      static constexpr std::string_view kFields[5] = {"email", "username", "password", "bio", "image"};
      static constexpr bool kNonEmpty[5] = {true, true, true, false, false};
      for (int i = 0; i < 5; ++i) {
        bool present;
        if (!opt_string(u, kFields[i], kNonEmpty[i], r->s[i], present)) return bad(L, r, "invalid user fields");
        if (!present) r->s_null |= std::uint8_t(1u << i);
      }
      if (!(r->s_null & 4)) {
        if (r->s[2].size() > 72) return bad(L, r, "password is too long");
        bcrypt_submit_hash(L, r, r->s[2]);
        return;
      }
      enqueue_write(L, r, true);
      return;
    }
    case Route::Follow:
    case Route::Unfollow:
    case Route::Favorite:
    case Route::Unfavorite:
    case Route::DeleteArticle:
      r->s[0] = w1;
      enqueue_write(L, r, false);
      return;
    case Route::CreateComment: {
      r->s[0] = w1;
      const json::Node* c = wrapper(body, "comment");
      if (!c) return bad(L, r, "invalid body");
      if (!req_string(c, "body", r->s[1])) return bad(L, r, "comment body is required");
      enqueue_write(L, r, false);
      return;
    }
    case Route::DeleteComment: {
      r->s[0] = w1;
      std::int64_t id;
      if (!util::parse_uint(w2, id)) {
        // The reference matches {id} as any segment and fails its integer parse with 404.
        respond_error(L, r, 404, "comment not found");
        return;
      }
      r->num = id;
      enqueue_write(L, r, false);
      return;
    }
    case Route::CreateArticle: {
      const json::Node* a = wrapper(body, "article");
      if (!a) return bad(L, r, "invalid body");
      if (!req_string(a, "title", r->s[0]) || !req_string(a, "description", r->s[1]) || !req_string(a, "body", r->s[2]))
        return bad(L, r, "title, description and body are required");
      const json::Node* tl = t_doc.get(a, "tagList");
      if (tl && tl->type != json::Type::Null) {
        if (tl->type != json::Type::Array || !collect_tags(tl, r))
          return bad(L, r, "tagList must be an array of non-empty strings");
      }
      enqueue_write(L, r, true);
      return;
    }
    case Route::UpdateArticle: {
      r->s[0] = w1;
      const json::Node* a = wrapper(body, "article");
      if (!a) return bad(L, r, "invalid body");
      static constexpr std::string_view kFields[3] = {"title", "description", "body"};
      for (int i = 0; i < 3; ++i) {
        bool present;
        if (!opt_string(a, kFields[i], true, r->s[i + 1], present)) return bad(L, r, "invalid article fields");
        if (!present) r->s_null |= std::uint8_t(1u << (i + 1));
      }
      enqueue_write(L, r, false);
      return;
    }
    default:
      respond_error(L, r, 404, "not found");
      return;
  }
}

std::int64_t sat_add(std::int64_t a, std::int64_t b) { return a > INT64_MAX - b ? INT64_MAX : a + b; }


}  // namespace

// ---------------------------------------------------------------------------------------------------------------

void handle_http(Loop& L, ClientConn& c, std::uint32_t slot, const http::Request& hr, const char* raw) {
  Request* r = request_alloc(L);
  if (!r) return;  // caller sees no active request and drops the connection
  r->slot = slot;
  r->keep_alive = hr.keep_alive;
  c.active = r;
  if (!buf_alloc(L.pool, r->in, hr.total_len ? hr.total_len : 1)) {
    respond_error(L, r, 503, "server busy");
    return;
  }
  std::memcpy(r->in.p, raw, hr.total_len);
  auto rebase = [&](std::string_view v) {
    return v.empty() ? std::string_view{} : std::string_view(r->in.p + (v.data() - raw), v.size());
  };
  std::string_view path = rebase(hr.path), query = rebase(hr.query), body = rebase(hr.body);

  Segs segs;
  std::string_view w1, w2;
  r->route = split_path(path, segs) ? route_of(hr.method, segs, w1, w2) : Route::None;
  if (r->route == Route::None) {
    respond_error(L, r, 404, "not found");
    return;
  }
  // Wildcard path segments are percent-decoded (not '+'); a malformed escape is a bad request.
  if ((!w1.empty() && !decode_view(w1, false)) || (!w2.empty() && !decode_view(w2, false))) {
    respond_error(L, r, 400, "bad path escape");
    return;
  }

  AuthMode mode = auth_mode(r->route);
  if (mode != AuthMode::None) {
    bool ok = false;
    if (hr.has_authorization) {
      std::string_view h = rebase(hr.authorization);
      if (h.starts_with("Token ")) {
        std::string_view tok = h.substr(6);
        std::int64_t id;
        if (auth::verify(tok, L.now_s, id) == auth::TokenStatus::Ok) {
          r->viewer = id;
          r->token = tok;
          ok = true;
        }
      }
    }
    if (!ok && (mode == AuthMode::Required || hr.has_authorization)) {
      respond_error(L, r, 401, "unauthorized");
      return;
    }
  }
  start_route(L, r, w1, w2, query, body);
}

int params_of(const Request* r, std::uint8_t stmt, Param out[6]) {
  int n = 0;
  auto i8 = [&](std::int64_t v) { out[n].kind = Param::Int8; out[n].i = v; ++n; };
  auto tx = [&](std::string_view v) { out[n].kind = Param::Text; out[n].s = v; ++n; };
  auto tx_or_null = [&](int i) {
    if (r->s_null & (1u << i)) { out[n].kind = Param::Null; ++n; }
    else tx(r->s[i]);
  };
  switch (stmt) {
    case sql::kTags: break;
    case sql::kUserById: i8(r->viewer); break;
    case sql::kUserByEmail: tx(r->s[0]); break;
    case sql::kProfile:
    case sql::kArticleBySlug:
    case sql::kComments:
    case sql::kFavorite:
    case sql::kUnfavorite:
    case sql::kFollow:
    case sql::kUnfollow:
      i8(r->viewer);
      tx(r->s[0]);
      break;
    case sql::kArticleById:
      i8(r->viewer);
      i8(r->r_id);
      break;
    case sql::kListAll:
    case sql::kListAllDeep:
      i8(r->viewer);
      i8(r->limit);
      i8(r->offset);
      break;
    case sql::kListTag:
    case sql::kListAuthor:
    case sql::kListFavorited:
      i8(r->viewer);
      i8(r->limit);
      i8(r->offset);
      tx(r->s[0]);
      break;
    case sql::kFeed:
      i8(r->viewer);
      i8(r->limit);
      i8(r->offset);
      i8(sat_add(r->limit, r->offset));
      break;
    case sql::kCommentCreate:
      tx(r->s[0]);
      i8(r->viewer);
      tx(r->s[1]);
      break;
    case sql::kCommentDelete:
      i8(r->num);
      tx(r->s[0]);
      i8(r->viewer);
      break;
    case sql::kArticleCreate:
      i8(r->viewer);
      tx(r->s[0]);
      tx(r->s[1]);
      tx(r->s[2]);
      out[n].kind = Param::TextArray;
      out[n].items = r->tags;
      out[n].n_items = r->n_tags;
      ++n;
      break;
    case sql::kArticleUpdate:
      tx(r->s[0]);
      tx_or_null(1);
      tx_or_null(2);
      tx_or_null(3);
      i8(r->viewer);
      break;
    case sql::kArticleDelete:
      tx(r->s[0]);
      i8(r->viewer);
      break;
    case sql::kUserInsert:
      tx(r->s[0]);
      tx(r->s[1]);
      tx(std::string_view(r->hash, r->hash_len));
      break;
    case sql::kUserUpdate:
      i8(r->viewer);
      tx_or_null(0);
      tx_or_null(1);
      if (r->s_null & 4) { out[n].kind = Param::Null; ++n; }
      else tx(std::string_view(r->hash, r->hash_len));
      tx_or_null(3);
      tx_or_null(4);
      break;
    default: break;
  }
  return n;
}

void encode_params(pg::Bind& b, Request* r, std::uint8_t stmt) {
  Param ps[6];
  int n = params_of(r, stmt, ps);
  for (int k = 0; k < n; ++k) {
    switch (ps[k].kind) {
      case Param::Int8: b.int8(ps[k].i); break;
      case Param::Text: b.text(ps[k].s); break;
      case Param::Null: b.null(); break;
      case Param::TextArray: b.text_array(ps[k].items, ps[k].n_items); break;
    }
  }
}

int write_stmts(const Request* r, std::uint8_t out[2]) {
  switch (r->route) {
    case Route::Favorite: out[0] = sql::kFavorite; out[1] = sql::kArticleBySlug; return 2;
    case Route::Unfavorite: out[0] = sql::kUnfavorite; out[1] = sql::kArticleBySlug; return 2;
    case Route::Follow: out[0] = sql::kFollow; return 1;
    case Route::Unfollow: out[0] = sql::kUnfollow; return 1;
    case Route::CreateComment: out[0] = sql::kCommentCreate; return 1;
    case Route::DeleteComment: out[0] = sql::kCommentDelete; return 1;
    case Route::DeleteArticle: out[0] = sql::kArticleDelete; return 1;
    case Route::UpdateArticle: out[0] = sql::kArticleUpdate; return 1;
    case Route::CreateArticle: out[0] = sql::kArticleCreate; return 1;
    case Route::Register: out[0] = sql::kUserInsert; return 1;
    case Route::PutUser: out[0] = sql::kUserUpdate; return 1;
    default: return 0;
  }
}

void on_row(Loop& L, Request* r, std::uint8_t stmt, pg::Row& row) {
  JsonOut& o = r->out;
  if (o.failed) return;
  switch (sql::base_kind(stmt)) {
    case sql::kTags: {
      if (!o.begin(L.pool, std::size_t(row.end - row.p) + 64)) return;
      o.lit("{\"tags\":");
      if (!col_tags(o, row)) return fail_row(r);
      o.ch('}');
      return;
    }
    case sql::kUserById:
    case sql::kUserByEmail:
    case sql::kUserInsert:
    case sql::kUserUpdate: {
      if (!o.begin(L.pool, std::size_t(row.end - row.p) + 512)) return;
      bool issue = r->route == Route::Login || r->route == Route::Register;
      if (!write_user(o, row, r->token, &r->r_id, issue, L.now_s)) return fail_row(r);
      if (stmt == sql::kUserByEmail) {
        const char* v;
        std::int32_t n;
        if (!row.next(v, n) || n < 0 || n >= std::int32_t(sizeof r->hash)) return fail_row(r);
        std::memcpy(r->hash, v, std::size_t(n));
        r->hash_len = std::uint8_t(n);
      }
      return;
    }
    case sql::kProfile:
    case sql::kFollow:
    case sql::kUnfollow: {
      if (!o.begin(L.pool, std::size_t(row.end - row.p) + 128)) return;
      o.lit("{\"profile\":");
      int fconst = stmt == sql::kProfile ? -1 : stmt == sql::kFollow ? 1 : 0;
      if (!write_author(o, row, fconst)) return fail_row(r);
      o.ch('}');
      return;
    }
    case sql::kArticleBySlug:
    case sql::kArticleById:
    case sql::kArticleCreate: {
      if (!o.begin(L.pool, std::size_t(row.end - row.p) + 512)) return;
      std::int64_t id;
      if (!col_int8(row, id)) return fail_row(r);
      r->r_id = id;
      o.lit("{\"article\":");
      if (!write_article(o, row, true)) return fail_row(r);
      o.ch('}');
      return;
    }
    case sql::kComments: {
      if (!(r->flags & kFlagListOpen)) {
        if (!o.begin(L.pool, 4096)) return;
        o.lit("{\"comments\":[");
        r->flags |= kFlagListOpen;
      }
      if (!col_skip(row)) return fail_row(r);  // article id
      const char* v;
      std::int32_t n;
      if (!row.next(v, n)) return fail_row(r);
      if (n < 0) return;  // article without comments
      if (n != 8) return fail_row(r);
      o.reserve(std::size_t(row.end - row.p) + 192);
      if (r->flags & kFlagNeedComma) o.ch(',');
      r->flags |= kFlagNeedComma;
      o.lit("{\"id\":");
      o.i64(pg::dec_int8(v));
      o.lit(",\"body\":");
      if (!col_text(o, row)) return fail_row(r);
      o.lit(",\"createdAt\":");
      if (!col_ts(o, row)) return fail_row(r);
      o.lit(",\"updatedAt\":");
      if (!col_ts(o, row)) return fail_row(r);
      o.lit(",\"author\":");
      if (!write_author(o, row, -1)) return fail_row(r);
      o.ch('}');
      return;
    }
    case sql::kListAll:
    case sql::kListTag:
    case sql::kListAuthor:
    case sql::kListFavorited:
    case sql::kFeed:
    case sql::kListAllDeep: {
      if (!(r->flags & kFlagListOpen)) {
        if (!o.begin(L.pool, list_initial_bytes(r))) return;
        o.lit("{\"articles\":[");
        r->flags |= kFlagListOpen;
      }
      std::int64_t count;
      if (!col_int8(row, count)) return fail_row(r);
      r->num = count;
      const char* v;
      std::int32_t n;
      if (!row.next(v, n)) return fail_row(r);
      if (n < 0) return;  // empty page: count only
      if (r->flags & kFlagNeedComma) o.ch(',');
      r->flags |= kFlagNeedComma;
      if (!write_article(o, row, false)) return fail_row(r);
      return;
    }
    case sql::kFavorite:
    case sql::kUnfavorite:
      r->flags |= kFlagExists;
      return;
    case sql::kCommentCreate: {
      if (!o.begin(L.pool, std::size_t(row.end - row.p) + 256)) return;
      std::int64_t id;
      if (!col_int8(row, id)) return fail_row(r);
      o.lit("{\"comment\":{\"id\":");
      o.i64(id);
      o.lit(",\"body\":");
      if (!col_text(o, row)) return fail_row(r);
      o.lit(",\"createdAt\":");
      if (!col_ts(o, row)) return fail_row(r);
      o.lit(",\"updatedAt\":");
      if (!col_ts(o, row)) return fail_row(r);
      o.lit(",\"author\":");
      if (!write_author(o, row, 0)) return fail_row(r);
      o.lit("}}");
      return;
    }
    case sql::kCommentDelete:
    case sql::kArticleDelete: {
      if (!col_int8(row, r->r_author)) return fail_row(r);
      return;
    }
    case sql::kArticleUpdate: {
      std::int64_t updated;
      if (!col_int8(row, r->r_id) || !col_int8(row, r->r_author) || !col_int8(row, updated)) return fail_row(r);
      r->num = updated;
      return;
    }
    default:
      return;
  }
}

void on_stmt_done(Loop& L, Request* r, std::uint8_t stmt) {
  (void)L;
  switch (sql::base_kind(stmt)) {
    case sql::kListAll:
    case sql::kListTag:
    case sql::kListAuthor:
    case sql::kListFavorited:
    case sql::kFeed:
    case sql::kListAllDeep:
      if (r->flags & kFlagListOpen) {
        r->out.lit("],\"articlesCount\":");
        r->out.i64(r->num);
        r->out.ch('}');
      }
      return;
    case sql::kComments:
      if (r->flags & kFlagListOpen) r->out.lit("]}");
      return;
    case sql::kFavorite:
    case sql::kUnfavorite:
      r->got_row = false;  // the article read-back that follows decides got_row for the response body
      return;
    default:
      return;
  }
}

void on_read_done(Loop& L, Request* r, bool ok) {
  if (!ok || r->out.failed) {
    respond_error(L, r, 500, "internal error");
    return;
  }
  switch (r->route) {
    case Route::Tags:
    case Route::ListArticles:
    case Route::Feed:
      r->status = 200;
      if (!r->got_row) return respond_error(L, r, 500, "internal error");
      respond(L, r);
      return;
    case Route::GetProfile:
    case Route::GetArticle:
    case Route::GetComments:
      if (!r->got_row) return respond_error(L, r, 404, "not found");
      r->status = 200;
      respond(L, r);
      return;
    case Route::GetUser:
      if (!r->got_row) return respond_error(L, r, 401, "unauthorized");
      r->status = 200;
      respond(L, r);
      return;
    case Route::Login:
      if (!r->got_row) return respond_error(L, r, 401, "invalid email or password");
      bcrypt_submit_verify(L, r, r->s[1]);
      return;
    case Route::UpdateArticle:  // stage 2: the updated article (its slug may have changed)
      if (!r->got_row) return respond_error(L, r, 404, "article not found");
      r->status = 200;
      respond(L, r);
      return;
    default:
      respond_error(L, r, 500, "internal error");
      return;
  }
}

void on_bcrypt_done(Loop& L, Request* r, bool ok) {
  switch (r->route) {
    case Route::Login:
      if (!ok) return respond_error(L, r, 401, "invalid email or password");
      r->status = 200;
      respond(L, r);
      return;
    case Route::Register:
    case Route::PutUser:
      if (!ok) return respond_error(L, r, 500, "password hashing failed");
      enqueue_write(L, r, true);
      return;
    default:
      respond_error(L, r, 500, "internal error");
      return;
  }
}

namespace {

void finish_write(Loop& L, Request* r) {
  if (r->out.failed) return respond_error(L, r, 500, "internal error");
  switch (r->route) {
    case Route::Favorite:
    case Route::Unfavorite:
      if (!(r->flags & kFlagExists) || !r->got_row) return respond_error(L, r, 404, "article not found");
      r->status = 200;
      return respond(L, r);
    case Route::Follow:
    case Route::Unfollow:
      if (!r->got_row) return respond_error(L, r, 404, "profile not found");
      r->status = 200;
      return respond(L, r);
    case Route::CreateComment:
      if (!r->got_row) return respond_error(L, r, 404, "article not found");
      r->status = 201;
      return respond(L, r);
    case Route::DeleteComment:
    case Route::DeleteArticle:
      if (!r->got_row) return respond_error(L, r, 404, "not found");
      if (r->r_author != r->viewer) return respond_error(L, r, 403, "not the author");
      r->status = 204;
      return respond(L, r);
    case Route::UpdateArticle:
      if (!r->got_row) return respond_error(L, r, 404, "article not found");
      if (r->r_author != r->viewer) return respond_error(L, r, 403, "not the author");
      r->got_row = false;
      enqueue_read(L, r, sql::kArticleById);
      return;
    case Route::CreateArticle:
      if (!r->got_row) return respond_error(L, r, 500, "internal error");
      r->status = 201;
      return respond(L, r);
    case Route::Register:
      if (!r->got_row) return respond_error(L, r, 500, "internal error");
      r->status = 201;
      return respond(L, r);
    case Route::PutUser:
      if (!r->got_row) return respond_error(L, r, 401, "unauthorized");
      r->status = 200;
      return respond(L, r);
    default:
      return respond_error(L, r, 500, "internal error");
  }
}

}  // namespace

void on_write_group_done(Loop& L, SyncGroup& g) {
  if (!g.failed) {
    for (std::uint32_t i = 0; i < g.n_reqs; ++i) finish_write(L, g.reqs[i]);
    return;
  }
  if (g.n_reqs > 1) {
    // The shared transaction rolled back: run each request alone so one failure cannot affect the others.
    for (std::uint32_t i = 0; i < g.n_reqs; ++i) {
      Request* r = g.reqs[i];
      r->out.release();
      r->got_row = false;
      r->flags = 0;
      ++L.stats.write_retries;
      enqueue_write(L, r, true);
    }
    return;
  }
  Request* r = g.reqs[0];
  if (std::memcmp(g.sqlstate, "23505", 5) == 0) return respond_error(L, r, 422, "username or email is already taken");
  bool transient = std::memcmp(g.sqlstate, "40P01", 5) == 0 || std::memcmp(g.sqlstate, "40001", 5) == 0;
  if (transient && !r->retried) {
    r->retried = true;
    r->out.release();
    r->got_row = false;
    r->flags = 0;
    ++L.stats.write_retries;
    enqueue_write(L, r, true);
    return;
  }
  respond_error(L, r, 500, "internal error");
}
