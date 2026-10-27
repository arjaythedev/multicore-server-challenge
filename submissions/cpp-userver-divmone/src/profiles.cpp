#include "handlers.hpp"

#include <userver/storages/postgres/io/optional.hpp>
#include <userver/storages/postgres/io/string_types.hpp>

namespace conduit {

namespace {

const pg::Query kProfile{
    "SELECT u.username, u.bio, u.image, "
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following "
    "FROM users u WHERE u.username = $2",
    pg::Query::Name{"profile"}};

// The user lookup and the write in one round trip; the follow row is only touched when the user exists.
const pg::Query kFollow{
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
    "ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING) "
    "SELECT username, bio, image FROM u",
    pg::Query::Name{"follow"}};

const pg::Query kUnfollow{
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), "
    "del AS (DELETE FROM follows f USING u WHERE f.follower_id = $1 AND f.followee_id = u.id) "
    "SELECT username, bio, image FROM u",
    pg::Query::Name{"unfollow"}};

std::string ProfileBody(const pg::Row& row, bool following) {
    JsonOut j;
    j.Raw("{\"profile\":");
    WriteProfile(j, row[0].As<std::string_view>(), row[1].As<std::optional<std::string_view>>(),
                 row[2].As<std::optional<std::string_view>>(), following);
    j.Raw("}");
    return std::move(j.Get());
}

}  // namespace

std::string Profile::Handle(const HttpRequest& request) const {
    const auto viewer = OptionalAuth(request);
    const auto res = Db().Execute(kMaster, kProfile, viewer, request.GetPathArg("username"));
    if (res.IsEmpty()) NotFound();
    return ProfileBody(res[0], res[0][3].As<bool>());
}

std::string Follow::Handle(const HttpRequest& request) const {
    const auto viewer = RequireAuth(request);
    const bool follow = request.GetMethod() == HttpMethod::kPost;
    const auto res = Db().Execute(kMaster, follow ? kFollow : kUnfollow, viewer.id, request.GetPathArg("username"));
    if (res.IsEmpty()) NotFound();
    return ProfileBody(res[0], follow);
}

}  // namespace conduit
