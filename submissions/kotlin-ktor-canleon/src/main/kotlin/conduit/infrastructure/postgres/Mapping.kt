package conduit.infrastructure.postgres

import conduit.domain.article.Article
import conduit.domain.comment.Comment
import conduit.domain.profile.Profile
import conduit.domain.user.UserAccount
import io.vertx.sqlclient.Row
import java.time.Instant

// Result rows -> domain objects. Column names are the ones in Queries.kt.

internal fun Row.instant(column: String): Instant {
    return getOffsetDateTime(column).toInstant()
}

/** A text[] column as a list, without copying the array the client returns. */
internal fun Row.textList(column: String): List<String> {
    return getArrayOfStrings(column).asList()
}

internal fun Row.toAccount(): UserAccount {
    return UserAccount(getLong("id"), getString("username"), getString("email"), getString("bio"), getString("image"))
}

/** The author columns of any row. */
internal fun Row.toProfile(): Profile {
    return Profile(getString("username"), getString("bio"), getString("image"), getBoolean("following"))
}

internal fun Row.toArticle(withBody: Boolean): Article {
    return Article(
        slug = getString("slug"),
        title = getString("title"),
        description = getString("description"),
        body = if (withBody) getString("body") else null,
        tagList = textList("tag_list"),
        createdAt = instant("created_at"),
        updatedAt = instant("updated_at"),
        favorited = getBoolean("favorited"),
        favoritesCount = getLong("favorites_count"),
        author = toProfile(),
    )
}

internal fun Row.toComment(): Comment {
    return Comment(
        id = getLong("id"),
        createdAt = instant("created_at"),
        updatedAt = instant("updated_at"),
        body = getString("body"),
        author = toProfile(),
    )
}
