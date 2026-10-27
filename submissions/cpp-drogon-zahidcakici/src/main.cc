// HTTP: Drogon on HTTP_THREADS event loops (SO_REUSEPORT, one listener per loop). Every request goes through one
// pre-routing advice that does its own routing, validation and JWT verification, then hands the database side a Job;
// the database side answers whole batches at a time, one queued task per event loop.
#include <drogon/drogon.h>
#include <json/json.h>

#include <cstdio>
#include <cstdlib>
#include <sched.h>
#include <unistd.h>
#include <mutex>
#include <thread>
#include <unordered_set>

#include "common.h"

using namespace drogon;

Config cfg;

static std::string errBody(const char *m) { return std::string("{\"errors\":{\"body\":[\"") + m + "\"]}}"; }
const std::string E401 = errBody("unauthorized"), E401_LOGIN = errBody("invalid email or password"), E403 = errBody("forbidden"),
                  E404 = errBody("not found"), E422 = errBody("invalid request"), E422_TAKEN = errBody("username or email is already taken"),
                  E500 = errBody("internal error");

// ---------------------------------------------------------------------------------------------------------------
// event loops and replies

static std::mutex g_loopsM;
static std::vector<trantor::EventLoop *> g_loops;

static int loopIndex() {
  static thread_local int idx = -1;
  if (idx < 0) {
    trantor::EventLoop *l = trantor::EventLoop::getEventLoopOfCurrentThread();
    std::lock_guard<std::mutex> g(g_loopsM);
    for (size_t i = 0; i < g_loops.size(); i++) if (g_loops[i] == l) idx = (int)i;
    if (idx < 0) { idx = (int)g_loops.size(); g_loops.push_back(l); }
  }
  return idx;
}
static trantor::EventLoop *loopAt(int i) {
  std::lock_guard<std::mutex> g(g_loopsM);
  return g_loops[(size_t)i];
}

HttpResponsePtr makeResponse(int status, std::string &&body) {
  auto r = HttpResponse::newHttpResponse();
  r->setStatusCode((HttpStatusCode)status);
  if (status != 204) {
    r->setContentTypeCode(CT_APPLICATION_JSON);
    r->setBody(std::move(body));
  }
  return r;
}

void reply(Job *j, int status, std::string &&body) {
  auto resp = makeResponse(status, std::move(body));
  loopAt(j->loop)->queueInLoop([j, resp] {
    j->cb(resp);
    delete j;
  });
}

bool clientConnected(const Job *j) {
  auto c = j->conn.lock();
  return c && c->connected();
}

void dropJob(Job *j) {
  loopAt(j->loop)->queueInLoop([j] { delete j; });
}

void Replies::add(Job *j, int status, std::string &&body) {
  if ((size_t)j->loop >= per.size()) per.resize((size_t)j->loop + 1);
  per[(size_t)j->loop].emplace_back(j, makeResponse(status, std::move(body)));
}

void Replies::flush() {
  for (size_t i = 0; i < per.size(); i++) {
    if (per[i].empty()) continue;
    auto batch = std::make_shared<std::vector<std::pair<Job *, HttpResponsePtr>>>(std::move(per[i]));
    per[i].clear();
    loopAt((int)i)->queueInLoop([batch] {
      for (auto &[j, r] : *batch) {
        j->cb(r);
        delete j;
      }
    });
  }
}

// ---------------------------------------------------------------------------------------------------------------
// parsing helpers

static int hexv(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static bool validUtf8(std::string_view s) {
  size_t i = 0, n = s.size();
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { i++; continue; }
    size_t len;
    uint32_t cp;
    if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; }
    else return false;
    if (i + len > n) return false;
    for (size_t k = 1; k < len; k++) {
      unsigned char d = (unsigned char)s[i + k];
      if ((d & 0xC0) != 0x80) return false;
      cp = (cp << 6) | (d & 0x3F);
    }
    if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF)) || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
    i += len;
  }
  return true;
}

// invalid UTF-8 becomes U+FFFD, as Node's Buffer.toString('utf8') does
static std::string sanitizeUtf8(std::string_view s) {
  if (validUtf8(s)) return std::string(s);
  std::string o;
  o.reserve(s.size() + 16);
  size_t i = 0, n = s.size();
  while (i < n) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { o.push_back((char)c); i++; continue; }
    size_t len = (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 0;
    if (len && i + len <= n && validUtf8(s.substr(i, len))) { o.append(s.data() + i, len); i += len; continue; }
    o.append("\xEF\xBF\xBD");
    i++;
  }
  return o;
}

// decodeURIComponent (with plus = true: '+' is a space first, as in a query string); nullopt where it would throw
static std::optional<std::string> pctDecode(std::string_view s, bool plus) {
  if (s.find('%') == std::string_view::npos && (!plus || s.find('+') == std::string_view::npos)) return std::string(s);
  std::string o;
  o.reserve(s.size());
  for (size_t i = 0; i < s.size(); i++) {
    char c = s[i];
    if (c == '+' && plus) o.push_back(' ');
    else if (c == '%') {
      if (i + 2 >= s.size()) return std::nullopt;
      int h = hexv(s[i + 1]), l = hexv(s[i + 2]);
      if (h < 0 || l < 0) return std::nullopt;
      o.push_back((char)(h * 16 + l));
      i += 2;
    } else o.push_back(c);
  }
  if (!validUtf8(o)) return std::nullopt;
  return o;
}

// a non-negative decimal integer of at most 16 digits (and <= 2^53 - 1), or -1
static int64_t num(std::string_view s) {
  if (s.empty() || s.size() > 16) return -1;
  int64_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return -1;
    v = v * 10 + (c - '0');
  }
  return v <= 9007199254740991LL ? v : -1;
}

static bool parseJson(std::string_view body, Json::Value &v) {
  static thread_local std::unique_ptr<Json::CharReader> r = [] {
    Json::CharReaderBuilder b;
    Json::CharReaderBuilder::strictMode(&b.settings_);
    b.settings_["rejectDupKeys"] = false;
    b.settings_["strictRoot"] = false;
    return std::unique_ptr<Json::CharReader>(b.newCharReader());
  }();
  std::string s = sanitizeUtf8(body);
  std::string err;
  if (!r->parse(s.data(), s.data() + s.size(), &v, &err)) { v = Json::Value(); return false; }
  return true;
}

static bool nonEmpty(const Json::Value &x) { return x.isString() && x.asString().size() > 0; }
static bool optStr(const Json::Value &x) { return x.isNull() || x.isString(); }
static std::optional<std::string> optVal(const Json::Value &x) { return x.isString() ? std::optional<std::string>(x.asString()) : std::nullopt; }

// ---------------------------------------------------------------------------------------------------------------
// requests

struct Ctx {
  const HttpRequestPtr &req;
  AdviceCallback &cb;
  void send(int status, const std::string &body) { cb(makeResponse(status, std::string(body))); }
  Job *job(uint8_t k, int64_t v) {
    Job *j = new Job();
    j->k = k;
    j->v = v;
    j->cb = std::move(cb);
    j->conn = req->getConnectionPtr();
    j->loop = loopIndex();
    return j;
  }
  // viewer: user id, 0 for no header, -1 for an invalid token
  int64_t auth() {
    const std::string &h = req->getHeader("authorization");
    if (h.empty()) return 0;
    if (h.size() < 7 || h.compare(0, 6, "Token ") != 0) return -1;
    int64_t id = verifyToken(std::string_view(h).substr(6));
    return id == 0 ? -1 : id;
  }
  std::string token() { return req->getHeader("authorization").substr(6); }
  // the JSON body; false (and a 422 sent) if the body is over 1 MB
  bool body(Json::Value &v) {
    std::string_view b = req->body();
    if (b.size() > (1u << 20)) { send(422, E422); return false; }
    parseJson(b, v);
    return true;
  }
};

// fills limit / offset and the filter; false -> 422
static bool listQuery(const std::string &q, Job *j, bool feed) {
  j->lim = 20;
  j->off = 0;
  std::optional<std::string> tag, author, favorited;
  bool seenL = false, seenO = false;
  size_t p = 0;
  while (!q.empty() && p <= q.size()) {
    size_t amp = q.find('&', p);
    if (amp == std::string::npos) amp = q.size();
    std::string_view part(q.data() + p, amp - p);
    p = amp + 1;
    size_t eq = part.find('=');
    auto k = pctDecode(eq == std::string_view::npos ? part : part.substr(0, eq), true);
    std::string_view raw = eq == std::string_view::npos ? std::string_view() : part.substr(eq + 1);
    if (!k) continue;
    if (*k == "limit") {
      if (seenL) continue;
      seenL = true;
      auto d = pctDecode(raw, true);
      int64_t n = num(d ? *d : "");
      if (n < 1 || n > 100) return false;
      j->lim = (int)n;
    } else if (*k == "offset") {
      if (seenO) continue;
      seenO = true;
      auto d = pctDecode(raw, true);
      int64_t n = num(d ? *d : "");
      if (n < 0) return false;
      j->off = n;
    } else if (*k == "tag") { if (!tag) tag = pctDecode(raw, true).value_or(""); }
    else if (*k == "author") { if (!author) author = pctDecode(raw, true).value_or(""); }
    else if (*k == "favorited") { if (!favorited) favorited = pctDecode(raw, true).value_or(""); }
    if (amp == q.size()) break;
  }
  if (feed) { j->k = K_FEED; return true; }
  if (tag && !tag->empty()) { j->k = K_TAG; j->key = std::move(*tag); }
  else if (author && !author->empty()) { j->k = K_AUTHOR; j->key = std::move(*author); }
  else if (favorited && !favorited->empty()) { j->k = K_FAVORITED; j->key = std::move(*favorited); }
  else j->k = K_GLOBAL;
  return true;
}

static void handle(const HttpRequestPtr &req, AdviceCallback &&cb0, AdviceChainCallback &&) {
  AdviceCallback cb = std::move(cb0);
  Ctx c{req, cb};
  const std::string &path = req->getOriginalPath();
  const HttpMethod m = req->method();
  if (path.size() < 5 || path.compare(0, 5, "/api/") != 0) { c.send(404, E404); return; }
  // segments after /api/
  std::string_view seg[5];
  int ns = 0;
  {
    std::string_view rest(path.data() + 5, path.size() - 5);
    size_t p = 0;
    for (;;) {
      size_t s = rest.find('/', p);
      if (ns == 5) { c.send(404, E404); return; }
      if (s == std::string_view::npos) { seg[ns++] = rest.substr(p); break; }
      seg[ns++] = rest.substr(p, s - p);
      p = s + 1;
    }
  }
  auto param = [&](int i) { return pctDecode(seg[i], false); };

  if (seg[0] == "tags" && ns == 1) {
    if (m != Get) { c.send(404, E404); return; }
    submitRead(c.job(K_TAGS, 0));
    return;
  }

  if (seg[0] == "user" && ns == 1) {
    if (m == Get) {
      int64_t v = c.auth();
      if (v <= 0) { c.send(401, E401); return; }
      std::string tok = c.token();
      Job *j = c.job(K_USER, v);
      j->token = std::move(tok);
      submitRead(j);
      return;
    }
    if (m == Put) {
      int64_t v = c.auth();
      Json::Value b;
      if (!c.body(b)) return;
      if (v <= 0) { c.send(401, E401); return; }
      const Json::Value &u = b.isObject() ? b["user"] : Json::Value::nullSingleton();
      if (!u.isObject()) { c.send(422, E422); return; }
      const Json::Value &email = u["email"], &username = u["username"], &password = u["password"], &bio = u["bio"], &image = u["image"];
      if (!optStr(email) || !optStr(username) || !optStr(password) || !optStr(bio) || !optStr(image)) { c.send(422, E422); return; }
      if ((email.isString() && email.asString().empty()) || (username.isString() && username.asString().empty()) ||
          (password.isString() && password.asString().empty())) { c.send(422, E422); return; }
      std::string pw = password.isString() ? password.asString() : std::string();
      if (pw.size() > 72 || pw.find('\0') != std::string::npos) { c.send(422, E422); return; }
      std::string tok = c.token();
      Job *j = c.job(W_UPDUSER, v);
      j->token = std::move(tok);
      j->o1 = optVal(email);
      j->o2 = optVal(username);
      j->o4 = optVal(bio);
      j->o5 = optVal(image);
      j->password = std::move(pw);
      submitWrite(j);
      return;
    }
    c.send(404, E404);
    return;
  }

  if (seg[0] == "users" && m == Post && (ns == 1 || (ns == 2 && seg[1] == "login"))) {
    Json::Value b;
    if (!c.body(b)) return;
    const Json::Value &u = b.isObject() ? b["user"] : Json::Value::nullSingleton();
    if (ns == 1) {
      if (!u.isObject() || !nonEmpty(u["username"]) || !nonEmpty(u["email"]) || !nonEmpty(u["password"])) { c.send(422, E422); return; }
      std::string pw = u["password"].asString();
      if (pw.size() > 72 || pw.find('\0') != std::string::npos) { c.send(422, E422); return; }
      Job *j = c.job(W_REGISTER, 0);
      j->s1 = u["username"].asString();
      j->s2 = u["email"].asString();
      j->password = std::move(pw);
      submitWrite(j);
    } else {
      if (!u.isObject() || !nonEmpty(u["email"]) || !nonEmpty(u["password"])) { c.send(422, E422); return; }
      std::string pw = u["password"].asString();
      if (pw.size() > 72 || pw.find('\0') != std::string::npos) { c.send(401, E401_LOGIN); return; }
      Job *j = c.job(K_LOGIN, 0);
      j->key = u["email"].asString();
      j->password = std::move(pw);
      submitRead(j);
    }
    return;
  }

  if (seg[0] == "profiles" && (ns == 2 || (ns == 3 && seg[2] == "follow"))) {
    if (ns == 2) {
      if (m != Get) { c.send(404, E404); return; }
      int64_t v = c.auth();
      if (v < 0) { c.send(401, E401); return; }
      auto name = param(1);
      if (!name || name->empty()) { c.send(404, E404); return; }
      Job *j = c.job(K_PROFILE, v);
      j->key = std::move(*name);
      submitRead(j);
      return;
    }
    if (m != Post && m != Delete) { c.send(404, E404); return; }
    int64_t v = c.auth();
    if (v <= 0) { c.send(401, E401); return; }
    auto name = param(1);
    if (!name || name->empty()) { c.send(404, E404); return; }
    Job *j = c.job(m == Post ? W_FOLLOW : W_UNFOLLOW, v);
    j->key = std::move(*name);
    submitWrite(j);
    return;
  }

  if (seg[0] == "articles") {
    if (ns == 1) {
      if (m == Get) {
        int64_t v = c.auth();
        if (v < 0) { c.send(401, E401); return; }
        Job tmp;
        if (!listQuery(req->query(), &tmp, false)) { c.send(422, E422); return; }
        Job *j = c.job(tmp.k, v);
        j->key = std::move(tmp.key);
        j->lim = tmp.lim;
        j->off = tmp.off;
        submitRead(j);
        return;
      }
      if (m == Post) {
        int64_t v = c.auth();
        Json::Value b;
        if (!c.body(b)) return;
        if (v <= 0) { c.send(401, E401); return; }
        const Json::Value &a = b.isObject() ? b["article"] : Json::Value::nullSingleton();
        if (!a.isObject() || !nonEmpty(a["title"]) || !nonEmpty(a["description"]) || !nonEmpty(a["body"])) { c.send(422, E422); return; }
        const Json::Value &tl = a["tagList"];
        std::vector<std::string> tags;
        if (!tl.isNull()) {
          if (!tl.isArray()) { c.send(422, E422); return; }
          std::unordered_set<std::string> seen;
          for (const auto &t : tl) {
            if (!nonEmpty(t)) { c.send(422, E422); return; }
            std::string s = t.asString();
            if (seen.insert(s).second) tags.push_back(std::move(s));
          }
        }
        Job *j = c.job(W_NEWART, v);
        j->s1 = a["title"].asString();
        j->s2 = a["description"].asString();
        j->s3 = a["body"].asString();
        j->tags = std::move(tags);
        submitWrite(j);
        return;
      }
      c.send(404, E404);
      return;
    }
    if (ns == 2 && seg[1] == "feed" && m == Get) {
      int64_t v = c.auth();
      if (v <= 0) { c.send(401, E401); return; }
      Job tmp;
      if (!listQuery(req->query(), &tmp, true)) { c.send(422, E422); return; }
      Job *j = c.job(K_FEED, v);
      j->lim = tmp.lim;
      j->off = tmp.off;
      submitRead(j);
      return;
    }
    if (ns == 2) {
      if (m == Get) {
        int64_t v = c.auth();
        if (v < 0) { c.send(401, E401); return; }
        auto slug = param(1);
        if (!slug || slug->empty()) { c.send(404, E404); return; }
        Job *j = c.job(K_SLUG, v);
        j->key = std::move(*slug);
        submitRead(j);
        return;
      }
      if (m == Put) {
        int64_t v = c.auth();
        auto slug = param(1);
        Json::Value b;
        if (!c.body(b)) return;
        if (v <= 0) { c.send(401, E401); return; }
        const Json::Value &a = b.isObject() ? b["article"] : Json::Value::nullSingleton();
        if (!a.isObject()) { c.send(422, E422); return; }
        const Json::Value &t = a["title"], &d = a["description"], &bd = a["body"];
        if (!optStr(t) || !optStr(d) || !optStr(bd) || (t.isString() && t.asString().empty()) || (d.isString() && d.asString().empty()) ||
            (bd.isString() && bd.asString().empty())) { c.send(422, E422); return; }
        if (!slug || slug->empty()) { c.send(404, E404); return; }
        Job *j = c.job(W_UPDART, v);
        j->key = std::move(*slug);
        j->o1 = optVal(t);
        j->o2 = optVal(d);
        j->o3 = optVal(bd);
        submitWrite(j);
        return;
      }
      if (m == Delete) {
        int64_t v = c.auth();
        if (v <= 0) { c.send(401, E401); return; }
        auto slug = param(1);
        if (!slug || slug->empty()) { c.send(404, E404); return; }
        Job *j = c.job(W_DELART, v);
        j->key = std::move(*slug);
        submitWrite(j);
        return;
      }
      c.send(404, E404);
      return;
    }
    if (ns == 3 && seg[2] == "favorite" && (m == Post || m == Delete)) {
      int64_t v = c.auth();
      if (v <= 0) { c.send(401, E401); return; }
      auto slug = param(1);
      if (!slug || slug->empty()) { c.send(404, E404); return; }
      Job *j = c.job(m == Post ? W_FAV : W_UNFAV, v);
      j->key = std::move(*slug);
      submitWrite(j);
      return;
    }
    if (ns == 3 && seg[2] == "comments") {
      if (m == Get) {
        int64_t v = c.auth();
        if (v < 0) { c.send(401, E401); return; }
        auto slug = param(1);
        if (!slug || slug->empty()) { c.send(404, E404); return; }
        Job *j = c.job(K_COMMENTS, v);
        j->key = std::move(*slug);
        submitRead(j);
        return;
      }
      if (m == Post) {
        int64_t v = c.auth();
        auto slug = param(1);
        Json::Value b;
        if (!c.body(b)) return;
        if (v <= 0) { c.send(401, E401); return; }
        const Json::Value &cm = b.isObject() ? b["comment"] : Json::Value::nullSingleton();
        if (!cm.isObject() || !nonEmpty(cm["body"])) { c.send(422, E422); return; }
        if (!slug || slug->empty()) { c.send(404, E404); return; }
        Job *j = c.job(W_NEWCMT, v);
        j->key = std::move(*slug);
        j->s1 = cm["body"].asString();
        submitWrite(j);
        return;
      }
      c.send(404, E404);
      return;
    }
    if (ns == 4 && seg[2] == "comments" && m == Delete) {
      int64_t v = c.auth();
      if (v <= 0) { c.send(401, E401); return; }
      auto slug = param(1);
      int64_t id = num(seg[3]);
      if (!slug || slug->empty() || id < 1) { c.send(404, E404); return; }
      Job *j = c.job(W_DELCMT, v);
      j->key = std::move(*slug);
      j->id = id;
      submitWrite(j);
      return;
    }
  }
  c.send(404, E404);
}

// ---------------------------------------------------------------------------------------------------------------

static int envInt(const char *k, int d) {
  const char *v = getenv(k);
  return v && *v ? atoi(v) : d;
}

int main() {
  const char *db = getenv("DATABASE_URL"), *secret = getenv("JWT_SECRET");
  if (!db || !secret) { fprintf(stderr, "DATABASE_URL and JWT_SECRET are required\n"); return 1; }
  // CPUs this process may run on (as Node's os.availableParallelism)
  int cpus = 0;
  cpu_set_t set;
  if (sched_getaffinity(0, sizeof set, &set) == 0) cpus = CPU_COUNT(&set);
  if (cpus < 1) cpus = (int)std::thread::hardware_concurrency();
  if (cpus < 1) cpus = 1;
  cfg.databaseUrl = db;
  cfg.jwtSecret = secret;
  cfg.host = getenv("HOST") && *getenv("HOST") ? getenv("HOST") : "0.0.0.0";
  cfg.port = envInt("PORT", 80);
  cfg.httpThreads = envInt("HTTP_THREADS", std::max(1, cpus / 4));
  cfg.readLanes = envInt("READ_LANES", std::max(1, cpus / 2));
  cfg.windowMs = envInt("READ_WINDOW_MS", 40);
  cfg.readMax = envInt("READ_MAX", 2048);
  cfg.writeMax = envInt("WRITE_MAX", 256);
  cfg.bcryptThreads = envInt("BCRYPT_THREADS", 2);
  cfg.bcryptLanes = envInt("BCRYPT_LANES", 0);
  cfg.bcryptWaitMs = envInt("BCRYPT_WAIT_MS", 200);
  cfg.idleTimeoutS = envInt("IDLE_TIMEOUT_S", 120);
  cfg.stats = envInt("STATS", 0) == 1;
  if (cfg.readLanes + 1 > 95) { fprintf(stderr, "more than 95 Postgres connections\n"); return 1; }

  jwtInit(cfg.jwtSecret);
  bcryptStart();
  dbStart();

  app()
      .setThreadNum((size_t)cfg.httpThreads)
      .setLogLevel(envInt("LOG_DEBUG", 0) ? trantor::Logger::kTrace : trantor::Logger::kWarn)
      .setIdleConnectionTimeout((size_t)cfg.idleTimeoutS)
      .setMaxConnectionNum(2000000)
      .setMaxConnectionNumPerIP(0)
      .setKeepaliveRequestsNumber(0)
      .setPipeliningRequestsNumber(0)
      .enableServerHeader(false)
      .enableDateHeader(false)
      .enableGzip(false)
      .setClientMaxBodySize(4 << 20)
      .setUploadPath("/tmp")
      .registerPreRoutingAdvice(handle)
      .addListener(cfg.host, (uint16_t)cfg.port);
  app().enableReusePort(true);
  fprintf(stderr, "listening on %s:%d: %d HTTP threads, %d read connections + 1 write connection, read window %d ms, %d bcrypt threads\n",
          cfg.host.c_str(), cfg.port, cfg.httpThreads, cfg.readLanes, cfg.windowMs, cfg.bcryptThreads);
  app().run();
  // not reached unless the server could not start; don't run static destructors under live threads
  fprintf(stderr, "server stopped\n");
  fflush(stderr);
  _exit(1);
}
