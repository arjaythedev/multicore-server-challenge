// The database side: one batch planner for the whole server with READ_LANES Postgres read connections (one thread
// each), one group-commit write connection (its own thread), and response assembly straight from libpq's binary
// results into JSON bytes.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

#include "common.h"
#include "pq.h"
#include "sql.h"

namespace {
using Clock = std::chrono::steady_clock;
using pq::Res;

const std::string GUCS_READ = "-c jit=off -c plan_cache_mode=force_generic_plan -c max_parallel_workers_per_gather=0";
const std::string GUCS_WRITE = "-c jit=off";

// distinct keys of one statement in one batch; index + 1 is the k the SQL tags rows with
template <class T>
struct Keys {
  std::unordered_map<T, int> map;
  std::vector<T> list;
  int idx(const T &k) {
    auto [it, fresh] = map.try_emplace(k, (int)list.size());
    if (fresh) list.push_back(k);
    return it->second;
  }
  int n() const { return (int)list.size(); }
};

// pages of one list kind: count keys and (key, limit, offset) page keys
struct ListKeys {
  Keys<std::string> count, page;
  std::vector<std::string> pkey;
  std::vector<int64_t> plim, poff;
  void add(const std::string &key, int lim, int64_t off, int &c, int &p) {
    c = count.idx(key);
    std::string pk = key;
    pk.push_back('\1'); pk += std::to_string(lim); pk.push_back('\1'); pk += std::to_string(off);
    int before = page.n();
    p = page.idx(pk);
    if (p == before) { pkey.push_back(key); plim.push_back(lim); poff.push_back(off); }
  }
};

struct PairHash {
  size_t operator()(const std::pair<int64_t, int64_t> &p) const {
    uint64_t h = (uint64_t)p.first * 0x9E3779B97F4A7C15ULL ^ ((uint64_t)p.second + 0x632BE59BD9B4E019ULL + ((uint64_t)p.first << 6));
    return (size_t)(h ^ (h >> 29));
  }
};
using PairSet = std::unordered_set<std::pair<int64_t, int64_t>, PairHash>;

// ---- JSON pieces ----
inline void col(Out &o, const Res &r, int row, int c) {
  if (r.null(row, c)) o.lit("null");
  else o.str(r.ptr(row, c), (size_t)r.len(row, c));
}
inline void profileObj(Out &o, const Res &r, int row, int cu, int cb, int ci, bool following) {
  o.lit("{\"username\":"); col(o, r, row, cu);
  o.lit(",\"bio\":"); col(o, r, row, cb);
  o.lit(",\"image\":"); col(o, r, row, ci);
  o.lit(",\"following\":"); o.boolean(following);
  o.ch('}');
}
inline void userJsonPg(Out &o, const Res &r, int row, int ce, int cu, int cb, int ci, std::string_view token) {
  o.lit("{\"user\":{\"email\":"); col(o, r, row, ce);
  o.lit(",\"token\":"); o.str(token);
  o.lit(",\"username\":"); col(o, r, row, cu);
  o.lit(",\"bio\":"); col(o, r, row, cb);
  o.lit(",\"image\":"); col(o, r, row, ci);
  o.lit("}}");
}

struct ReadLane;

// The batch clock: the first read to arrive opens a window; when it closes, everything waiting goes to a free lane
// as one batch (at most READ_MAX; a bigger backlog is split over several lanes). While one batch runs in Postgres
// the next one is collected.
class Planner {
 public:
  void start(int n);
  void push(Job *j) {
    {
      std::lock_guard<std::mutex> lk(m_);
      q_.push_back(j);
      if (due_ || open_) return;
      open_ = true;
      end_ = Clock::now() + std::chrono::milliseconds(cfg.windowMs);
    }
    cv_.notify_one();
  }
  void laneFree(ReadLane *l) {
    {
      std::lock_guard<std::mutex> lk(m_);
      free_.push_back(l);
    }
    cv_.notify_one();
  }
  size_t queued() { std::lock_guard<std::mutex> lk(m_); return q_.size(); }

 private:
  void loop();
  std::mutex m_;
  std::condition_variable cv_;
  std::deque<Job *> q_;
  std::vector<ReadLane *> free_;
  std::vector<ReadLane *> lanes_;
  bool open_ = false, due_ = false;
  Clock::time_point end_;
};

Planner planner;

std::atomic<uint64_t> stBatches{0}, stJobs{0}, stMax{0}, stWrites{0}, stGroups{0}, stPgUs{0};

struct ReadLane {
  pq::Conn pg;
  std::mutex m;
  std::condition_variable cv;
  std::vector<Job *> batch;
  bool has = false;
  Replies rep;
  std::vector<int> tagGen, tagPos;
  int gen = 0;
  pq::Params P;

  void give(std::vector<Job *> &&b) {
    {
      std::lock_guard<std::mutex> lk(m);
      batch = std::move(b);
      has = true;
    }
    cv.notify_one();
  }

  bool connect() {
    for (int attempt = 0;; attempt++) {
      if (pg.connect(cfg.databaseUrl, GUCS_READ) && pg.prepare(sql::read())) return true;
      if (attempt >= 30) return false;
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
  }

  void thread() {
    std::vector<Job *> jobs;
    for (;;) {
      {
        std::unique_lock<std::mutex> lk(m);
        cv.wait(lk, [&] { return has; });
        jobs = std::move(batch);
        batch.clear();
        has = false;
      }
      auto t0 = Clock::now();
      if (pg.dead() && !connect()) fail(jobs, "no connection");
      else run(jobs);
      pg.clear();
      if (cfg.stats) {
        stBatches++; stJobs += jobs.size();
        uint64_t mx = stMax.load();
        while (jobs.size() > mx && !stMax.compare_exchange_weak(mx, jobs.size())) {}
        stPgUs += (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - t0).count();
      }
      jobs.clear();
      planner.laneFree(this);
    }
  }

  void fail(std::vector<Job *> &jobs, const char *why) {
    fprintf(stderr, "[db] read batch failed: %s\n", why);
    for (Job *j : jobs) if (j) rep.add(j, 500, std::string(E500));
    rep.flush();
  }

  bool sendRound(int n, std::vector<Job *> &jobs) {
    if (!pg.run(n)) { fail(jobs, PQerrorMessage(pg.c)); return false; }
    for (int i = 0; i < n; i++) {
      if (!pg.res[i].ok()) { std::string e = pg.res[i].message(); fail(jobs, e.c_str()); return false; }
    }
    return true;
  }

  void run(std::vector<Job *> &jobs) {
    // ---- distinct keys ----
    bool wantTags = false;
    Keys<int64_t> uid, aid, feedC;
    Keys<std::string> uemail, prof, aslug, cmts, global, feedP;
    std::vector<int64_t> gLim, gOff, fpV, fpLim, fpOff;
    ListKeys lists[3];
    bool hasList[3] = {false, false, false};
    for (Job *j : jobs) {
      switch (j->k) {
        case K_TAGS: wantTags = true; break;
        case K_USER: j->i = uid.idx(j->v); break;
        case K_LOGIN: j->i = uemail.idx(j->key); break;
        case K_PROFILE: j->i = prof.idx(j->key); break;
        case K_SLUG: j->i = aslug.idx(j->key); break;
        case K_ID: j->i = aid.idx(j->id); break;
        case K_COMMENTS: j->i = cmts.idx(j->key); break;
        case K_GLOBAL: {
          int before = global.n();
          j->i = global.idx(std::to_string(j->lim) + '\1' + std::to_string(j->off));
          if (j->i == before) { gLim.push_back(j->lim); gOff.push_back(j->off); }
          break;
        }
        case K_TAG: case K_AUTHOR: case K_FAVORITED: {
          int f = j->k - K_TAG;
          hasList[f] = true;
          lists[f].add(j->key, j->lim, j->off, j->i, j->j);
          break;
        }
        case K_FEED: {
          j->i = feedC.idx(j->v);
          std::string pk = std::to_string(j->v);
          pk.push_back('\1'); pk += std::to_string(j->lim); pk.push_back('\1'); pk += std::to_string(j->off);
          int before = feedP.n();
          j->j = feedP.idx(pk);
          if (j->j == before) { fpV.push_back(j->v); fpLim.push_back(j->lim); fpOff.push_back(j->off); }
          break;
        }
      }
    }

    // ---- phase A ----
    int n = 0;
    auto q = [&](const char *name) {
      if (!pg.queue(name, P)) return false;
      P.clear();
      n++;
      return true;
    };
    bool ok = true;
    int sTags = -1, sUid = -1, sEmail = -1, sProf = -1, sSlug = -1, sAid = -1, sCmts = -1, sGlobal = -1, sFeed = -1;
    int sList[3] = {-1, -1, -1};
    P.clear();
    if (wantTags) { sTags = n; ok &= q("tags"); }
    if (uid.n()) { sUid = n; P.i64arr(uid.list); ok &= q("uid"); }
    if (uemail.n()) { sEmail = n; P.textarr(uemail.list); ok &= q("uemail"); }
    if (prof.n()) { sProf = n; P.textarr(prof.list); ok &= q("prof"); }
    if (aslug.n()) { sSlug = n; P.textarr(aslug.list); ok &= q("aslug"); }
    if (aid.n()) { sAid = n; P.i64arr(aid.list); ok &= q("aid"); }
    if (cmts.n()) { sCmts = n; P.textarr(cmts.list); ok &= q("cmts"); }
    if (global.n()) { sGlobal = n; P.i64arr(gLim); P.i64arr(gOff); ok &= q("global"); }
    static const char *LIST_STMT[3] = {"tag", "author", "favlist"};
    for (int f = 0; f < 3; f++) {
      if (!hasList[f]) continue;
      sList[f] = n;
      P.textarr(lists[f].count.list); P.textarr(lists[f].pkey); P.i64arr(lists[f].plim); P.i64arr(lists[f].poff);
      ok &= q(LIST_STMT[f]);
    }
    if (feedC.n()) { sFeed = n; P.i64arr(feedC.list); P.i64arr(fpV); P.i64arr(fpLim); P.i64arr(fpOff); ok &= q("feed"); }
    if (!ok) { fail(jobs, PQerrorMessage(pg.c)); return; }
    if (n == 0) { fail(jobs, "empty batch"); return; }
    if (!sendRound(n, jobs)) return;
    std::vector<Res> ra = std::move(pg.res);
    pg.res.clear();
    struct Guard { std::vector<Res> &r; ~Guard() { for (auto &x : r) if (x.r) PQclear(x.r); } } guard{ra};

    // ---- decode phase A ----
    auto firstRow = [&](int slot, int nkeys) {  // key index -> row (one row per key)
      std::vector<int> v((size_t)nkeys, -1);
      if (slot < 0) return v;
      const Res &r = ra[slot];
      for (int row = 0, e = r.n(); row < e; row++) {
        int64_t k = r.i64(row, 0);
        if (k >= 1 && k <= nkeys) v[(size_t)k - 1] = row;
      }
      return v;
    };
    std::vector<int> userRow = firstRow(sUid, uid.n()), emailRow = firstRow(sEmail, uemail.n()), profRow = firstRow(sProf, prof.n()),
                     slugRow = firstRow(sSlug, aslug.n()), idRow = firstRow(sAid, aid.n());
    std::vector<std::vector<int>> cmtRows;
    std::vector<char> cmtFound;
    if (sCmts >= 0) {
      cmtRows.resize((size_t)cmts.n());
      cmtFound.assign((size_t)cmts.n(), 0);
      const Res &r = ra[sCmts];
      for (int row = 0, e = r.n(); row < e; row++) {
        int64_t k = r.i64(row, 0);
        if (k < 1 || k > cmts.n()) continue;
        cmtFound[(size_t)k - 1] = 1;
        cmtRows[(size_t)k - 1].push_back(row);
      }
    }
    // list statements: k <= 0 -> count of key -k (k = 0: the one global count); k > 0 -> page row
    struct Decoded {
      int slot = -1;
      std::vector<int64_t> counts;
      std::vector<std::vector<int>> pages;
    };
    auto decodeList = [&](int slot, int ncount, int npage) {
      Decoded d;
      d.slot = slot;
      d.counts.assign((size_t)std::max(ncount, 1), 0);
      d.pages.resize((size_t)npage);
      if (slot >= 0) {
        const Res &r = ra[slot];
        for (int row = 0, e = r.n(); row < e; row++) {
          int64_t k = r.i64(row, 0);
          if (k <= 0) {
            int64_t i = k == 0 ? 0 : -k - 1;
            if (i < (int64_t)d.counts.size()) d.counts[(size_t)i] = r.i64(row, 1);
          } else if (k <= npage) d.pages[(size_t)k - 1].push_back(row);
        }
        for (auto &p : d.pages)
          if (p.size() > 1) std::sort(p.begin(), p.end(), [&](int x, int y) { return r.i64(x, 1) > r.i64(y, 1); });
      }
      return d;
    };
    Decoded G = decodeList(sGlobal, 1, global.n());
    Decoded L[3];
    for (int f = 0; f < 3; f++) if (hasList[f]) L[f] = decodeList(sList[f], lists[f].count.n(), lists[f].page.n());
    Decoded FD = decodeList(sFeed, feedC.n(), feedP.n());

    // ---- phase B keys: every article referenced, once; the viewer flags asked about ----
    std::unordered_map<int64_t, int> arts;
    std::vector<int64_t> artIds, artAuthors;
    PairSet favAsk, folAsk;
    auto addArt = [&](const Res &r, int row, int64_t v) {
      int64_t id = r.i64(row, 1), author = r.i64(row, 2);
      auto [it, fresh] = arts.try_emplace(id, (int)artIds.size());
      if (fresh) { artIds.push_back(id); artAuthors.push_back(author); }
      if (v != 0) { favAsk.emplace(v, id); folAsk.emplace(v, author); }
    };
    for (Job *j : jobs) {
      int64_t v = j->v;
      switch (j->k) {
        case K_SLUG: { int row = slugRow[(size_t)j->i]; if (row >= 0) addArt(ra[sSlug], row, v); break; }
        case K_ID: { int row = idRow[(size_t)j->i]; if (row >= 0) addArt(ra[sAid], row, v); break; }
        case K_GLOBAL: for (int row : G.pages[(size_t)j->i]) addArt(ra[sGlobal], row, v); break;
        case K_TAG: case K_AUTHOR: case K_FAVORITED: {
          Decoded &D = L[j->k - K_TAG];
          for (int row : D.pages[(size_t)j->j]) addArt(ra[D.slot], row, v);
          break;
        }
        case K_FEED: for (int row : FD.pages[(size_t)j->j]) addArt(ra[sFeed], row, v); break;
        case K_COMMENTS:
          if (v != 0 && sCmts >= 0) {
            const Res &r = ra[sCmts];
            for (int row : cmtRows[(size_t)j->i]) if (!r.null(row, 2)) folAsk.emplace(v, r.i64(row, 6));
          }
          break;
        case K_PROFILE:
          if (v != 0) { int row = profRow[(size_t)j->i]; if (row >= 0) folAsk.emplace(v, ra[sProf].i64(row, 1)); }
          break;
      }
    }

    int nb = 0, sArtx = -1, sTagn = -1, sFlags = -1;
    if (!artIds.empty()) {
      sArtx = nb; P.i64arr(artIds); P.i64arr(artAuthors); ok &= pg.queue("artx", P); P.clear(); nb++;
      sTagn = nb; P.i64arr(artIds); ok &= pg.queue("tagnames", P); P.clear(); nb++;
    }
    if (!favAsk.empty() || !folAsk.empty()) {
      std::vector<int64_t> fv, fa, ov, ou;
      fv.reserve(favAsk.size()); fa.reserve(favAsk.size()); ov.reserve(folAsk.size()); ou.reserve(folAsk.size());
      for (auto &p : favAsk) { fv.push_back(p.first); fa.push_back(p.second); }
      for (auto &p : folAsk) { ov.push_back(p.first); ou.push_back(p.second); }
      sFlags = nb; P.i64arr(fv); P.i64arr(fa); P.i64arr(ov); P.i64arr(ou); ok &= pg.queue("flags", P); P.clear(); nb++;
    }
    if (!ok) { fail(jobs, PQerrorMessage(pg.c)); return; }
    if (nb > 0 && !sendRound(nb, jobs)) return;
    const Res *rbx = sArtx >= 0 ? &pg.res[sArtx] : nullptr;
    const Res *rbt = sTagn >= 0 ? &pg.res[sTagn] : nullptr;
    const Res *rbf = sFlags >= 0 ? &pg.res[sFlags] : nullptr;

    // ---- assemble ----
    std::vector<int> artRow(artIds.size(), -1);
    if (rbx) for (int row = 0, e = rbx->n(); row < e; row++) {
      auto it = arts.find(rbx->i64(row, 0));
      if (it != arts.end()) artRow[(size_t)it->second] = row;
    }
    // tag id -> row of tagnames (rows are in name order)
    gen++;
    if (rbt) for (int row = 0, e = rbt->n(); row < e; row++) {
      int id = rbt->i32(row, 0);
      if (id < 0) continue;
      if ((size_t)id >= tagGen.size()) { size_t nn = std::max<size_t>(4096, tagGen.size()); while (nn <= (size_t)id) nn *= 2; tagGen.resize(nn, 0); tagPos.resize(nn, 0); }
      tagGen[(size_t)id] = gen;
      tagPos[(size_t)id] = row;
    }
    PairSet favSet, folSet;
    if (rbf) for (int row = 0, e = rbf->n(); row < e; row++) {
      if (rbf->i64(row, 0) == 0) favSet.emplace(rbf->i64(row, 1), rbf->i64(row, 2));
      else folSet.emplace(rbf->i64(row, 1), rbf->i64(row, 2));
    }
    std::vector<int> tagRows;
    // one Article object from a phase-A article row; false (nothing written) if its author vanished
    auto article = [&](Out &o, const Res &r, int row, bool full, int64_t v) {
      int64_t id = r.i64(row, 1), author = r.i64(row, 2);
      auto it = arts.find(id);
      int xr = it == arts.end() ? -1 : artRow[(size_t)it->second];
      if (xr < 0) return false;
      const Res &x = *rbx;
      o.lit("{\"slug\":"); col(o, r, row, 3);
      o.lit(",\"title\":"); col(o, r, row, 4);
      o.lit(",\"description\":"); col(o, r, row, 5);
      if (full) { o.lit(",\"body\":"); col(o, r, row, 8); }
      o.lit(",\"tagList\":[");
      // tag ids (int4[]), in name order
      if (!x.null(xr, 1) && x.len(xr, 1) > 12) {
        const char *b = x.ptr(xr, 1);
        if (pq::be32(b) == 1) {
          int cnt = pq::be32(b + 12);
          const char *p = b + 20;
          tagRows.clear();
          for (int t = 0; t < cnt; t++) {
            int tid = pq::be32(p + 4);
            p += 8;
            if (tid >= 0 && (size_t)tid < tagGen.size() && tagGen[(size_t)tid] == gen) tagRows.push_back(tagPos[(size_t)tid]);
          }
          if (tagRows.size() > 1) std::sort(tagRows.begin(), tagRows.end());
          for (size_t t = 0; t < tagRows.size(); t++) {
            if (t > 0) o.ch(',');
            col(o, *rbt, tagRows[t], 1);
          }
        }
      }
      o.lit("],\"createdAt\":"); o.ts(r.i64(row, 6));
      o.lit(",\"updatedAt\":"); o.ts(r.i64(row, 7));
      o.lit(",\"favorited\":"); o.boolean(v != 0 && favSet.count({v, id}));
      o.lit(",\"favoritesCount\":"); o.num(x.i64(xr, 2));
      o.lit(",\"author\":");
      profileObj(o, x, xr, 3, 4, 5, v != 0 && folSet.count({v, author}));
      o.ch('}');
      return true;
    };
    auto list = [&](Job *j, const Res &r, const std::vector<int> &rows, int64_t count) {
      std::string body;
      body.reserve(512 + rows.size() * 700);
      Out o(body);
      o.lit("{\"articles\":[");
      bool first = true;
      for (int row : rows) {
        size_t mark = body.size();
        if (!first) o.ch(',');
        if (article(o, r, row, false, j->v)) first = false;
        else body.resize(mark);
      }
      o.lit("],\"articlesCount\":"); o.num(count); o.ch('}');
      rep.add(j, 200, std::move(body));
    };

    for (Job *j : jobs) {
      int64_t v = j->v;
      switch (j->k) {
        case K_TAGS: {
          std::string body;
          Out o(body);
          o.lit("{\"tags\":[");
          const Res &r = ra[sTags];
          if (r.n() > 0 && !r.null(0, 0) && r.len(0, 0) > 12) {
            const char *b = r.ptr(0, 0);
            if (pq::be32(b) == 1) {
              int cnt = pq::be32(b + 12);
              const char *p = b + 20;
              for (int t = 0; t < cnt; t++) {
                int l = pq::be32(p);
                p += 4;
                if (t > 0) o.ch(',');
                o.str(p, (size_t)l);
                p += l;
              }
            }
          }
          o.lit("]}");
          rep.add(j, 200, std::move(body));
          break;
        }
        case K_USER: {
          int row = userRow[(size_t)j->i];
          if (row < 0) { rep.add(j, 401, std::string(E401)); break; }
          std::string body;
          Out o(body);
          userJsonPg(o, ra[sUid], row, 3, 2, 4, 5, j->token);
          rep.add(j, 200, std::move(body));
          break;
        }
        case K_LOGIN: {
          int row = emailRow[(size_t)j->i];
          if (row < 0) { rep.add(j, 401, std::string(E401_LOGIN)); break; }
          const Res &r = ra[sEmail];
          j->id = r.i64(row, 1);
          j->s1 = r.str(row, 2);
          j->s2 = r.str(row, 3);
          j->o1 = r.null(row, 4) ? std::nullopt : std::optional<std::string>(r.str(row, 4));
          j->o2 = r.null(row, 5) ? std::nullopt : std::optional<std::string>(r.str(row, 5));
          std::string hash = r.null(row, 6) ? std::string() : r.str(row, 6);
          std::string pw = std::move(j->password);
          j->password.clear();
          bcryptVerify(std::move(pw), std::move(hash), [j](bool ok) {
            if (!ok) { reply(j, 401, std::string(E401_LOGIN)); return; }
            std::string body;
            Out o(body);
            o.lit("{\"user\":{\"email\":"); o.str(j->s2);
            o.lit(",\"token\":"); o.str(issueToken(j->id));
            o.lit(",\"username\":"); o.str(j->s1);
            o.lit(",\"bio\":"); o.strOrNull(j->o1);
            o.lit(",\"image\":"); o.strOrNull(j->o2);
            o.lit("}}");
            reply(j, 200, std::move(body));
          });
          break;
        }
        case K_PROFILE: {
          int row = profRow[(size_t)j->i];
          if (row < 0) { rep.add(j, 404, std::string(E404)); break; }
          const Res &r = ra[sProf];
          std::string body;
          Out o(body);
          o.lit("{\"profile\":");
          profileObj(o, r, row, 2, 3, 4, v != 0 && folSet.count({v, r.i64(row, 1)}));
          o.ch('}');
          rep.add(j, 200, std::move(body));
          break;
        }
        case K_SLUG: case K_ID: {
          bool bySlug = j->k == K_SLUG;
          int row = bySlug ? slugRow[(size_t)j->i] : idRow[(size_t)j->i];
          const Res &r = ra[bySlug ? sSlug : sAid];
          std::string body;
          body.reserve(4096);
          Out o(body);
          o.lit("{\"article\":");
          if (row >= 0 && article(o, r, row, true, v)) { o.ch('}'); rep.add(j, j->status, std::move(body)); }
          else rep.add(j, 404, std::string(E404));
          break;
        }
        case K_COMMENTS: {
          if (sCmts < 0 || !cmtFound[(size_t)j->i]) { rep.add(j, 404, std::string(E404)); break; }
          const Res &r = ra[sCmts];
          std::vector<int> rows;
          for (int row : cmtRows[(size_t)j->i]) if (!r.null(row, 2) && !r.null(row, 7)) rows.push_back(row);
          if (rows.size() > 1)
            std::sort(rows.begin(), rows.end(), [&](int x, int y) {
              int64_t cx = r.i64(x, 4), cy = r.i64(y, 4);
              if (cx != cy) return cx > cy;
              return r.i64(x, 2) > r.i64(y, 2);
            });
          std::string body;
          body.reserve(64 + rows.size() * 400);
          Out o(body);
          o.lit("{\"comments\":[");
          for (size_t i = 0; i < rows.size(); i++) {
            int row = rows[i];
            if (i > 0) o.ch(',');
            o.lit("{\"id\":"); o.num(r.i64(row, 2));
            o.lit(",\"createdAt\":"); o.ts(r.i64(row, 4));
            o.lit(",\"updatedAt\":"); o.ts(r.i64(row, 5));
            o.lit(",\"body\":"); col(o, r, row, 3);
            o.lit(",\"author\":");
            profileObj(o, r, row, 7, 8, 9, v != 0 && folSet.count({v, r.i64(row, 6)}));
            o.ch('}');
          }
          o.lit("]}");
          rep.add(j, 200, std::move(body));
          break;
        }
        case K_GLOBAL: list(j, ra[sGlobal], G.pages[(size_t)j->i], G.counts[0]); break;
        case K_TAG: case K_AUTHOR: case K_FAVORITED: {
          Decoded &D = L[j->k - K_TAG];
          list(j, ra[D.slot], D.pages[(size_t)j->j], D.counts[(size_t)j->i]);
          break;
        }
        case K_FEED: list(j, ra[sFeed], FD.pages[(size_t)j->j], FD.counts[(size_t)j->i]); break;
      }
    }
    rep.flush();
  }
};

void Planner::start(int n) {
  for (int i = 0; i < n; i++) lanes_.push_back(new ReadLane());
  std::vector<std::thread> conns;
  bool okAll = true;
  std::mutex okm;
  for (ReadLane *l : lanes_) conns.emplace_back([l, &okAll, &okm] { if (!l->connect()) { std::lock_guard<std::mutex> g(okm); okAll = false; } });
  for (auto &t : conns) t.join();
  if (!okAll) { fprintf(stderr, "[db] cannot open the read connections\n"); exit(1); }
  for (ReadLane *l : lanes_) { std::thread([l] { l->thread(); }).detach(); free_.push_back(l); }
  std::thread([this] { loop(); }).detach();
}

void Planner::loop() {
  std::unique_lock<std::mutex> lk(m_);
  for (;;) {
    if (!due_) {
      if (!open_) { cv_.wait(lk); continue; }
      if (Clock::now() < end_) { cv_.wait_until(lk, end_); continue; }
      open_ = false;
      due_ = true;
    }
    if (q_.empty()) { due_ = false; continue; }
    if (free_.empty()) { cv_.wait(lk); continue; }
    ReadLane *lane = free_.back();
    free_.pop_back();
    std::vector<Job *> batch;
    size_t take = std::min(q_.size(), (size_t)cfg.readMax);
    batch.reserve(take);
    for (size_t i = 0; i < take; i++) {
      Job *j = q_.front();
      q_.pop_front();
      // a request whose client is gone is not worth a Postgres round trip
      if (!clientConnected(j)) { dropJob(j); continue; }
      batch.push_back(j);
    }
    if (q_.empty()) due_ = false;
    if (batch.empty()) { free_.push_back(lane); continue; }
    lk.unlock();
    lane->give(std::move(batch));
    lk.lock();
  }
}

// ---- the write lane: group commit ----
// Every write waiting while the previous group commits goes out as one implicit transaction (all statements before
// one Sync); responses are released after its ReadyForQuery, i.e. after COMMIT. If any statement fails the whole
// group rolls back and each write is retried on its own.
class WriteLane {
 public:
  void start() {
    if (!connect()) { fprintf(stderr, "[db] cannot open the write connection\n"); exit(1); }
    std::thread([this] { loop(); }).detach();
  }
  void push(Job *j) {
    {
      std::lock_guard<std::mutex> lk(m_);
      q_.push_back(j);
    }
    cv_.notify_one();
  }

 private:
  bool connect() {
    for (int attempt = 0;; attempt++) {
      if (pg_.connect(cfg.databaseUrl, GUCS_WRITE) && pg_.prepare(sql::write())) return true;
      if (attempt >= 30) return false;
      std::this_thread::sleep_for(std::chrono::seconds(1));
    }
  }
  void loop() {
    std::vector<Job *> group;
    for (;;) {
      {
        std::unique_lock<std::mutex> lk(m_);
        cv_.wait(lk, [&] { return !q_.empty(); });
        // a profile update can fail by design (unique violation), so it never shares a transaction
        if (q_.front()->k == W_UPDUSER) { group.push_back(q_.front()); q_.pop_front(); }
        else
          while (!q_.empty() && (int)group.size() < cfg.writeMax && q_.front()->k != W_UPDUSER) { group.push_back(q_.front()); q_.pop_front(); }
      }
      if (pg_.dead() && !connect()) {
        for (Job *j : group) rep_.add(j, 500, std::string(E500));
        rep_.flush();
      } else run(group);
      if (cfg.stats) { stGroups++; stWrites += group.size(); }
      group.clear();
    }
  }
  int bind(Job *j) {  // queues the statements of one write; returns how many
    auto q = [&](const char *name) { bool ok = pg_.queue(name, P_); P_.clear(); return ok ? 1 : -1000; };
    P_.clear();
    switch (j->k) {
      case W_REGISTER: P_.text(j->s1); P_.text(j->s2); P_.text(j->hash); return q("register");
      case W_UPDUSER: P_.i64(j->v); P_.textOpt(j->o1); P_.textOpt(j->o2); P_.textOpt(j->hash.empty() ? std::nullopt : std::optional<std::string>(j->hash)); P_.textOpt(j->o4); P_.textOpt(j->o5); return q("upduser");
      case W_FOLLOW: P_.i64(j->v); P_.text(j->key); return q("follow");
      case W_UNFOLLOW: P_.i64(j->v); P_.text(j->key); return q("unfollow");
      case W_FAV: P_.i64(j->v); P_.text(j->key); return q("fav");
      case W_UNFAV: P_.i64(j->v); P_.text(j->key); return q("unfav");
      case W_NEWART: {
        P_.i64(j->v); P_.text(j->s1); P_.text(j->s2); P_.text(j->s3);
        int n = q("newart");
        if (j->tags.empty()) return n;
        P_.textarr(j->tags); n += q("newtags");
        P_.textarr(j->tags); n += q("arttags");
        return n;
      }
      case W_UPDART: P_.text(j->key); P_.textOpt(j->o1); P_.textOpt(j->o2); P_.textOpt(j->o3); P_.i64(j->v); return q("updart");
      case W_DELART: P_.text(j->key); P_.i64(j->v); return q("delart");
      case W_NEWCMT: P_.text(j->key); P_.i64(j->v); P_.text(j->s1); return q("newcmt");
      case W_DELCMT: P_.i64(j->id); P_.text(j->key); P_.i64(j->v); return q("delcmt");
    }
    return 0;
  }
  static int stmtCount(const Job *j) { return j->k == W_NEWART && !j->tags.empty() ? 3 : 1; }

  void run(std::vector<Job *> &group) {
    std::vector<int> spans(group.size());
    int n = 0;
    bool ok = true;
    for (size_t i = 0; i < group.size(); i++) {
      spans[i] = n;
      int c = bind(group[i]);
      if (c < 0) ok = false;
      n += stmtCount(group[i]);
    }
    if (!ok || !pg_.run(n)) {
      // connection lost: the commit outcome is unknown, so nothing is retried
      fprintf(stderr, "[db] write group failed: %s", PQerrorMessage(pg_.c));
      for (Job *j : group) rep_.add(j, 500, std::string(E500));
      rep_.flush();
      pg_.clear();
      if (pg_.dead()) connect();
      return;
    }
    bool failed = false;
    for (int i = 0; i < n; i++) if (!pg_.res[i].ok()) { failed = true; break; }
    if (failed && group.size() > 1) {
      // the group rolled back: run each write on its own
      pg_.clear();
      for (Job *j : group) {
        std::vector<Job *> one{j};
        run(one);
      }
      return;
    }
    for (size_t i = 0; i < group.size(); i++) finish(group[i], spans[i]);
    rep_.flush();
    pg_.clear();
  }

  void finish(Job *j, int s) {
    for (int i = s; i < s + stmtCount(j); i++) {
      const Res &r = pg_.res[i];
      if (r.ok()) continue;
      if (r.sqlstate() == "23505") { rep_.add(j, 422, std::string(E422_TAKEN)); return; }
      fprintf(stderr, "[db] write failed: %s %s", r.sqlstate().c_str(), r.message().c_str());
      rep_.add(j, 500, std::string(E500));
      return;
    }
    const Res &r = pg_.res[s];
    bool has = r.n() > 0;
    int64_t v = j->v;
    std::string body;
    Out o(body);
    switch (j->k) {
      case W_REGISTER:
        if (!has) { rep_.add(j, 422, std::string(E422_TAKEN)); return; }
        userJsonPg(o, r, 0, 2, 1, 3, 4, issueToken(r.i64(0, 0)));
        rep_.add(j, 201, std::move(body));
        return;
      case W_UPDUSER:
        if (!has) { rep_.add(j, 401, std::string(E401)); return; }
        userJsonPg(o, r, 0, 2, 1, 3, 4, j->token);
        rep_.add(j, 200, std::move(body));
        return;
      case W_FOLLOW: case W_UNFOLLOW:
        if (!has) { rep_.add(j, 404, std::string(E404)); return; }
        o.lit("{\"profile\":"); profileObj(o, r, 0, 0, 1, 2, j->k == W_FOLLOW); o.ch('}');
        rep_.add(j, 200, std::move(body));
        return;
      case W_FAV: case W_UNFAV: case W_NEWART:
        if (!has) {
          if (j->k == W_NEWART) rep_.add(j, 500, std::string(E500));
          else rep_.add(j, 404, std::string(E404));
          return;
        }
        readBack(j, r.i64(0, 0), j->k == W_NEWART ? 201 : 200);
        return;
      case W_UPDART:
        if (!has) { rep_.add(j, 404, std::string(E404)); return; }
        if (r.i64(0, 1) != v) { rep_.add(j, 403, std::string(E403)); return; }
        readBack(j, r.i64(0, 0), 200);
        return;
      case W_DELART: case W_DELCMT:
        if (!has) { rep_.add(j, 404, std::string(E404)); return; }
        if (r.i64(0, 0) != v) { rep_.add(j, 403, std::string(E403)); return; }
        rep_.add(j, 204, std::string());
        return;
      case W_NEWCMT:
        if (!has) { rep_.add(j, 404, std::string(E404)); return; }
        o.lit("{\"comment\":{\"id\":"); o.num(r.i64(0, 0));
        o.lit(",\"createdAt\":"); o.ts(r.i64(0, 2));
        o.lit(",\"updatedAt\":"); o.ts(r.i64(0, 3));
        o.lit(",\"body\":"); col(o, r, 0, 1);
        o.lit(",\"author\":"); profileObj(o, r, 0, 4, 5, 6, false);
        o.lit("}}");
        rep_.add(j, 201, std::move(body));
        return;
    }
  }
  // the article is read back through the read lanes, after the commit, in a new snapshot
  void readBack(Job *j, int64_t id, int status) {
    j->k = K_ID;
    j->id = id;
    j->status = status;
    planner.push(j);
  }

  pq::Conn pg_;
  pq::Params P_;
  Replies rep_;
  std::mutex m_;
  std::condition_variable cv_;
  std::deque<Job *> q_;
};

WriteLane writer;
}  // namespace

void dbStart() {
  std::thread w([] { writer.start(); });
  planner.start(cfg.readLanes);
  w.join();
  if (cfg.stats) {
    std::thread([] {
      for (;;) {
        std::this_thread::sleep_for(std::chrono::seconds(5));
        uint64_t b = stBatches.exchange(0), jb = stJobs.exchange(0), mx = stMax.exchange(0), us = stPgUs.exchange(0), w = stWrites.exchange(0), g = stGroups.exchange(0);
        fprintf(stderr, "[db] batches=%lu avg=%.1f max=%lu ms/batch=%.2f writes=%lu/%lu q=%zu\n", (unsigned long)b, b ? (double)jb / b : 0.0,
                (unsigned long)mx, b ? us / 1000.0 / b : 0.0, (unsigned long)w, (unsigned long)g, planner.queued());
      }
    }).detach();
  }
}

void submitRead(Job *j) { planner.push(j); }

void submitWrite(Job *j) {
  if ((j->k == W_REGISTER || j->k == W_UPDUSER) && !j->password.empty()) {
    std::string pw = std::move(j->password);
    j->password.clear();
    bcryptHash(std::move(pw), [j](std::string h) {
      if (h.empty()) { reply(j, 500, std::string(E500)); return; }
      j->hash = std::move(h);
      writer.push(j);
    });
  } else writer.push(j);
}
