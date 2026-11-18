#pragma once

#include "api.hpp"

namespace conduit {

#define CONDUIT_HANDLER(Class, component_name)                                \
    class Class final : public Handler {                                      \
    public:                                                                   \
        static constexpr std::string_view kName = component_name;            \
        using Handler::Handler;                                               \
                                                                              \
    protected:                                                                \
        std::string Handle(const HttpRequest& request) const override;       \
    }

CONDUIT_HANDLER(Register, "handler-register");          // POST /api/users
CONDUIT_HANDLER(Login, "handler-login");                // POST /api/users/login
CONDUIT_HANDLER(CurrentUser, "handler-current-user");   // GET, PUT /api/user
CONDUIT_HANDLER(Profile, "handler-profile");            // GET /api/profiles/{username}
CONDUIT_HANDLER(Follow, "handler-follow");              // POST, DELETE /api/profiles/{username}/follow
CONDUIT_HANDLER(Articles, "handler-articles");          // GET, POST /api/articles
CONDUIT_HANDLER(Feed, "handler-feed");                  // GET /api/articles/feed
CONDUIT_HANDLER(Article, "handler-article");            // GET, PUT, DELETE /api/articles/{slug}
CONDUIT_HANDLER(Favorite, "handler-favorite");          // POST, DELETE /api/articles/{slug}/favorite
CONDUIT_HANDLER(Comments, "handler-comments");          // GET, POST /api/articles/{slug}/comments
CONDUIT_HANDLER(Comment, "handler-comment");            // DELETE /api/articles/{slug}/comments/{id}
CONDUIT_HANDLER(Tags, "handler-tags");                  // GET /api/tags

#undef CONDUIT_HANDLER

}  // namespace conduit
