#pragma once

#include <drogon/HttpController.h>

namespace multicore
{
    using namespace drogon;

    class ProfilesController : public drogon::HttpController<ProfilesController, false>
    {
    public:
        METHOD_LIST_BEGIN
        ADD_METHOD_TO(ProfilesController::GetProfile,   "api/profiles/{username}",        Get,    "multicore::AuthOptionalMiddleware");
        ADD_METHOD_TO(ProfilesController::FollowUser,   "api/profiles/{username}/follow", Post,   "multicore::AuthRequiredMiddleware");
        ADD_METHOD_TO(ProfilesController::UnfollowUser, "api/profiles/{username}/follow", Delete, "multicore::AuthRequiredMiddleware");
        METHOD_LIST_END

        static Task<HttpResponsePtr> GetProfile(HttpRequestPtr req, std::string username);
        static Task<HttpResponsePtr> FollowUser(HttpRequestPtr req, std::string username);
        static Task<HttpResponsePtr> UnfollowUser(HttpRequestPtr req, std::string username);
    };
}