package conduit.app

import conduit.json.JsonName
import conduit.json.JsonWriter
import conduit.pg.Result
import conduit.pg.Row

// Response JSON, written straight from binary rows (text columns are copied as UTF-8, never decoded to Strings).
// Key sets are exact (conformance checks them): list articles have no "body", single articles do.

internal val N_USER = JsonName("user")
internal val N_PROFILE = JsonName("profile")
internal val N_ARTICLE = JsonName("article")
internal val N_ARTICLES = JsonName("articles")
internal val N_ARTICLES_COUNT = JsonName("articlesCount")
internal val N_COMMENT = JsonName("comment")
internal val N_COMMENTS = JsonName("comments")
internal val N_TAGS = JsonName("tags")
internal val N_EMAIL = JsonName("email")
internal val N_TOKEN = JsonName("token")
internal val N_USERNAME = JsonName("username")
internal val N_BIO = JsonName("bio")
internal val N_IMAGE = JsonName("image")
internal val N_FOLLOWING = JsonName("following")
internal val N_SLUG = JsonName("slug")
internal val N_TITLE = JsonName("title")
internal val N_DESCRIPTION = JsonName("description")
internal val N_BODY = JsonName("body")
internal val N_TAG_LIST = JsonName("tagList")
internal val N_CREATED_AT = JsonName("createdAt")
internal val N_UPDATED_AT = JsonName("updatedAt")
internal val N_FAVORITED = JsonName("favorited")
internal val N_FAVORITES_COUNT = JsonName("favoritesCount")
internal val N_AUTHOR = JsonName("author")
internal val N_ID = JsonName("id")

/** Profile members from columns username, bio, image at [c]; [following] given by the caller. */
internal fun JsonWriter.profile(r: Row, c: Int, following: Boolean) {
    beginObject()
    name(N_USERNAME); text(r, c)
    name(N_BIO); text(r, c + 1)
    name(N_IMAGE); text(r, c + 2)
    name(N_FOLLOWING); bool(following)
    endObject()
}

/**
 * Article from the layout at [c]: slug, title, description, [body], created_at, updated_at, tag_list,
 * favorites_count, favorited, username, bio, image, following. [flags]: the rows are shared between requests (a
 * [conduit.db.Sharing.GROUPS] read) and carry no viewer flags: favorited and following come from this request's flag rows
 * ([conduit.pg.Result.hasFlag]: the article id when the viewer favorited it, minus the author id when they follow the
 * author), and the article and author ids are the two columns after the layout.
 */
internal fun JsonWriter.article(r: Row, c: Int, withBody: Boolean, flags: Result? = null) {
    beginObject()
    name(N_SLUG); text(r, c)
    name(N_TITLE); text(r, c + 1)
    name(N_DESCRIPTION); text(r, c + 2)
    var p = c + 3
    if (withBody) { name(N_BODY); text(r, p); p++ }
    name(N_TAG_LIST); textArray(r, p + 2, TagOrder.appSorts)
    name(N_CREATED_AT); timestamp(r.micros(p))
    name(N_UPDATED_AT); timestamp(r.micros(p + 1))
    name(N_FAVORITED); bool(if (flags == null) r.bool(p + 4) else flags.hasFlag(r.int8(p + 9)))
    name(N_FAVORITES_COUNT); number(r.int8(p + 3))
    name(N_AUTHOR); profile(r, p + 5, if (flags == null) r.bool(p + 8) else flags.hasFlag(-r.int8(p + 10)))
    endObject()
}

/** {"article": ...} for a full article at column [c]. */
internal fun JsonWriter.articleEnvelope(r: Row, c: Int, flags: Result? = null) {
    beginObject()
    name(N_ARTICLE); article(r, c, withBody = true, flags)
    endObject()
}

/** {"user": ...} from Strings (login/register: the row was copied across a bcrypt suspension or a token signed). */
internal fun JsonWriter.user(email: String?, token: String?, username: String?, bio: String?, image: String?) {
    beginObject()
    name(N_USER)
    beginObject()
    name(N_EMAIL); string(email)
    name(N_TOKEN); string(token)
    name(N_USERNAME); string(username)
    name(N_BIO); string(bio)
    name(N_IMAGE); string(image)
    endObject()
    endObject()
}

/** {"user": ...} from columns email, username, bio, image at [c]. */
internal fun JsonWriter.user(r: Row, c: Int, token: String?) {
    beginObject()
    name(N_USER)
    beginObject()
    name(N_EMAIL); text(r, c)
    name(N_TOKEN); string(token)
    name(N_USERNAME); text(r, c + 1)
    name(N_BIO); text(r, c + 2)
    name(N_IMAGE); text(r, c + 3)
    endObject()
    endObject()
}
