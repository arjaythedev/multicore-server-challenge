#include "UsersController.hpp"
#include "Common.hpp"
#include "db/Sql.hpp"
#include "BCryptPool.hpp"

#include <future>

using namespace multicore;
using namespace multicore::common;

namespace {

    Task<std::string> AsyncHash(const std::string& password)
    {
        auto promise = std::make_shared<std::promise<std::string>>();
        auto fut = promise->get_future();
        BcryptPool::instance().hashAsync(password,
            [promise](std::string h) {
                promise->set_value(std::move(h));
            });
        try {
            co_return co_await multicore::FutureAwaiter<std::string>{fut.share()};
        } catch (const std::exception& e) {
            throw;
        }
    }

    Task<bool> AsyncCheck(const std::string& password, const std::string& stored)
    {
        auto promise = std::make_shared<std::promise<bool>>();
        auto fut = promise->get_future();
        BcryptPool::instance().verifyAsync(password, stored,
            [promise](const bool ok) { promise->set_value(ok); });
        co_return co_await multicore::FutureAwaiter<bool>{fut.share()};
    }

    constexpr auto kDummyHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

}

Task<HttpResponsePtr> UsersController::Register(HttpRequestPtr req)
{
    auto body = req->getJsonObject();
    if (!body) co_return Unprocessable();
    if (!body->isMember("user") || !(*body)["user"].isObject()) co_return Unprocessable();
    const auto& user = (*body)["user"];
    if (!user.isMember("username") || !user["username"].isString() ||
        !user.isMember("email")    || !user["email"].isString() ||
        !user.isMember("password") || !user["password"].isString())
        co_return Unprocessable();
    const auto username = user["username"].asString();
    const auto email    = user["email"].asString();
    const auto password = user["password"].asString();
    if (username.empty() || email.empty() || password.empty()) co_return Unprocessable();
    if (password.size() > 72) co_return Unprocessable();

    std::string hash;
    try {
        hash = co_await AsyncHash(password);
    } catch (...) {
        co_return ServerError();
    }
    if (hash.empty()) co_return ServerError();

    const auto secret = JwtSecret();
    if (secret.empty()) co_return ServerError();
    const auto db = drogon::app().getDbClient("write");
    try
    {
        const auto r = co_await db->execSqlCoro(sql::kInsertUser, username, email, hash);
        if (r.empty())
            co_return ServerError();
        const int64_t id = r[0]["id"].as<int64_t>();
        Json::Value root;
        root["user"] = UserJson(r[0], MakeToken(id, secret));
        co_return MakeJson(k201Created, root);
    }
    catch (const DrogonDbException& e)
    {
        const auto& msg = e.base().what();
        if (std::string(msg).find("23505") != std::string::npos ||
            std::string(msg).find("duplicate key") != std::string::npos)
            co_return Unprocessable();
        co_return ServerError();
    }
}

Task<HttpResponsePtr> UsersController::Login(HttpRequestPtr req)
{
    auto body = req->getJsonObject();
    if (!body) co_return Unprocessable();
    if (!body->isMember("user") || !(*body)["user"].isObject()) co_return Unprocessable();
    const auto& user = (*body)["user"];
    if (!user.isMember("email")    || !user["email"].isString() ||
        !user.isMember("password") || !user["password"].isString())
        co_return Unprocessable();
    const auto email    = user["email"].asString();
    const auto password = user["password"].asString();
    if (email.empty() || password.empty()) co_return Unprocessable();

    const auto secret = JwtSecret();
    if (secret.empty()) co_return ServerError();
    const auto db = drogon::app().getDbClient("default");
    try
    {
        auto r = co_await db->execSqlCoro(sql::kSelectUserByEmail, email);
        if (r.empty())
        {
            // Keep timing uniform for non-existent emails.
            try { (void) co_await AsyncCheck(password, kDummyHash); } catch (...) {}
            co_return Unauthorized();
        }
        const auto stored = r[0]["password_hash"].as<std::string>();
        bool ok = false;
        try { ok = co_await AsyncCheck(password, stored); }
        catch (...) { co_return ServerError(); }
        if (!ok) co_return Unauthorized();
        const int64_t id = r[0]["id"].as<int64_t>();
        Json::Value root;
        root["user"] = UserJson(r[0], MakeToken(id, secret));
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> UsersController::GetCurrentUser(HttpRequestPtr req)
{
    const int64_t viewer = Viewer(req);
    const std::string token = req->getHeader("Authorization").substr(std::string("Token ").size());
    auto db = drogon::app().getDbClient("default");
    try
    {
        auto r = co_await db->execSqlCoro(sql::kSelectUserById, viewer);
        if (r.empty()) co_return Unauthorized();
        Json::Value root;
        root["user"] = UserJson(r[0], token);
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException&) { co_return ServerError(); }
}

Task<HttpResponsePtr> UsersController::UpdateCurrentUser(HttpRequestPtr req)
{
    const int64_t viewer = Viewer(req);
    const std::string token = req->getHeader("Authorization").substr(std::string("Token ").size());

    auto body = req->getJsonObject();
    if (!body) co_return Unprocessable();
    if (!body->isMember("user") || !(*body)["user"].isObject()) co_return Unprocessable();
    const auto& user = (*body)["user"];

    if (user.isMember("email") && !user["email"].isNull() &&
        (!user["email"].isString() || user["email"].asString().empty()))
        co_return Unprocessable();
    if (user.isMember("username") && !user["username"].isNull() &&
        (!user["username"].isString() || user["username"].asString().empty()))
        co_return Unprocessable();
    if (user.isMember("password") && !user["password"].isNull() &&
        (!user["password"].isString() || user["password"].asString().empty() ||
         user["password"].asString().size() > 72))
        co_return Unprocessable();
    if (user.isMember("bio") && !user["bio"].isNull() && !user["bio"].isString())
        co_return Unprocessable();
    if (user.isMember("image") && !user["image"].isNull() && !user["image"].isString())
        co_return Unprocessable();

    auto optStr = [&](const char* key) -> std::optional<std::string> {
        if (!user.isMember(key) || user[key].isNull()) return std::nullopt;
        return user[key].asString();
    };

    auto email    = optStr("email");
    auto username = optStr("username");
    auto password = optStr("password");
    auto bio      = optStr("bio");
    auto image    = optStr("image");

    std::optional<std::string> hash;
    if (password) {
        try {
            auto h = co_await AsyncHash(*password);
            if (!h.empty()) hash = std::move(h);
        } catch (...) {
            co_return ServerError();
        }
    }

    auto db = drogon::app().getDbClient("write");
    try
    {
        auto r = co_await db->execSqlCoro(
            sql::kUpdateUser, viewer, email, username, hash, bio, image);
        if (r.empty()) co_return Unauthorized();
        Json::Value root;
        root["user"] = UserJson(r[0], token);
        co_return MakeJson(k200OK, root);
    }
    catch (const DrogonDbException& e)
    {
        const auto& msg = e.base().what();
        if (std::string(msg).find("23505") != std::string::npos ||
            std::string(msg).find("duplicate key") != std::string::npos)
            co_return Unprocessable();
        co_return ServerError();
    }
}