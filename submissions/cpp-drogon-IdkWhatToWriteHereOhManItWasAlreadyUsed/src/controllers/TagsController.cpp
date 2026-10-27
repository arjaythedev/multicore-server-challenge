#include "TagsController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"

#include <algorithm>
#include <vector>
#include <string>

using namespace multicore;
using namespace multicore::common;

Task<HttpResponsePtr> TagsController::ListTags(HttpRequestPtr req)
{
    const auto db = drogon::app().getDbClient();
    try
    {
        auto r = co_await db->execSqlCoro(sql::kSelectTags);

        std::vector<std::string> tags;
        tags.reserve(r.size());
        for (const auto& row : r)
            tags.push_back(row["name"].as<std::string>());
        std::ranges::sort(tags);

        Json::Value arr(Json::arrayValue);
        for (auto& t : tags) arr.append(t);

        Json::Value root;
        root["tags"] = arr;
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}