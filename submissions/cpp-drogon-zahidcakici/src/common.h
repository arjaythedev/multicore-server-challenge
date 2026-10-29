// Shared types: the request as the database side sees it (Job), settings, and the JSON byte writer.
#pragma once
#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include <drogon/HttpResponse.h>
#include <trantor/net/EventLoop.h>
#include <trantor/net/TcpConnection.h>

// read kinds (batched by the planner)
enum : uint8_t { K_TAGS, K_USER, K_LOGIN, K_PROFILE, K_SLUG, K_ID, K_COMMENTS, K_GLOBAL, K_TAG, K_AUTHOR, K_FAVORITED, K_FEED };
// write kinds (group commit)
enum : uint8_t { W_REGISTER, W_UPDUSER, W_FOLLOW, W_UNFOLLOW, W_FAV, W_UNFAV, W_NEWART, W_UPDART, W_DELART, W_NEWCMT, W_DELCMT };

using Callback = std::function<void(const drogon::HttpResponsePtr &)>;

struct Job {
  uint8_t k = 0;      // kind
  int64_t v = 0;      // viewer, 0 = anonymous
  std::string key;    // slug, username, email or tag
  int64_t id = 0;     // article id (K_ID), comment id (W_DELCMT)
  int lim = 0;
  int64_t off = 0;
  int status = 200;   // status of a successful K_ID read (200, or 201 after a create)
  std::string token;  // the presented token (GET/PUT /api/user)
  // write payload: register (s1 username, s2 email), upduser (o1..o5), follow (key), articles (key slug, o1..o3)
  std::string s1, s2, s3;
  std::optional<std::string> o1, o2, o3, o4, o5;
  std::vector<std::string> tags;
  std::string password, hash;  // the plain password is wiped once hashed or verified
  // planner scratch
  int i = 0, j = 0;
  // where the answer goes
  Callback cb;
  std::weak_ptr<trantor::TcpConnection> conn;
  int loop = 0;  // index of the HTTP event loop that owns the connection

  ~Job() { wipe(password); }
  static void wipe(std::string &s) {
    volatile char *p = s.data();
    for (size_t n = 0; n < s.size(); n++) p[n] = 0;
    s.clear();
  }
};

struct Config {
  std::string databaseUrl, jwtSecret, host;
  int port = 80;
  int httpThreads = 2;
  int readLanes = 4;
  int windowMs = 40;
  int readMax = 2048;
  int writeMax = 256;
  int bcryptThreads = 2;
  int bcryptLanes = 0;  // 0: calibrate
  int bcryptWaitMs = 200;
  int idleTimeoutS = 120;
  bool stats = false;
};
extern Config cfg;

// ---- responses ----
// Answer one request from any thread: the response is handed to its connection's event loop.
void reply(Job *j, int status, std::string &&body);
// Collects answers of one batch and hands each event loop its share in one queued task.
struct Replies {
  std::vector<std::vector<std::pair<Job *, drogon::HttpResponsePtr>>> per;
  void add(Job *j, int status, std::string &&body);
  void flush();
};
drogon::HttpResponsePtr makeResponse(int status, std::string &&body);
// whether the request's connection is still open; a dropped job is freed on its event loop
bool clientConnected(const Job *j);
void dropJob(Job *j);

extern const std::string E401, E401_LOGIN, E403, E404, E422, E422_TAKEN, E500;

// ---- JSON output ----
struct Out {
  std::string &s;
  explicit Out(std::string &t) : s(t) {}
  void lit(std::string_view x) { s.append(x.data(), x.size()); }
  void ch(char c) { s.push_back(c); }
  // a JSON string from raw bytes
  void str(const char *p, size_t n) {
    static const char HEX[] = "0123456789abcdef";
    s.push_back('"');
    size_t run = 0;
    for (size_t i = 0; i < n; i++) {
      unsigned char c = (unsigned char)p[i];
      if (c >= 0x20 && c != '"' && c != '\\') continue;
      s.append(p + run, i - run);
      run = i + 1;
      switch (c) {
        case '"': s.append("\\\"", 2); break;
        case '\\': s.append("\\\\", 2); break;
        case '\n': s.append("\\n", 2); break;
        case '\r': s.append("\\r", 2); break;
        case '\t': s.append("\\t", 2); break;
        case '\b': s.append("\\b", 2); break;
        case '\f': s.append("\\f", 2); break;
        default: {
          char u[6] = {'\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15]};
          s.append(u, 6);
        }
      }
    }
    s.append(p + run, n - run);
    s.push_back('"');
  }
  void str(std::string_view x) { str(x.data(), x.size()); }
  void strOrNull(const std::optional<std::string> &x) {
    if (x) str(*x); else lit("null");
  }
  void num(int64_t v) {
    char b[24];
    int n = 0;
    uint64_t u = v < 0 ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
    do { b[n++] = (char)('0' + u % 10); u /= 10; } while (u);
    if (v < 0) s.push_back('-');
    while (n) s.push_back(b[--n]);
  }
  void boolean(bool b) { if (b) lit("true"); else lit("false"); }
  // a timestamptz in binary format (microseconds since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ" (truncated)
  void ts(int64_t us) {
    int64_t ms = us >= 0 ? us / 1000 : -((-us + 999) / 1000);
    int64_t secs = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000);
    int msr = (int)(ms - secs * 1000);
    int64_t days = secs >= 0 ? secs / 86400 : -((-secs + 86399) / 86400);
    int sod = (int)(secs - days * 86400);
    // civil from days (Howard Hinnant), days since 1970-01-01
    int64_t z = days + 10957 + 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    unsigned doe = (unsigned)(z - era * 146097);
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t y = (int64_t)yoe + era * 400;
    unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    unsigned d = doy - (153 * mp + 2) / 5 + 1;
    unsigned m = mp < 10 ? mp + 3 : mp - 9;
    if (m <= 2) y++;
    char b[27];
    int yy = (int)y;
    b[0] = '"';
    b[1] = (char)('0' + yy / 1000 % 10); b[2] = (char)('0' + yy / 100 % 10); b[3] = (char)('0' + yy / 10 % 10); b[4] = (char)('0' + yy % 10);
    b[5] = '-'; b[6] = (char)('0' + m / 10); b[7] = (char)('0' + m % 10);
    b[8] = '-'; b[9] = (char)('0' + d / 10); b[10] = (char)('0' + d % 10);
    int hh = sod / 3600, mi = sod / 60 % 60, ss = sod % 60;
    b[11] = 'T'; b[12] = (char)('0' + hh / 10); b[13] = (char)('0' + hh % 10);
    b[14] = ':'; b[15] = (char)('0' + mi / 10); b[16] = (char)('0' + mi % 10);
    b[17] = ':'; b[18] = (char)('0' + ss / 10); b[19] = (char)('0' + ss % 10);
    b[20] = '.'; b[21] = (char)('0' + msr / 100); b[22] = (char)('0' + msr / 10 % 10); b[23] = (char)('0' + msr % 10);
    b[24] = 'Z'; b[25] = '"';
    s.append(b, 26);
  }
};

// ---- JWT (jwt.cc) ----
void jwtInit(const std::string &secret);
int64_t verifyToken(std::string_view tok);  // user id, or 0 if invalid
std::string issueToken(int64_t id);

// ---- bcrypt (bcrypt_pool.cc) ----
void bcryptStart();
// hash with a fresh random salt (empty result on failure); verify against a stored hash. cb runs on a bcrypt thread.
void bcryptHash(std::string pw, std::function<void(std::string)> cb);
void bcryptVerify(std::string pw, std::string stored, std::function<void(bool)> cb);

// ---- database side (db.cc) ----
void dbStart();
void submitRead(Job *j);
void submitWrite(Job *j);  // hashes the password first for register / profile update
