#pragma once

#include <drogon/HttpController.h>

namespace multicore
{
    using namespace drogon;

    class TagsController : public drogon::HttpController<TagsController, false>
    {
    public:
        METHOD_LIST_BEGIN
        ADD_METHOD_TO(TagsController::ListTags, "api/tags", Get);
        METHOD_LIST_END

        static Task<HttpResponsePtr> ListTags(HttpRequestPtr req);
    };
}