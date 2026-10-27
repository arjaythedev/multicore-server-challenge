#include "handlers.hpp"

#include <userver/storages/postgres/exceptions.hpp>
#include <userver/storages/postgres/io/optional.hpp>
#include <userver/storages/postgres/io/string_types.hpp>

namespace conduit {

namespace {

const pg::Query kInsertUser{
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
    "RETURNING id, username, email, bio, image",
    pg::Query::Name{"insert_user"}};

const pg::Query kUserByEmail{
    "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
    pg::Query::Name{"user_by_email"}};

const pg::Query kUserById{
    "SELECT id, username, email, bio, image FROM users WHERE id = $1",
    pg::Query::Name{"user_by_id"}};

const pg::Query kUpdateUser{
    "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
    "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
    "WHERE id = $1 RETURNING id, username, email, bio, image",
    pg::Query::Name{"update_user"}};

constexpr std::size_t kMaxPassword = 72;  // bcrypt only uses the first 72 bytes

// Row: id, username, email, bio, image.
std::string UserBody(const pg::Row& row, std::string_view token) {
    JsonOut j;
    j.Raw("{\"user\":{\"email\":");
    j.Str(row[2].As<std::string_view>());
    j.Raw(",\"token\":");
    j.Str(token);
    j.Raw(",\"username\":");
    j.Str(row[1].As<std::string_view>());
    j.Raw(",\"bio\":");
    j.OptStr(row[3].As<std::optional<std::string_view>>());
    j.Raw(",\"image\":");
    j.OptStr(row[4].As<std::optional<std::string_view>>());
    j.Raw("}}");
    return std::move(j.Get());
}

}  // namespace

std::string Register::Handle(const HttpRequest& request) const {
    const auto u = ReadWrapper(request, "user");
    const auto username = ReqString(u, "username");
    const auto email = ReqString(u, "email");
    const auto password = ReqString(u, "password");
    if (password.size() > kMaxPassword) Unprocessable("password is longer than 72 bytes");

    const auto hash = Cpu([&] { return BcryptHash(password); });
    const auto res = [&] {
        try {
            return Db().Execute(kMaster, kInsertUser, username, email, hash);
        } catch (const pg::UniqueViolation&) {
            Unprocessable("username or email has already been taken");
        }
    }();
    request.SetResponseStatus(Status::kCreated);
    return UserBody(res[0], TheJwt().Issue(res[0][0].As<std::int64_t>()));
}

std::string Login::Handle(const HttpRequest& request) const {
    const auto u = ReadWrapper(request, "user");
    const auto email = ReqString(u, "email");
    const auto password = ReqString(u, "password");

    const auto res = Db().Execute(kMaster, kUserByEmail, email);
    if (res.IsEmpty()) Fail(Status::kUnauthorized, "invalid email or password");
    const auto hash = res[0][5].As<std::string>();
    if (!Cpu([&] { return BcryptCheck(password, hash); })) Fail(Status::kUnauthorized, "invalid email or password");
    return UserBody(res[0], TheJwt().Issue(res[0][0].As<std::int64_t>()));
}

std::string CurrentUser::Handle(const HttpRequest& request) const {
    const auto viewer = RequireAuth(request);

    if (request.GetMethod() == HttpMethod::kGet) {
        const auto res = Db().Execute(kMaster, kUserById, viewer.id);
        if (res.IsEmpty()) Unauthorized();
        return UserBody(res[0], viewer.token);
    }

    // PUT
    const auto u = ReadWrapper(request, "user");
    const auto email = OptString(u, "email", true);
    const auto username = OptString(u, "username", true);
    const auto password = OptString(u, "password", true);
    const auto bio = OptString(u, "bio", false);
    const auto image = OptString(u, "image", false);
    if (password && password->size() > kMaxPassword) Unprocessable("password is longer than 72 bytes");

    std::optional<std::string> hash;
    if (password) hash = Cpu([&] { return BcryptHash(*password); });

    const auto res = [&] {
        try {
            return Db().Execute(kMaster, kUpdateUser, viewer.id, email, username, hash, bio, image);
        } catch (const pg::UniqueViolation&) {
            Unprocessable("username or email has already been taken");
        }
    }();
    if (res.IsEmpty()) Unauthorized();
    return UserBody(res[0], viewer.token);
}

}  // namespace conduit
