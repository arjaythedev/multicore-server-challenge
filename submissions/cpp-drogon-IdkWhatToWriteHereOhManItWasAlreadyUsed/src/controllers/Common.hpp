#pragma once

#include <drogon/drogon.h>
#include <drogon/orm/DbClient.h>
#include <drogon/orm/Result.h>
#include <jwt-cpp/jwt.h>
#include <random>
#include <string>
#include <string_view>
#include <vector>
#include <algorithm>
#include "bcrypt.hpp"
#include "robin_hood.h"
#include "db/Sql.hpp"

namespace multicore::common
{
    using namespace drogon;
    using namespace drogon::orm;

    inline std::string ToPgBigintArray(const std::vector<int64_t>& v)
    {
        std::string out = "{";
        for (size_t i = 0; i < v.size(); ++i)
        {
            if (i) out += ',';
            out += std::to_string(v[i]);
        }
        out += '}';
        return out;
    }

    inline HttpResponsePtr MakeJson(HttpStatusCode code, const Json::Value& v)
    {
        auto resp = HttpResponse::newHttpResponse();
        resp->setStatusCode(code);
        resp->setContentTypeCode(ContentType::CT_APPLICATION_JSON);
        resp->setBody(Json::FastWriter().write(v));
        return resp;
    }

    inline HttpResponsePtr MakeError(HttpStatusCode code, const std::string& msg)
    {
        Json::Value root;
        root["errors"]["body"].append(msg);
        return MakeJson(code, root);
    }

    inline HttpResponsePtr Unauthorized() { return MakeError(k401Unauthorized, "Unauthorized"); }
    inline HttpResponsePtr Forbidden()    { return MakeError(k403Forbidden, "Forbidden"); }
    inline HttpResponsePtr NotFound()     { return MakeError(k404NotFound, "Not found"); }
    inline HttpResponsePtr Unprocessable(){ return MakeError(k422UnprocessableEntity, "Unprocessable"); }
    inline HttpResponsePtr ServerError()  { return MakeError(k500InternalServerError, "Internal"); }

    inline HttpResponsePtr NoContent()
    {
        auto resp = HttpResponse::newHttpResponse();
        resp->setStatusCode(k204NoContent);
        return resp;
    }

    inline int64_t Viewer(const HttpRequestPtr& req)
    {
        return req->attributes()->get<int64_t>("viewer");
    }

    inline trantor::Date FieldToDate(const Field& f)
    {
        if (f.isNull()) return trantor::Date{};
        return trantor::Date::fromISOString(std::string(f.as<std::string_view>()));
    }

    inline std::string FormatTs(const Field& f)
    {
        if (f.isNull()) return "1970-01-01T00:00:00.000Z";
        const auto us = FieldToDate(f).microSecondsSinceEpoch();
        const auto ms = us / 1000;
        time_t secs = ms / 1000;
        int millis = static_cast<int>(ms % 1000);
        if (millis < 0) { millis += 1000; secs -= 1; }
        tm tm{};
        gmtime_r(&secs, &tm);
        char buf[32];
        snprintf(buf, sizeof(buf), "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                 tm.tm_hour, tm.tm_min, tm.tm_sec, millis);
        return buf;
    }

    inline void ProfileJson(Json::Value& out, const Row& r,
                            const char* userCol, const char* bioCol,
                            const char* imgCol, const char* followCol)
    {
        out["username"] = r[userCol].as<std::string>();
        out["bio"]      = r[bioCol].isNull() ? Json::Value() : Json::Value(r[bioCol].as<std::string>());
        out["image"]    = r[imgCol].isNull() ? Json::Value() : Json::Value(r[imgCol].as<std::string>());
        out["following"]= r[followCol].as<bool>();
    }

    inline Json::Value ArticleJson(const Row& r, bool withBody)
    {
        Json::Value a;
        a["slug"]        = std::string(r["slug"].as<std::string_view>());
        a["title"]       = std::string(r["title"].as<std::string_view>());
        a["description"] = std::string(r["description"].as<std::string_view>());
        if (withBody)
            a["body"] = std::string(r["body"].as<std::string_view>());

        Json::Value tags(Json::arrayValue);
        for (auto& p : r["tag_list"].asArray<std::string>())
            if (p) tags.append(*p);
        a["tagList"]        = tags;
        a["createdAt"]      = FormatTs(r["created_at"]);
        a["updatedAt"]      = FormatTs(r["updated_at"]);
        a["favorited"]      = r["favorited"].as<bool>();
        a["favoritesCount"] = r["favorites_count"].as<int64_t>();

        Json::Value author;
        ProfileJson(author, r, "username", "bio", "image", "following");
        a["author"] = author;
        return a;
    }

    struct ArticleExtras
    {
        robin_hood::unordered_flat_map<int64_t, std::vector<std::string>> tags;
        robin_hood::unordered_flat_map<int64_t, int64_t> favoriteCounts;
        robin_hood::unordered_flat_set<int64_t> favorited;
        robin_hood::unordered_flat_set<int64_t> following;
    };
    inline Json::Value ArticleJsonWithExtras(const Row& r, bool withBody,
                                             const ArticleExtras& ex)
    {
        const int64_t id = r["id"].as<int64_t>();
        const int64_t authorId = r["author_id"].as<int64_t>();

        Json::Value a;
        a["slug"]        = std::string(r["slug"].as<std::string_view>());
        a["title"]       = std::string(r["title"].as<std::string_view>());
        a["description"] = std::string(r["description"].as<std::string_view>());
        if (withBody)
            a["body"] = std::string(r["body"].as<std::string_view>());

        Json::Value tags(Json::arrayValue);
        if (auto it = ex.tags.find(id); it != ex.tags.end())
            for (const auto& t : it->second) tags.append(t);
        a["tagList"] = tags;

        a["createdAt"] = FormatTs(r["created_at"]);
        a["updatedAt"] = FormatTs(r["updated_at"]);

        a["favorited"] = ex.favorited.count(id) > 0;
        auto fc = ex.favoriteCounts.find(id);
        a["favoritesCount"] = static_cast<Json::Int64>(fc != ex.favoriteCounts.end() ? fc->second : 0);

        Json::Value author;
        author["username"] = std::string(r["username"].as<std::string_view>());
        author["bio"]      = r["bio"].isNull() ? Json::Value() : Json::Value(r["bio"].as<std::string>());
        author["image"]    = r["image"].isNull() ? Json::Value() : Json::Value(r["image"].as<std::string>());
        author["following"]= ex.following.count(authorId) > 0;
        a["author"] = author;

        return a;
    }

    inline Json::Value UserJson(const Row& r, const std::string& token)
    {
        Json::Value u;
        u["email"]    = r["email"].as<std::string>();
        u["token"]    = token;
        u["username"] = r["username"].as<std::string>();
        u["bio"]      = r["bio"].isNull() ? Json::Value() : Json::Value(r["bio"].as<std::string>());
        u["image"]    = r["image"].isNull() ? Json::Value() : Json::Value(r["image"].as<std::string>());
        return u;
    }

    struct PageParams { int limit; int offset; bool ok; };

    inline PageParams ParsePage(const HttpRequestPtr& req)
    {
        int limit = 20, offset = 0;
        auto& ps = req->getParameters();
        auto parseInt = [](const std::string& s, int& out) -> bool {
            if (s.empty()) return false;
            for (char c : s) if (c < '0' || c > '9') return false;
            try { out = std::stoi(s); } catch (...) { return false; }
            return true;
        };
        auto it = ps.find("limit");
        if (it != ps.end()) {
            if (!parseInt(it->second, limit)) return {0,0,false};
            if (limit < 1 || limit > 100) return {0,0,false};
        }
        it = ps.find("offset");
        if (it != ps.end()) {
            if (!parseInt(it->second, offset)) return {0,0,false};
            if (offset < 0) return {0,0,false};
        }
        return {limit, offset, true};
    }

    inline std::string Slugify(const std::string& x)
    {
        std::string s;
        s.reserve(x.size());
        bool prevDash = false;
        for (char c : x)
        {
            char out = 0;
            if (c >= 'A' && c <= 'Z') out = static_cast<char>(c - 'A' + 'a');
            else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) out = c;
            if (out) { s.push_back(out); prevDash = false; }
            else if (!prevDash) { s.push_back('-'); prevDash = true; }
        }
        if (!s.empty() && s.front() == '-') s.erase(s.begin());
        if (!s.empty() && s.back() == '-') s.pop_back();
        return s;
    }

    inline std::string JwtSecret()
    {
        const char* s = std::getenv("JWT_SECRET");
        return s ? std::string(s) : std::string();
    }

    inline std::string MakeToken(int64_t userId, const std::string& secret)
    {
        const auto now = std::chrono::system_clock::now();
        const auto exp = now + std::chrono::hours(24 * 30);
        return jwt::create()
            .set_algorithm("HS256")
            .set_type("JWT")
            .set_payload_claim("sub", jwt::claim(std::to_string(userId)))
            .set_issued_at(now)
            .set_expires_at(exp)
            .sign(jwt::algorithm::hs256{secret});
    }

    inline std::string BcryptGensalt()
    {
        std::random_device rd;
        uint8_t raw[16];
        for (auto& b : raw) b = static_cast<uint8_t>(rd());
        std::string out;
        out.reserve(7 + 22);
        out.append("$2b$10$");
        bcrypt::b64_encode(out, raw, 16);
        return out;
    }

    inline std::string BcryptHash(const std::string& password)
    {
        bcrypt::Job j;
        const auto setting = BcryptGensalt();
        if (!bcrypt::prepare(j, password, setting))
            throw std::runtime_error("bcrypt prepare failed");
        bcrypt::Job* jobs[1] = {&j};
        bcrypt::compute(jobs, 1);
        return j.result;
    }

    inline bool BcryptCheck(const std::string& password, const std::string& hash)
    {
        bcrypt::Job j;
        if (!bcrypt::prepare(j, password, hash)) return false;
        bcrypt::Job* jobs[1] = {&j};
        bcrypt::compute(jobs, 1);
        return j.result == hash;
    }


    inline Task<bool> LoadArticleExtras(const DbClientPtr db, int64_t viewer,
                                        const std::vector<int64_t>& articleIds,
                                        const std::vector<int64_t>& authorIds,
                                        ArticleExtras& ex)
    {
        const auto articleIdsLiteral = ToPgBigintArray(articleIds);
        const auto authorIdsLiteral  = ToPgBigintArray(authorIds);

        try
        {
            if (!articleIds.empty())
            {
                auto tags = co_await db->execSqlCoro(sql::kTagsForArticles, articleIdsLiteral);
                for (const auto& row : tags)
                {
                    const int64_t aid = row["article_id"].as<int64_t>();
                    ex.tags[aid].push_back(row["name"].as<std::string>());
                }

                for (auto& kv : ex.tags)
                    std::ranges::sort(kv.second);

                const auto counts = co_await db->execSqlCoro(sql::kFavoriteCountsForArticles, articleIdsLiteral);
                for (const auto& row : counts)
                    ex.favoriteCounts[row["article_id"].as<int64_t>()] = row["cnt"].as<int64_t>();

                if (viewer > 0)
                {
                    auto favs = co_await db->execSqlCoro(sql::kFavoritedForViewer, viewer, articleIdsLiteral);
                    for (const auto& row : favs)
                        ex.favorited.insert(row["article_id"].as<int64_t>());
                }
            }

            if (!authorIds.empty() && viewer > 0)
            {
                auto follows = co_await db->execSqlCoro(sql::kFollowingForViewer, viewer, authorIdsLiteral);
                for (const auto& row : follows)
                    ex.following.insert(row["followee_id"].as<int64_t>());
            }
        }
        catch (const DrogonDbException&)
        {
            co_return false;
        }
        co_return true;
    }
}
