#include "handlers.hpp"

#include <vector>

#include <userver/storages/postgres/io/array_types.hpp>
#include <userver/storages/postgres/io/optional.hpp>
#include <userver/storages/postgres/io/string_types.hpp>
#include <userver/storages/postgres/transaction.hpp>

namespace conduit {

namespace {

// $1 = viewer. ARTICLE_LIST_SELECT and ARTICLE_FULL_SELECT from SPEC.md.
#define ARTICLE_SELECT(BODY)                                                                              \
    "SELECT a.id, a.slug, a.title, a.description, " BODY "a.created_at, a.updated_at, "                    \
    "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "                            \
    "WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "                                            \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "                    \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "       \
    "u.username, u.bio, u.image, "                                                                         \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following " \
    "FROM articles a JOIN users u ON u.id = a.author_id "

#define LIST_SELECT ARTICLE_SELECT("")
#define FULL_SELECT ARTICLE_SELECT("a.body, ")

// A list page and its capped count in one statement (one round trip). $1 viewer, $2 limit, $3 offset, $4 filter.
// The LEFT JOIN keeps the count row when the page is empty.
#define LIST_WITH_COUNT(PAGE, COUNT)                                         \
    "WITH p AS (" PAGE "), c AS (SELECT count(*) AS n FROM (" COUNT ") s) " \
    "SELECT c.n, p.* FROM c LEFT JOIN p ON true ORDER BY p.id DESC"

// Every list pages its article ids first (an index-only walk that can skip OFFSET rows cheaply) and only then
// builds the full rows, with their tag/favorite/follow subselects, for at most `limit` ids. Paging the full
// select instead makes Postgres build every skipped row: ?offset=100000000 took 12.8 s on the full seed.
//
// The global, author and tag lists get LIMIT/OFFSET as literals (validated integers), one prepared statement per
// page shape. With them as parameters Postgres can't reuse a generic plan for these (it guesses LIMIT $n means 10%
// of the rows) and replans on every call, which costs as much as running the query (measured on the full seed:
// planning 0.26-0.36 ms vs execution ~0.29 ms; with literals planning drops to ~0.005 ms). The favorited list and
// the feed already reuse their generic plans with parameters. Here $1 = viewer, $2 = tag or author.
constexpr std::string_view kPageMark = "/*PAGE*/";

const std::string kListAllTpl = LIST_WITH_COUNT(
    LIST_SELECT "WHERE a.id IN (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC /*PAGE*/) ORDER BY a.id DESC",
    "SELECT 1 FROM articles a LIMIT 1000");

const std::string kListByAuthorTpl = LIST_WITH_COUNT(
    LIST_SELECT
    "WHERE a.id IN (SELECT a2.id FROM articles a2 "
    "WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $2) "
    "ORDER BY a2.id DESC /*PAGE*/) ORDER BY a.id DESC",
    "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $2) LIMIT 1000");

const std::string kListByTagTpl = LIST_WITH_COUNT(
    LIST_SELECT
    "WHERE a.id IN (SELECT at.article_id FROM article_tags at "
    "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2) "
    "ORDER BY at.article_id DESC /*PAGE*/) ORDER BY a.id DESC",
    "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2) LIMIT 1000");

pg::Query WithPage(const std::string& tpl, const Page& page, const char* name) {
    std::string sql = tpl;
    const auto pos = sql.find(kPageMark);
    sql.replace(pos, kPageMark.size(),
                "LIMIT " + std::to_string(page.limit) + " OFFSET " + std::to_string(page.offset));
    return pg::Query{std::move(sql), pg::Query::Name{name}};
}

const pg::Query kListByFavorited{
    LIST_WITH_COUNT(LIST_SELECT
                    "WHERE a.id IN (SELECT f.article_id FROM favorites f "
                    "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) "
                    "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                    "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) "
                    "LIMIT 1000"),
    pg::Query::Name{"list_by_favorited"}};

const pg::Query kFeed{
    LIST_WITH_COUNT(LIST_SELECT
                    "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
                    "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id "
                    "ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x "
                    "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
                    "SELECT 1 FROM articles a WHERE a.author_id IN "
                    "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000"),
    pg::Query::Name{"feed"}};

const pg::Query kArticleBySlug{FULL_SELECT "WHERE a.slug = $2", pg::Query::Name{"article_by_slug"}};
const pg::Query kArticleById{FULL_SELECT "WHERE a.id = $2", pg::Query::Name{"article_by_id"}};

#define SLUGIFY(X) "trim(both '-' from lower(regexp_replace(" X ", '[^A-Za-z0-9]+', '-', 'g')))"

const pg::Query kInsertArticle{
    "INSERT INTO articles (id, slug, author_id, title, description, body) "
    "SELECT n.id, " SLUGIFY("$2") " || '-' || n.id, $1, $2, $3, $4 "
    "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
    pg::Query::Name{"insert_article"}};

const pg::Query kInsertTags{
    "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
    pg::Query::Name{"insert_tags"}};

const pg::Query kInsertArticleTags{
    "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])",
    pg::Query::Name{"insert_article_tags"}};

const pg::Query kArticleOwner{
    "SELECT id, author_id FROM articles WHERE slug = $1", pg::Query::Name{"article_owner"}};

const pg::Query kUpdateArticle{
    "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
    "body = COALESCE($4, body), "
    "slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2") " || '-' || id END, "
    "updated_at = now() WHERE id = $1",
    pg::Query::Name{"update_article"}};

const pg::Query kDeleteArticle{"DELETE FROM articles WHERE id = $1", pg::Query::Name{"delete_article"}};

// The slug lookup and the write in one round trip; the full select after it must be a separate statement
// so it sees the write.
const pg::Query kFavorite{
    "WITH a AS (SELECT id FROM articles WHERE slug = $2), "
    "ins AS (INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM a ON CONFLICT DO NOTHING) "
    "SELECT id FROM a",
    pg::Query::Name{"favorite"}};

const pg::Query kUnfavorite{
    "WITH a AS (SELECT id FROM articles WHERE slug = $2), "
    "del AS (DELETE FROM favorites f USING a WHERE f.user_id = $1 AND f.article_id = a.id) "
    "SELECT id FROM a",
    pg::Query::Name{"unfavorite"}};

const pg::Query kTags{"SELECT name FROM tags ORDER BY name", pg::Query::Name{"tags"}};

std::string ListBody(const pg::ResultSet& res) {
    JsonOut j;
    j.Raw("{\"articles\":[");
    bool first = true;
    for (const auto& row : res) {
        if (row[1].IsNull()) continue;  // empty page: only the count row
        if (!first) j.Raw(",");
        first = false;
        WriteArticle(j, row, 1, false);
    }
    j.Raw("],\"articlesCount\":");
    j.Int(res.IsEmpty() ? 0 : res[0][0].As<std::int64_t>());
    j.Raw("}");
    return std::move(j.Get());
}

std::string ArticleBody(const pg::ResultSet& res) {
    JsonOut j;
    j.Raw("{\"article\":");
    WriteArticle(j, res[0], 0, true);
    j.Raw("}");
    return std::move(j.Get());
}

// Returns the filter value if the query parameter is present and non-empty.
const std::string* Filter(const HttpRequest& request, std::string_view name) {
    if (!request.HasArg(name)) return nullptr;
    const auto& v = request.GetArg(name);
    return v.empty() ? nullptr : &v;
}

std::vector<std::string> ParseTagList(const json::Value& a) {
    std::vector<std::string> tags;
    const auto tl = a["tagList"];
    if (tl.IsMissing() || tl.IsNull()) return tags;
    if (!tl.IsArray()) Unprocessable("tagList must be an array of non-empty strings");
    tags.reserve(tl.GetSize());
    for (const auto& item : tl) {
        if (!item.IsString()) Unprocessable("tagList must be an array of non-empty strings");
        auto s = item.As<std::string>();
        if (s.empty()) Unprocessable("tagList must be an array of non-empty strings");
        tags.push_back(std::move(s));
    }
    return tags;
}

}  // namespace

std::string Articles::Handle(const HttpRequest& request) const {
    if (request.GetMethod() == HttpMethod::kGet) {
        const auto viewer = OptionalAuth(request);
        const auto page = ParsePage(request);
        // Only the first filter given applies, in this order.
        if (const auto* tag = Filter(request, "tag")) {
            return ListBody(Db().Execute(kMaster, WithPage(kListByTagTpl, page, "list_by_tag"), viewer, *tag));
        }
        if (const auto* author = Filter(request, "author")) {
            return ListBody(Db().Execute(kMaster, WithPage(kListByAuthorTpl, page, "list_by_author"), viewer, *author));
        }
        if (const auto* fav = Filter(request, "favorited")) {
            return ListBody(Db().Execute(kMaster, kListByFavorited, viewer, page.limit, page.offset, *fav));
        }
        return ListBody(Db().Execute(kMaster, WithPage(kListAllTpl, page, "list_all"), viewer));
    }

    // POST
    const auto viewer = RequireAuth(request);
    const auto a = ReadWrapper(request, "article");
    const auto title = ReqString(a, "title");
    const auto description = ReqString(a, "description");
    const auto body = ReqString(a, "body");
    const auto tags = ParseTagList(a);

    auto trx = Db().Begin(kMaster, pg::TransactionOptions{});
    const auto inserted = trx.Execute(kInsertArticle, viewer.id, title, description, body);
    const auto id = inserted[0][0].As<std::int64_t>();
    if (!tags.empty()) {
        trx.Execute(kInsertTags, tags);
        trx.Execute(kInsertArticleTags, id, tags);
    }
    trx.Commit();

    const auto res = Db().Execute(kMaster, kArticleById, viewer.id, id);
    if (res.IsEmpty()) NotFound();  // deleted concurrently
    request.SetResponseStatus(Status::kCreated);
    return ArticleBody(res);
}

std::string Feed::Handle(const HttpRequest& request) const {
    const auto viewer = RequireAuth(request);
    const auto page = ParsePage(request);
    return ListBody(Db().Execute(kMaster, kFeed, viewer.id, page.limit, page.offset));
}

std::string Article::Handle(const HttpRequest& request) const {
    const auto& slug = request.GetPathArg("slug");
    const auto method = request.GetMethod();

    if (method == HttpMethod::kGet) {
        const auto viewer = OptionalAuth(request);
        const auto res = Db().Execute(kMaster, kArticleBySlug, viewer, slug);
        if (res.IsEmpty()) NotFound();
        return ArticleBody(res);
    }

    const auto viewer = RequireAuth(request);
    std::optional<std::string> title, description, body;
    if (method == HttpMethod::kPut) {
        const auto a = ReadWrapper(request, "article");
        title = OptString(a, "title", true);
        description = OptString(a, "description", true);
        body = OptString(a, "body", true);
    }

    const auto owner = Db().Execute(kMaster, kArticleOwner, slug);
    if (owner.IsEmpty()) NotFound();
    const auto id = owner[0][0].As<std::int64_t>();
    if (owner[0][1].As<std::int64_t>() != viewer.id) Forbidden();

    if (method == HttpMethod::kDelete) {
        Db().Execute(kMaster, kDeleteArticle, id);
        request.SetResponseStatus(Status::kNoContent);
        return {};
    }

    Db().Execute(kMaster, kUpdateArticle, id, title, description, body);
    const auto res = Db().Execute(kMaster, kArticleById, viewer.id, id);
    if (res.IsEmpty()) NotFound();
    return ArticleBody(res);
}

std::string Favorite::Handle(const HttpRequest& request) const {
    const auto viewer = RequireAuth(request);
    const bool add = request.GetMethod() == HttpMethod::kPost;
    const auto found = Db().Execute(kMaster, add ? kFavorite : kUnfavorite, viewer.id, request.GetPathArg("slug"));
    if (found.IsEmpty()) NotFound();
    const auto res = Db().Execute(kMaster, kArticleById, viewer.id, found[0][0].As<std::int64_t>());
    if (res.IsEmpty()) NotFound();
    return ArticleBody(res);
}

std::string Tags::Handle(const HttpRequest&) const {
    const auto res = Db().Execute(kMaster, kTags);
    JsonOut j;
    j.Raw("{\"tags\":[");
    bool first = true;
    for (const auto& row : res) {
        if (!first) j.Raw(",");
        first = false;
        j.Str(row[0].As<std::string_view>());
    }
    j.Raw("]}");
    return std::move(j.Get());
}

}  // namespace conduit
