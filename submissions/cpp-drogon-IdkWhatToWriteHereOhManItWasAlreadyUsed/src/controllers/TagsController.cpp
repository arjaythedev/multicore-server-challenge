#include "TagsController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"

using namespace multicore;
using namespace multicore::common;

Task<HttpResponsePtr> TagsController::ListTags(HttpRequestPtr req)
{
    const auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(sql::kSelectTags);
        Json::Value tags(Json::arrayValue);
        for (const auto& row : r)
            tags.append(row["name"].as<std::string>());
        Json::Value root;
        root["tags"] = tags;
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}