#pragma once

#include <drogon/HttpController.h>

namespace multicore
{
    using namespace drogon;

    class UsersController : public drogon::HttpController<UsersController, false>
    {
    public:
        METHOD_LIST_BEGIN
        ADD_METHOD_TO(UsersController::Register,          "api/users",       Post);
        ADD_METHOD_TO(UsersController::Login,             "api/users/login", Post);
        ADD_METHOD_TO(UsersController::GetCurrentUser,    "api/user",        Get, "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(UsersController::UpdateCurrentUser, "api/user",        Put, "multicore::AuthRequiredMiddleware");
        METHOD_LIST_END

        static Task<HttpResponsePtr> Register(HttpRequestPtr req);
        static Task<HttpResponsePtr> Login(HttpRequestPtr req);
        static Task<HttpResponsePtr> GetCurrentUser(HttpRequestPtr req);
        static Task<HttpResponsePtr> UpdateCurrentUser(HttpRequestPtr req);
    };
}