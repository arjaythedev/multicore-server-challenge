#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include <userver/components/component_config.hpp>
#include <userver/components/component_context.hpp>
#include <userver/engine/async.hpp>
#include <userver/engine/task/task_processor_fwd.hpp>
#include <userver/formats/json/value.hpp>
#include <userver/server/handlers/http_handler_base.hpp>
#include <userver/server/http/http_request.hpp>
#include <userver/storages/postgres/cluster.hpp>
#include <userver/storages/postgres/io/chrono.hpp>
#include <userver/storages/postgres/result_set.hpp>

#include "auth.hpp"
#include "util.hpp"

namespace conduit {

namespace us = USERVER_NAMESPACE;
namespace pg = us::storages::postgres;
namespace json = us::formats::json;
using us::server::http::HttpMethod;
using us::server::http::HttpRequest;
using Status = us::server::http::HttpStatus;

constexpr auto kMaster = pg::ClusterHostType::kMaster;

// Thrown by handlers to answer with {"errors": {"body": [msg]}}.
struct ApiError {
    Status status;
    const char* msg;
};

[[noreturn]] inline void Fail(Status status, const char* msg) { throw ApiError{status, msg}; }
[[noreturn]] inline void Unauthorized() { Fail(Status::kUnauthorized, "unauthorized"); }
[[noreturn]] inline void Unprocessable(const char* msg = "invalid body") { Fail(Status::kUnprocessableEntity, msg); }
[[noreturn]] inline void NotFound() { Fail(Status::kNotFound, "not found"); }
[[noreturn]] inline void Forbidden() { Fail(Status::kForbidden, "forbidden"); }

const Jwt& TheJwt();

class Handler : public us::server::handlers::HttpHandlerBase {
public:
    Handler(const us::components::ComponentConfig& config, const us::components::ComponentContext& context);

    std::string HandleRequestThrow(const HttpRequest& request, us::server::request::RequestContext&) const final;

protected:
    virtual std::string Handle(const HttpRequest& request) const = 0;

    struct Viewer {
        std::int64_t id;
        std::string_view token;
    };
    // Missing or invalid token -> 401.
    static Viewer RequireAuth(const HttpRequest& request);
    // No header -> 0. A header that is present but invalid -> 401.
    static std::int64_t OptionalAuth(const HttpRequest& request);

    // Runs CPU-heavy work (bcrypt) on its own task processor so the HTTP workers stay responsive.
    template <typename F>
    auto Cpu(F&& f) const {
        return us::engine::AsyncNoTracing(cpu_tp_, std::forward<F>(f)).Get();
    }

    pg::Cluster& Db() const { return *pg_; }

private:
    pg::ClusterPtr pg_;
    us::engine::TaskProcessor& cpu_tp_;
};

// ---------- request parsing ----------

// Parses the body as {"<key>": {...}} and returns the inner object; anything else -> 422.
json::Value ReadWrapper(const HttpRequest& request, std::string_view key);
// Absent or null -> nullopt; a string -> it; anything else -> 422. With non_empty, "" -> 422 too.
std::optional<std::string> OptString(const json::Value& obj, std::string_view key, bool non_empty);
// Must be present and a non-empty string, else 422.
std::string ReqString(const json::Value& obj, std::string_view key);

struct Page {
    std::int64_t limit = 20;
    std::int64_t offset = 0;
};
// limit (default 20, 1..100) and offset (default 0, >= 0); a present but invalid value -> 422.
Page ParsePage(const HttpRequest& request);

// ---------- response writing ----------

std::string ErrorBody(std::string_view msg);

using TimeTz = pg::TimePointTz;
using OptStr = std::optional<std::string_view>;

inline void WriteProfile(JsonOut& j, std::string_view username, const OptStr& bio, const OptStr& image,
                         bool following) {
    j.Raw("{\"username\":");
    j.Str(username);
    j.Raw(",\"bio\":");
    j.OptStr(bio);
    j.Raw(",\"image\":");
    j.OptStr(image);
    j.Raw(",\"following\":");
    j.Bool(following);
    j.Raw("}");
}

// Columns of ARTICLE_LIST_SELECT / ARTICLE_FULL_SELECT starting at `base`.
void WriteArticle(JsonOut& j, const pg::Row& row, std::size_t base, bool with_body);

}  // namespace conduit
