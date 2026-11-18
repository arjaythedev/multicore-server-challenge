#include "handlers.hpp"

#include <userver/storages/postgres/io/optional.hpp>
#include <userver/storages/postgres/io/string_types.hpp>

namespace conduit {

namespace {

// The slug check and the newest 100 comments in one round trip: no row means no article,
// a row with a NULL comment id means an article without comments.
const pg::Query kListComments{
    "WITH a AS (SELECT id FROM articles WHERE slug = $2) "
    "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following "
    "FROM a LEFT JOIN LATERAL ("
    "  SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
    "  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
    "  FROM comments c JOIN users u ON u.id = c.author_id "
    "  WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100"
    ") c ON true "
    "ORDER BY c.created_at DESC, c.id DESC",
    pg::Query::Name{"list_comments"}};

const pg::Query kInsertComment{
    "WITH a AS (SELECT id FROM articles WHERE slug = $1), "
    "c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a "
    "RETURNING id, body, created_at, updated_at, author_id) "
    "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image "
    "FROM c JOIN users u ON u.id = c.author_id",
    pg::Query::Name{"insert_comment"}};

const pg::Query kCommentOwner{
    "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
    pg::Query::Name{"comment_owner"}};

const pg::Query kDeleteComment{"DELETE FROM comments WHERE id = $1", pg::Query::Name{"delete_comment"}};

// Columns from `base`: id, body, created_at, updated_at, username, bio, image[, following].
void WriteComment(JsonOut& j, const pg::Row& row, std::size_t base, bool following) {
    j.Raw("{\"id\":");
    j.Int(row[base].As<std::int64_t>());
    j.Raw(",\"createdAt\":");
    j.Time(row[base + 2].As<TimeTz>().GetUnderlying());
    j.Raw(",\"updatedAt\":");
    j.Time(row[base + 3].As<TimeTz>().GetUnderlying());
    j.Raw(",\"body\":");
    j.Str(row[base + 1].As<std::string_view>());
    j.Raw(",\"author\":");
    WriteProfile(j, row[base + 4].As<std::string_view>(), row[base + 5].As<std::optional<std::string_view>>(),
                 row[base + 6].As<std::optional<std::string_view>>(), following);
    j.Raw("}");
}

}  // namespace

std::string Comments::Handle(const HttpRequest& request) const {
    const auto& slug = request.GetPathArg("slug");

    if (request.GetMethod() == HttpMethod::kGet) {
        const auto viewer = OptionalAuth(request);
        const auto res = Db().Execute(kMaster, kListComments, viewer, slug);
        if (res.IsEmpty()) NotFound();
        JsonOut j;
        j.Raw("{\"comments\":[");
        bool first = true;
        for (const auto& row : res) {
            if (row[1].IsNull()) continue;
            if (!first) j.Raw(",");
            first = false;
            WriteComment(j, row, 1, row[8].As<bool>());
        }
        j.Raw("]}");
        return std::move(j.Get());
    }

    // POST
    const auto viewer = RequireAuth(request);
    const auto c = ReadWrapper(request, "comment");
    const auto body = ReqString(c, "body");
    const auto res = Db().Execute(kMaster, kInsertComment, slug, viewer.id, body);
    if (res.IsEmpty()) NotFound();
    JsonOut j;
    j.Raw("{\"comment\":");
    WriteComment(j, res[0], 0, false);
    j.Raw("}");
    request.SetResponseStatus(Status::kCreated);
    return std::move(j.Get());
}

std::string Comment::Handle(const HttpRequest& request) const {
    const auto viewer = RequireAuth(request);
    std::int64_t id = 0;
    if (!ParseUint(request.GetPathArg("id"), id)) NotFound();

    const auto owner = Db().Execute(kMaster, kCommentOwner, id, request.GetPathArg("slug"));
    if (owner.IsEmpty()) NotFound();
    if (owner[0][0].As<std::int64_t>() != viewer.id) Forbidden();

    Db().Execute(kMaster, kDeleteComment, id);
    request.SetResponseStatus(Status::kNoContent);
    return {};
}

}  // namespace conduit
