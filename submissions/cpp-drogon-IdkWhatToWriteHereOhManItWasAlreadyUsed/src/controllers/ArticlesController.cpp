#include "ArticlesController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"

#include "robin_hood.h"

using namespace multicore;
using namespace multicore::common;

namespace {

HttpResponsePtr ArticlesPageResponse(const Result& r,
                                     int64_t count,
                                     const ArticleExtras& ex)
{
    Json::Value arr(Json::arrayValue);
    for (const auto& row : r)
        arr.append(ArticleJsonWithExtras(row, false, ex));
    Json::Value root;
    root["articles"] = arr;
    root["articlesCount"] = static_cast<Json::Int64>(count);
    return MakeJson(k200OK, root);
}

std::string ToPgTextArray(const std::vector<std::string>& v)
{
    std::string out = "{";
    for (size_t i = 0; i < v.size(); ++i)
    {
        if (i) out += ',';
        out += '"';
        for (const char c : v[i])
        {
            if (c == '"' || c == '\\') out += '\\';
            out += c;
        }
        out += '"';
    }
    out += '}';
    return out;
}

Task<HttpResponsePtr> LoadAndBuildPage(DbClientPtr db,
                                       int64_t viewer,
                                       const Result& r,
                                       int64_t count)
{
    std::vector<int64_t> articleIds;
    std::vector<int64_t> authorIds;
    articleIds.reserve(r.size());
    authorIds.reserve(r.size());
    for (const auto& row : r)
    {
        articleIds.push_back(row["id"].as<int64_t>());
        authorIds.push_back(row["author_id"].as<int64_t>());
    }

    ArticleExtras ex;
    if (!co_await LoadArticleExtras(db, viewer, articleIds, authorIds, ex))
        co_return ServerError();

    co_return ArticlesPageResponse(r, count, ex);
}

}

Task<HttpResponsePtr> ArticlesController::ListArticles(HttpRequestPtr req)
{
    const int64_t viewer = Viewer(req);
    auto page = ParsePage(req);
    if (!page.ok) co_return Unprocessable();

    const auto& ps = req->getParameters();
    auto it = ps.find("tag");
    if (it != ps.end() && !it->second.empty())
    {
        const auto tag = it->second;
        auto db = drogon::app().getDbClient();
        try
        {
            auto r = co_await db->execSqlCoro(
                std::string(sql::kArticleBaseListSelect) +
                "WHERE a.id IN ("
                "  SELECT at.article_id FROM article_tags at "
                "   WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) "
                "   ORDER BY at.article_id DESC LIMIT $2::bigint OFFSET $3::bigint"
                ") ORDER BY a.id DESC",
                tag, static_cast<int64_t>(page.limit), static_cast<int64_t>(page.offset));
            auto c = co_await db->execSqlCoro(
                "SELECT count(*) FROM (SELECT 1 FROM article_tags at "
                " WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
                tag);
            co_return co_await LoadAndBuildPage(db, viewer, r, c[0][0].as<int64_t>());
        }
        catch (const DrogonDbException&) { co_return ServerError(); }
    }

    it = ps.find("author");
    if (it != ps.end() && !it->second.empty())
    {
        const auto author = it->second;
        auto db = drogon::app().getDbClient();
        try
        {
            auto r = co_await db->execSqlCoro(
                std::string(sql::kArticleBaseListSelect) +
                "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $1) "
                "ORDER BY a.id DESC LIMIT $2::bigint OFFSET $3::bigint",
                author, static_cast<int64_t>(page.limit), static_cast<int64_t>(page.offset));
            auto c = co_await db->execSqlCoro(
                "SELECT count(*) FROM (SELECT 1 FROM articles a "
                " WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
                author);
            co_return co_await LoadAndBuildPage(db, viewer, r, c[0][0].as<int64_t>());
        }
        catch (const DrogonDbException&) { co_return ServerError(); }
    }

    it = ps.find("favorited");
    if (it != ps.end() && !it->second.empty())
    {
        const auto fav = it->second;
        auto db = drogon::app().getDbClient();
        try
        {
            auto r = co_await db->execSqlCoro(
                std::string(sql::kArticleBaseListSelect) +
                "WHERE a.id IN ("
                "  SELECT f.article_id FROM favorites f "
                "   WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) "
                "   ORDER BY f.article_id DESC LIMIT $2::bigint OFFSET $3::bigint"
                ") ORDER BY a.id DESC",
                fav, static_cast<int64_t>(page.limit), static_cast<int64_t>(page.offset));
            auto c = co_await db->execSqlCoro(
                "SELECT count(*) FROM (SELECT 1 FROM favorites f "
                " WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
                fav);
            co_return co_await LoadAndBuildPage(db, viewer, r, c[0][0].as<int64_t>());
        }
        catch (const DrogonDbException&) { co_return ServerError(); }
    }

    auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(
            std::string(sql::kArticleBaseListSelect) +
            "ORDER BY a.id DESC LIMIT $1::bigint OFFSET $2::bigint",
            static_cast<int64_t>(page.limit), static_cast<int64_t>(page.offset));
        auto c = co_await db->execSqlCoro(
            "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s");
        co_return co_await LoadAndBuildPage(db, viewer, r, c[0][0].as<int64_t>());
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ArticlesController::CreateArticle(HttpRequestPtr req)
{
    const int64_t viewer = Viewer(req);
    auto body = req->getJsonObject();
    if (!body) co_return Unprocessable();
    if (!body->isMember("article") || !(*body)["article"].isObject()) co_return Unprocessable();
    const auto& art = (*body)["article"];

    if (!art.isMember("title") || !art["title"].isString() || art["title"].asString().empty())
        co_return Unprocessable();
    if (!art.isMember("description") || !art["description"].isString() || art["description"].asString().empty())
        co_return Unprocessable();
    if (!art.isMember("body") || !art["body"].isString() || art["body"].asString().empty())
        co_return Unprocessable();

    const auto title = art["title"].asString();
    const auto desc  = art["description"].asString();
    const auto text  = art["body"].asString();

    if (art.isMember("tagList") && !art["tagList"].isNull() && !art["tagList"].isArray())
        co_return Unprocessable();

    std::vector<std::string> tags;
    if (art.isMember("tagList") && art["tagList"].isArray())
    {
        for (const auto& t : art["tagList"])
        {
            if (!t.isString() || t.asString().empty()) co_return Unprocessable();
            tags.push_back(t.asString());
        }
    }

    const auto slug = Slugify(title);

    auto db = drogon::app().getDbClient();
    try
    {
        const auto tagsLiteral = tags.empty() ? std::string("{}") : ToPgTextArray(tags);

        auto ins = co_await db->execSqlCoro(
            sql::kCreateArticleWithTags,
            viewer, slug, title, desc, text, tagsLiteral);
        if (ins.empty()) co_return ServerError();
        const int64_t id = ins[0]["id"].as<int64_t>();

        auto r = co_await db->execSqlCoro(
            std::string(sql::kArticleFullSelect) + "WHERE a.id = $2", viewer, id);
        if (r.empty()) co_return ServerError();
        Json::Value root;
        root["article"] = ArticleJson(r[0], true);
        co_return MakeJson(k201Created, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ArticlesController::GetFeed(HttpRequestPtr req)
{
    const int64_t viewer = Viewer(req);
    auto page = ParsePage(req);
    if (!page.ok) co_return Unprocessable();

    auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(
             std::string(sql::kArticleBaseListSelect) + sql::kArticlePageFeed,
             viewer, page.limit, page.offset);
        auto c = co_await db->execSqlCoro(
            "SELECT count(*) FROM (SELECT 1 FROM articles a "
            " WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) "
            " LIMIT 1000) s",
            viewer);
        co_return co_await LoadAndBuildPage(db, viewer, r, c[0][0].as<int64_t>());
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ArticlesController::GetArticle(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(
            std::string(sql::kArticleFullSelect) + "WHERE a.slug = $2", viewer, slug);
        if (r.empty()) co_return common::NotFound();
        Json::Value root;
        root["article"] = ArticleJson(r[0], true);
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ArticlesController::UpdateArticle(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto body = req->getJsonObject();
    if (!body) co_return Unprocessable();
    if (!body->isMember("article") || !(*body)["article"].isObject()) co_return Unprocessable();
    const auto& art = (*body)["article"];

    if (art.isMember("title") && !art["title"].isNull() &&
        (!art["title"].isString() || art["title"].asString().empty()))
        co_return Unprocessable();
    if (art.isMember("description") && !art["description"].isNull() &&
        (!art["description"].isString() || art["description"].asString().empty()))
        co_return Unprocessable();
    if (art.isMember("body") && !art["body"].isNull() &&
        (!art["body"].isString() || art["body"].asString().empty()))
        co_return Unprocessable();

    auto optStr = [&](const char* key) -> std::optional<std::string> {
        if (!art.isMember(key) || art[key].isNull()) return std::nullopt;
        return art[key].asString();
    };
    auto title = optStr("title");
    auto desc  = optStr("description");
    auto text  = optStr("body");

    auto db = drogon::app().getDbClient();
    try
    {
        auto a = co_await db->execSqlCoro(
            "SELECT id, author_id FROM articles WHERE slug = $1", slug);
        if (a.empty()) co_return common::NotFound();
        const int64_t id = a[0]["id"].as<int64_t>();
        if (a[0]["author_id"].as<int64_t>() != viewer) co_return Forbidden();

        const std::optional<std::string> newSlug =
            title ? std::optional<std::string>(Slugify(*title)) : std::nullopt;

        co_await db->execSqlCoro(
            "UPDATE articles SET title = COALESCE($2, title), "
            "description = COALESCE($3, description), body = COALESCE($4, body), "
            "slug = CASE WHEN $5::text IS NULL THEN slug ELSE $5::text || '-' || id END, "
            "updated_at = now() WHERE id = $1",
            id, title, desc, text, newSlug);

        auto r = co_await db->execSqlCoro(
            std::string(sql::kArticleFullSelect) + "WHERE a.id = $2", viewer, id);
        if (r.empty()) co_return ServerError();
        Json::Value root;
        root["article"] = ArticleJson(r[0], true);
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ArticlesController::DeleteArticle(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto a = co_await db->execSqlCoro(
            "SELECT id, author_id FROM articles WHERE slug = $1", slug);
        if (a.empty()) co_return common::NotFound();
        const int64_t id = a[0]["id"].as<int64_t>();
        if (a[0]["author_id"].as<int64_t>() != viewer) co_return Forbidden();

        co_await db->execSqlCoro("DELETE FROM articles WHERE id = $1", id);
        co_return NoContent();
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}