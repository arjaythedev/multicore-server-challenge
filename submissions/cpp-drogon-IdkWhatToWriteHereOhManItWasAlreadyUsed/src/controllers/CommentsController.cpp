#include "CommentsController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"

using namespace multicore;
using namespace multicore::common;

namespace {

Json::Value CommentJson(const Row& r)
{
    Json::Value c;
    c["id"]        = r["id"].as<int64_t>();
    c["createdAt"] = FormatTs(r["created_at"]);
    c["updatedAt"] = FormatTs(r["updated_at"]);
    c["body"]      = std::string(r["body"].as<std::string_view>());
    Json::Value author;
    ProfileJson(author, r, "username", "bio", "image", "following");
    c["author"] = author;
    return c;
}

bool ParseInt64(const std::string& s, int64_t& out)
{
    if (s.empty()) return false;
    size_t pos = 0;
    try { out = std::stoll(s, &pos); } catch (...) { return false; }
    return pos == s.size();
}

}

Task<HttpResponsePtr> CommentsController::ListComments(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto db = drogon::app().getDbClient();
    try
    {
        auto a = co_await db->execSqlCoro(sql::kArticleIdOnlyBySlug, slug);
        if (a.empty()) co_return common::NotFound();
        const int64_t articleId = a[0]["id"].as<int64_t>();

        auto r = co_await db->execSqlCoro(sql::kSelectComments, viewer, articleId);

        Json::Value arr(Json::arrayValue);
        for (const auto& row : r)
            arr.append(CommentJson(row));
        Json::Value root;
        root["comments"] = arr;
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> CommentsController::CreateComment(HttpRequestPtr req, std::string slug)
{
    const int64_t viewer = Viewer(req);
    auto body = req->getJsonObject();
    if (!body) co_return Unprocessable();
    const auto text = (*body)["comment"]["body"].asString();
    if (text.empty()) co_return Unprocessable();

    auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(sql::kInsertCommentBySlug, viewer, slug, text);
        if (r.empty()) co_return common::NotFound();
        Json::Value root;
        root["comment"] = CommentJson(r[0]);
        co_return MakeJson(k201Created, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> CommentsController::DeleteComment(HttpRequestPtr req, std::string slug, std::string id)
{
    const int64_t viewer = Viewer(req);
    int64_t commentId = 0;
    if (!ParseInt64(id, commentId)) co_return common::NotFound();

    auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
            " WHERE c.id = $1 AND a.slug = $2",
            commentId, slug);
        if (r.empty()) co_return common::NotFound();
        if (r[0]["author_id"].as<int64_t>() != viewer) co_return Forbidden();

        co_await db->execSqlCoro("DELETE FROM comments WHERE id = $1", commentId);
        co_return NoContent();
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}