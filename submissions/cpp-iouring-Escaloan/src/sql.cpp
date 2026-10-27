// Batched statement forms, built mechanically from the single forms in sql.hpp:
//
//   SELECT r.ord::int4, q.* FROM unnest($1::int8[], $2::text[], ...) WITH ORDINALITY AS r(p1, p2, ..., ord)
//   CROSS JOIN LATERAL (<single form with $k replaced by r.pk>) q ORDER BY r.ord[, <list order>]
//
// Every request in the batch still runs its own lookups; what the batch saves is per-statement overhead
// (protocol round trip, executor start-up, snapshot, plan lookup). Rows carry the request ordinal in column 0.
#include <string>

#include "config.hpp"
#include "sql.hpp"

namespace sql {
namespace {

// Replaces whole parameter tokens: "$1" must not match inside "$10".
std::string replace_params(const char* text) {
  std::string out;
  for (const char* p = text; *p; ++p) {
    if (*p == '$' && p[1] >= '0' && p[1] <= '9') {
      out += "r.p";
      ++p;
      while (*p >= '0' && *p <= '9') out += *p++;
      --p;
    } else {
      out += *p;
    }
  }
  return out;
}

const char* array_cast(std::uint32_t oid) {
  switch (oid) {
    case kInt8: return "int8[]";
    case kInt4: return "int4[]";
    case kText: return "text[]";
    default: return nullptr;
  }
}

// Comments need explicit output names: the single form returns two columns called "id".
constexpr const char* kCommentsBatched =
    "SELECT r.ord::int4, q.aid, q.cid, q.body, q.created_at, q.updated_at, q.username, q.bio, q.image, q.following "
    "FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(p1, p2, ord) "
    "CROSS JOIN LATERAL (SELECT a.id AS aid, c.id AS cid, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
    "COALESCE(c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1), false) AS following "
    "FROM articles a "
    "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c "
    "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true "
    "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = r.p2) q "
    "ORDER BY r.ord, q.created_at DESC, q.cid DESC";

// Shared list execution: each request's page of article ids, then the viewer-independent columns once per distinct
// article, then the viewer's favorited/following per row. Nothing outlives the execution.
//   {COUNT}  per distinct filter value (or once, for the global list) when counts are shared, else per request
//   {PAGE}   the request's page ids (references r.p2 limit, r.p3 offset, r.p4 filter)
std::string shared_list(const char* params, const char* names, const std::string& counts_cte, const std::string& counts_join,
                        const char* page) {
  return std::string("WITH requests AS MATERIALIZED (SELECT * FROM unnest(") + params + ") WITH ORDINALITY AS r(" + names +
         ", ord)), " + counts_cte +
         ", pages AS MATERIALIZED (SELECT r.ord, p.id FROM requests r LEFT JOIN LATERAL (" + page + ") p ON true), "
         "ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), "
         "enriched AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, "
         CONDUIT_TAGS_COL " AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, "
         "u.username, u.bio, u.image FROM ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id) "
         "SELECT r.ord::int4, c.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, "
         "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = r.p1), e.username, e.bio, e.image, "
         "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = e.author_id) "
         "FROM pages p JOIN requests r ON r.ord = p.ord " + counts_join +
         " LEFT JOIN enriched e ON e.id = p.id ORDER BY r.ord, e.id DESC";
}

// Count CTE + join. With shared counts, one count per distinct filter value; otherwise one per request.
void count_parts(const char* count_expr_f, bool filtered, std::string& cte, std::string& join) {
  if (!cfg::kShareCountsInExecution) {
    // Per request: count_expr_f references f.p4; alias the request row as f.
    cte = std::string("counts AS MATERIALIZED (SELECT f.ord, (") + count_expr_f + ") AS n FROM requests f)";
    join = "JOIN counts c ON c.ord = r.ord";
  } else if (filtered) {
    cte = std::string("counts AS MATERIALIZED (SELECT f.p4, (") + count_expr_f + ") AS n FROM (SELECT DISTINCT p4 FROM requests) f)";
    join = "JOIN counts c ON c.p4 = r.p4";
  } else {
    cte = std::string("counts AS MATERIALIZED (SELECT (") + count_expr_f + ") AS n)";
    join = "CROSS JOIN counts c";
  }
}

}  // namespace

int shared_for(int list_kind) {
  switch (list_kind) {
    case kListAll: return kListAllShared;
    case kListTag: return kListTagShared;
    case kListAuthor: return kListAuthorShared;
    case kListFavorited: return kListFavoritedShared;
    default: return -1;
  }
}

std::string shared_text(int stmt) {
  std::string cte, join;
  const char* p3 = "$1::int8[], $2::int8[], $3::int8[]";
  const char* p4 = "$1::int8[], $2::int8[], $3::int8[], $4::text[]";
  switch (stmt) {
    case kListAllShared:
      count_parts("SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s", false, cte, join);
      return shared_list(p3, "p1, p2, p3", cte, join,
                         "SELECT b.id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) b "
                         "ORDER BY b.id DESC LIMIT r.p2");
    case kListTagShared:
      count_parts("SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = f.p4) "
                  "OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at "
                  "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = f.p4) LIMIT 1000) s) END",
                  true, cte, join);
      return shared_list(p4, "p1, p2, p3, p4", cte, join,
                         "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t "
                         "WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3");
    case kListAuthorShared:
      count_parts("SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au "
                  "WHERE au.username = f.p4) LIMIT 1000) s",
                  true, cte, join);
      return shared_list(p4, "p1, p2, p3, p4", cte, join,
                         "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) "
                         "ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3");
    case kListFavoritedShared:
      count_parts("SELECT count(*) FROM (SELECT 1 FROM favorites fa WHERE fa.user_id = (SELECT fu.id FROM users fu "
                  "WHERE fu.username = f.p4) LIMIT 1000) s",
                  true, cte, join);
      return shared_list(p4, "p1, p2, p3, p4", cte, join,
                         "SELECT fa.article_id AS id FROM favorites fa WHERE fa.user_id = (SELECT fu.id FROM users fu "
                         "WHERE fu.username = r.p4) ORDER BY fa.article_id DESC LIMIT r.p2 OFFSET r.p3");
    case kFeedShared:
      // Feed pages differ per viewer, but popular authors appear in many viewers' pages: enrich each distinct article
      // once per execution. Counts stay per request (they depend on the viewer); `following` is the constant true.
      return "WITH requests AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::int8[]) "
             "WITH ORDINALITY AS r(p1, p2, p3, p4, ord)), "
             "counts AS MATERIALIZED (SELECT r.ord, (SELECT count(*) FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = "
             "ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)) LIMIT 1000) s) AS n FROM requests r), "
             "pages AS MATERIALIZED (SELECT r.ord, p.id FROM requests r LEFT JOIN LATERAL (SELECT x.id FROM follows fo "
             "CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC "
             "LIMIT r.p4) x WHERE fo.follower_id = r.p1 ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3) p ON true), "
             "ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL), "
             "enriched AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
             CONDUIT_TAGS_COL " AS tags, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, "
             "u.username, u.bio, u.image FROM ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id) "
             "SELECT r.ord::int4, c.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc, "
             "EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.p1 AND f.article_id = e.id), e.username, e.bio, e.image, "
             "true FROM pages p JOIN requests r ON r.ord = p.ord JOIN counts c ON c.ord = r.ord "
             "LEFT JOIN enriched e ON e.id = p.id ORDER BY r.ord, e.id DESC";
    default:
      return {};
  }
}

bool batchable(int stmt) {
  switch (stmt) {
    case kUserById:
    case kUserByEmail:
    case kProfile:
    case kArticleBySlug:
    case kArticleById:
    case kComments:
    case kListAll:
    case kListTag:
    case kListAuthor:
    case kListFavorited:
    case kFeed:
    case kListAllDeep:
      return true;
    default:
      return false;
  }
}

std::uint32_t array_oid(std::uint32_t elem) {
  switch (elem) {
    case kInt8: return kInt8Array;
    case kInt4: return kInt4Array;
    case kText: return kTextArray;
    default: return 0;
  }
}

std::string batched_text(int stmt) {
  if (stmt == kComments) return kCommentsBatched;
  const StmtDef& d = kStmts[stmt];
  std::string args, names;
  for (int k = 0; k < d.nparams; ++k) {
    if (k) {
      args += ", ";
      names += ", ";
    }
    args += "$" + std::to_string(k + 1) + "::" + array_cast(d.types[k]);
    names += "p" + std::to_string(k + 1);
  }
  bool list = stmt == kListAll || stmt == kListTag || stmt == kListAuthor || stmt == kListFavorited ||
              stmt == kFeed || stmt == kListAllDeep;
  return "SELECT r.ord::int4, q.* FROM unnest(" + args + ") WITH ORDINALITY AS r(" + names +
         ", ord) CROSS JOIN LATERAL (" + replace_params(d.text) + ") q ORDER BY r.ord" + (list ? ", q.id DESC" : "");
}

}  // namespace sql
