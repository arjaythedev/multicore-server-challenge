#include "api.hpp"

#include <cstdlib>
#include <stdexcept>
#include <vector>

#include <userver/formats/json/serialize.hpp>
#include <userver/http/common_headers.hpp>
#include <userver/http/content_type.hpp>
#include <userver/server/http/http_response.hpp>
#include <userver/storages/postgres/component.hpp>
#include <userver/storages/postgres/io/array_types.hpp>
#include <userver/storages/postgres/io/optional.hpp>
#include <userver/storages/postgres/io/string_types.hpp>

namespace conduit {

const Jwt& TheJwt() {
    static const Jwt jwt([] {
        const char* s = std::getenv("JWT_SECRET");
        if (!s || !*s) throw std::runtime_error("JWT_SECRET is not set");
        return std::string_view(s);
    }());
    return jwt;
}

Handler::Handler(const us::components::ComponentConfig& config, const us::components::ComponentContext& context)
    : HttpHandlerBase(config, context),
      pg_(context.FindComponent<us::components::Postgres>("conduit-db").GetCluster()),
      cpu_tp_(context.GetTaskProcessor("bcrypt-task-processor")) {
    TheJwt();  // fail at startup, not on the first request, if JWT_SECRET is missing
}

std::string Handler::HandleRequestThrow(const HttpRequest& request, us::server::request::RequestContext&) const {
    request.GetHttpResponse().SetContentType(us::http::content_type::kApplicationJson);
    try {
        return Handle(request);
    } catch (const ApiError& e) {
        request.SetResponseStatus(e.status);
        return ErrorBody(e.msg);
    }
}

namespace {

// Returns {present, id}: id is 0 when the header is present but invalid.
std::pair<bool, std::int64_t> ParseAuth(const HttpRequest& request, std::string_view& token) {
    if (!request.HasHeader(us::http::headers::kAuthorization)) return {false, 0};
    const std::string& h = request.GetHeader(us::http::headers::kAuthorization);
    constexpr std::string_view kScheme = "Token ";
    if (h.size() <= kScheme.size() || std::string_view(h).substr(0, kScheme.size()) != kScheme) return {true, 0};
    token = std::string_view(h).substr(kScheme.size());
    return {true, TheJwt().Verify(token)};
}

}  // namespace

Handler::Viewer Handler::RequireAuth(const HttpRequest& request) {
    std::string_view token;
    const auto [present, id] = ParseAuth(request, token);
    if (id == 0) Unauthorized();
    return {id, token};
}

std::int64_t Handler::OptionalAuth(const HttpRequest& request) {
    std::string_view token;
    const auto [present, id] = ParseAuth(request, token);
    if (present && id == 0) Unauthorized();
    return id;
}

json::Value ReadWrapper(const HttpRequest& request, std::string_view key) {
    json::Value top;
    try {
        top = json::FromString(request.RequestBody());
    } catch (const std::exception&) {
        Unprocessable();
    }
    if (!top.IsObject()) Unprocessable();
    auto inner = top[std::string(key)];
    if (!inner.IsObject()) Unprocessable();
    return inner;
}

std::optional<std::string> OptString(const json::Value& obj, std::string_view key, bool non_empty) {
    const auto v = obj[std::string(key)];
    if (v.IsMissing() || v.IsNull()) return std::nullopt;
    if (!v.IsString()) Unprocessable();
    auto s = v.As<std::string>();
    if (non_empty && s.empty()) Unprocessable();
    return s;
}

std::string ReqString(const json::Value& obj, std::string_view key) {
    auto s = OptString(obj, key, true);
    if (!s) Unprocessable();
    return std::move(*s);
}

Page ParsePage(const HttpRequest& request) {
    Page p;
    if (request.HasArg("limit")) {
        if (!ParseUint(request.GetArg("limit"), p.limit) || p.limit < 1 || p.limit > 100) {
            Unprocessable("invalid limit");
        }
    }
    if (request.HasArg("offset")) {
        if (!ParseUint(request.GetArg("offset"), p.offset)) Unprocessable("invalid offset");
    }
    return p;
}

std::string ErrorBody(std::string_view msg) {
    JsonOut j;
    j.Raw("{\"errors\":{\"body\":[");
    j.Str(msg);
    j.Raw("]}}");
    return std::move(j.Get());
}

void WriteArticle(JsonOut& j, const pg::Row& row, std::size_t base, bool with_body) {
    // id, slug, title, description, [body], created_at, updated_at, tag_list, favorites_count, favorited,
    // username, bio, image, following
    std::size_t i = base + 1;
    j.Raw("{\"slug\":");
    j.Str(row[i++].As<std::string_view>());
    j.Raw(",\"title\":");
    j.Str(row[i++].As<std::string_view>());
    j.Raw(",\"description\":");
    j.Str(row[i++].As<std::string_view>());
    if (with_body) {
        j.Raw(",\"body\":");
        j.Str(row[i++].As<std::string_view>());
    }
    j.Raw(",\"createdAt\":");
    j.Time(row[i++].As<TimeTz>().GetUnderlying());
    j.Raw(",\"updatedAt\":");
    j.Time(row[i++].As<TimeTz>().GetUnderlying());
    j.Raw(",\"tagList\":[");
    {
        const auto tags = row[i++].As<std::vector<std::string>>();
        bool first = true;
        for (const auto& t : tags) {
            if (!first) j.Raw(",");
            first = false;
            j.Str(t);
        }
    }
    j.Raw("],\"favoritesCount\":");
    j.Int(row[i++].As<std::int64_t>());
    j.Raw(",\"favorited\":");
    j.Bool(row[i++].As<bool>());
    j.Raw(",\"author\":");
    const auto username = row[i++].As<std::string_view>();
    const auto bio = row[i++].As<std::optional<std::string_view>>();
    const auto image = row[i++].As<std::optional<std::string_view>>();
    const auto following = row[i++].As<bool>();
    WriteProfile(j, username, bio, image, following);
    j.Raw("}");
}

}  // namespace conduit
