#pragma once

#include <drogon/HttpMiddleware.h>
#include <trantor/utils/Logger.h>
#include <optional>
#include <string>
#include <drogon/HttpAppFramework.h>

#include <jwt-cpp/jwt.h>

namespace multicore::jwtutil
{

inline std::optional<int64_t> ExtractViewer(const std::string& authHeader)
{
    static const std::string kPrefix = "Token ";

    if (authHeader.empty() || authHeader.size() <= kPrefix.size() ||
        authHeader.compare(0, kPrefix.size(), kPrefix) != 0)
    {
        return std::nullopt;
    }

    const auto token = authHeader.substr(kPrefix.size());

    static const std::string secret = (std::getenv("JWT_SECRET"));

    if (secret.empty())
    {
        LOG_ERROR << "JWT_SECRET is not set";
        return -1;
    }

    try
    {
        const auto decoded = jwt::decode(token);

        if (decoded.get_algorithm() != "HS256")
        {
            return -1;
        }

        const auto verifier =
            jwt::verify()
                .allow_algorithm(jwt::algorithm::hs256{secret})
                .leeway(0);
        verifier.verify(decoded);

        if (!decoded.has_payload_claim("sub") || !decoded.has_payload_claim("exp"))
        {
            return -1;
        }

        const auto exp = decoded.get_payload_claim("exp").as_integer();
        const auto now = std::chrono::duration_cast<std::chrono::seconds>(
                             std::chrono::system_clock::now().time_since_epoch())
                             .count();
        if (exp <= now)
        {
            return -1;
        }

        const auto sub = decoded.get_payload_claim("sub").as_string();
        if (sub.empty())
        {
            return -1;
        }

        size_t pos = 0;
        int64_t viewer = 0;
        try
        {
            viewer = std::stoll(sub, &pos);
        }
        catch (...)
        {
            return -1;
        }
        if (pos != sub.size() || viewer <= 0)
        {
            return -1;
        }

        return viewer;
    }
    catch (const std::exception& e)
    {
        LOG_WARN << "JWT decode/verify failed: " << e.what();
        return -1;
    }
}

} // namespace multicore::jwtutil

namespace multicore
{

using namespace drogon;

class AuthRequiredMiddleware : public HttpMiddleware<AuthRequiredMiddleware, false>
{
public:
    AuthRequiredMiddleware() = default;

    void invoke(const HttpRequestPtr& req,
                MiddlewareNextCallback&& nextCb,
                MiddlewareCallback&& mcb) override
    {
        const auto header = req->getHeader("Authorization");
        const auto viewer = jwtutil::ExtractViewer(header);

        if (!viewer.has_value() || *viewer <= 0)
        {
            const auto response = HttpResponse::newHttpResponse();
            response->setStatusCode(k401Unauthorized);
            response->setContentTypeCode(ContentType::CT_APPLICATION_JSON);
            static const std::string body = R"({"errors":{"body":["Unauthorized"]}})";
            response->setBody(body);
            mcb(response);
            return;
        }

        req->attributes()->insert("viewer", *viewer);

        nextCb
        (
            [mcb = std::move(mcb)](const HttpResponsePtr& resp)
            {
                mcb(resp);
            }
        );
    }
};

class AuthOptionalMiddleware : public HttpMiddleware<AuthOptionalMiddleware, false>
{
public:
    AuthOptionalMiddleware() = default;

    void invoke(const HttpRequestPtr& req,
                MiddlewareNextCallback&& nextCb,
                MiddlewareCallback&& mcb) override
    {
        const auto header = req->getHeader("Authorization");
        const auto viewer = jwtutil::ExtractViewer(header);

        if (!viewer.has_value())
        {
            req->attributes()->insert("viewer", static_cast<int64_t>(0));
            nextCb
            (
                [mcb = std::move(mcb)](const HttpResponsePtr& resp)
                {
                    mcb(resp);
                }
            );
            return;
        }

        if (*viewer <= 0)
        {
            const auto response = HttpResponse::newHttpResponse();
            response->setStatusCode(k401Unauthorized);
            response->setContentTypeCode(ContentType::CT_APPLICATION_JSON);
            static const std::string body = R"({"errors":{"body":["Unauthorized"]}})";
            response->setBody(body);
            mcb(response);
            return;
        }

        req->attributes()->insert("viewer", *viewer);
        nextCb
        (
            [mcb = std::move(mcb)](const HttpResponsePtr& resp)
            {
                mcb(resp);
            }
        );
    }
};

} // namespace multicore