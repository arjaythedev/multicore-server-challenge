#include "ProfilesController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"

using namespace multicore;
using namespace multicore::common;

namespace {

HttpResponsePtr ProfileResponse(const Row& r)
{
    Json::Value profile;
    ProfileJson(profile, r, "username", "bio", "image", "following");
    Json::Value root;
    root["profile"] = profile;
    return MakeJson(k200OK, root);
}

Task<HttpResponsePtr> ReloadProfile(DbClientPtr db, int64_t viewer, const std::string& username)
{
    auto r = co_await db->execSqlCoro(sql::kSelectProfile, viewer, username);
    if (r.empty()) co_return common::NotFound();
    co_return ProfileResponse(r[0]);
}

}

Task<HttpResponsePtr> ProfilesController::GetProfile(HttpRequestPtr req, std::string username)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(sql::kSelectProfile, viewer, username);
        if (r.empty()) co_return common::NotFound();
        co_return ProfileResponse(r[0]);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ProfilesController::FollowUser(HttpRequestPtr req, std::string username)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto t = co_await db->execSqlCoro(sql::kInsertFollowByUsername, viewer, username);
        if (t.empty() || t[0]["followee_id"].isNull()) co_return common::NotFound();
        co_return co_await ReloadProfile(db, viewer, username);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> ProfilesController::UnfollowUser(HttpRequestPtr req, std::string username)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto t = co_await db->execSqlCoro(sql::kDeleteFollowByUsername, viewer, username);
        if (t.empty() || t[0]["followee_id"].isNull()) co_return common::NotFound();
        co_return co_await ReloadProfile(db, viewer, username);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}