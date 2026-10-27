#pragma once

#include <drogon/HttpController.h>

namespace multicore
{
    using namespace drogon;

    class ArticlesController : public drogon::HttpController<ArticlesController, false>
    {
    public:
        METHOD_LIST_BEGIN
        ADD_METHOD_TO(ArticlesController::ListArticles,  "api/articles",        Get,    "multicore::AuthOptionalMiddleware");
        ADD_METHOD_TO(ArticlesController::CreateArticle, "api/articles",        Post,   "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(ArticlesController::GetFeed,       "api/articles/feed",   Get,    "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(ArticlesController::GetArticle,    "api/articles/{slug}", Get,    "multicore::AuthOptionalMiddleware");
        ADD_METHOD_TO(ArticlesController::UpdateArticle, "api/articles/{slug}", Put,    "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(ArticlesController::DeleteArticle, "api/articles/{slug}", Delete, "multicore::AuthRequiredMiddleware");
        METHOD_LIST_END

        static Task<HttpResponsePtr> ListArticles(HttpRequestPtr req);
        static Task<HttpResponsePtr> CreateArticle(HttpRequestPtr req);
        static Task<HttpResponsePtr> GetFeed(HttpRequestPtr req);
        static Task<HttpResponsePtr> GetArticle(HttpRequestPtr req, std::string slug);
        static Task<HttpResponsePtr> UpdateArticle(HttpRequestPtr req, std::string slug);
        static Task<HttpResponsePtr> DeleteArticle(HttpRequestPtr req, std::string slug);
    };
}