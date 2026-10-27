#pragma once

#include <drogon/HttpController.h>

namespace multicore
{
    using namespace drogon;

    class CommentsController : public drogon::HttpController<CommentsController, false>
    {
    public:
        METHOD_LIST_BEGIN
        ADD_METHOD_TO(CommentsController::ListComments,  "api/articles/{slug}/comments",      Get,    "multicore::AuthOptionalMiddleware");
        ADD_METHOD_TO(CommentsController::CreateComment, "api/articles/{slug}/comments",      Post,   "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(CommentsController::DeleteComment, "api/articles/{slug}/comments/{id}", Delete, "multicore::AuthRequiredMiddleware");
        METHOD_LIST_END

        static Task<HttpResponsePtr> ListComments(HttpRequestPtr req, std::string slug);
        static Task<HttpResponsePtr> CreateComment(HttpRequestPtr req, std::string slug);
        static Task<HttpResponsePtr> DeleteComment(HttpRequestPtr req, std::string slug, std::string id);
    };
}