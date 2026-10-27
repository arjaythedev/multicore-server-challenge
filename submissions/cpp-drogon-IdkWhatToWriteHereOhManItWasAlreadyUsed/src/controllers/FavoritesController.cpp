#include "FavoritesController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"

using namespace multicore;
using namespace multicore::common;

namespace {

    Task<HttpResponsePtr> ReloadArticle(DbClientPtr db, int64_t viewer, int64_t id)
    {
        auto r = co_await db->execSqlCoro(
            std::string(sql::kArticleFullSelect) + "WHERE a.id = $2", viewer, id);
        if (r.empty())
            co_return common::NotFound();
        Json::Value root;
        root["article"] = ArticleJson(r[0], true);
        co_return MakeJson(k200OK, root);
    }

}

Task<HttpResponsePtr> FavoritesController::FavoriteArticle(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto a = co_await db->execSqlCoro(sql::kInsertFavoriteBySlug, viewer, slug);
        if (a.empty() || a[0]["article_id"].isNull()) co_return common::NotFound();
        const int64_t id = a[0]["article_id"].as<int64_t>();
        co_return co_await ReloadArticle(db, viewer, id);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> FavoritesController::UnfavoriteArticle(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto a = co_await db->execSqlCoro(sql::kDeleteFavoriteBySlug, viewer, slug);
        if (a.empty() || a[0]["article_id"].isNull()) co_return common::NotFound();
        const int64_t id = a[0]["article_id"].as<int64_t>();
        co_return co_await ReloadArticle(db, viewer, id);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}