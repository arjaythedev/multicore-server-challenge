#pragma once

#include <drogon/HttpController.h>

namespace multicore
{
    using namespace drogon;

    class FavoritesController : public drogon::HttpController<FavoritesController, false>
    {
    public:
        METHOD_LIST_BEGIN
        ADD_METHOD_TO(FavoritesController::FavoriteArticle,   "api/articles/{slug}/favorite", Post,   "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(FavoritesController::UnfavoriteArticle, "api/articles/{slug}/favorite", Delete, "multicore::AuthRequiredMiddleware");
        METHOD_LIST_END

        static Task<HttpResponsePtr> FavoriteArticle(HttpRequestPtr req, std::string slug);
        static Task<HttpResponsePtr> UnfavoriteArticle(HttpRequestPtr req, std::string slug);
    };
}