package conduit.domain.article

import conduit.domain.profile.Profile
import conduit.domain.shared.ForbiddenException
import conduit.domain.shared.ValidationException
import conduit.domain.shared.requireNotEmpty
import conduit.domain.shared.requireNotEmptyIfGiven
import java.time.Instant

/** [body] is null in lists. [favorited] is whether the viewer favorited it. */
class Article(
    val slug: String,
    val title: String,
    val description: String,
    val body: String?,
    val tagList: List<String>,
    val createdAt: Instant,
    val updatedAt: Instant,
    val favorited: Boolean,
    val favoritesCount: Long,
    val author: Profile,
)

/** One page of articles and the total (capped at 1,000). */
class ArticleList(val articles: List<Article>, val totalCount: Long)

/** Who wrote an article: only the author may change or delete it. */
class ArticleOwnership(val articleId: Long, val authorId: Long) {
    /** Forbidden unless [userId] is the author. */
    fun assertAuthor(userId: Long) {
        if (authorId != userId) throw ForbiddenException()
    }
}

/** Which articles a list shows. At most one filter applies: a tag, else an author, else who favorited them. */
sealed interface ArticleFilter {
    data object All : ArticleFilter

    class Tag(val name: String) : ArticleFilter

    class Author(val username: String) : ArticleFilter

    class FavoritedBy(val username: String) : ArticleFilter

    companion object {
        fun of(tag: String?, author: String?, favoritedBy: String?): ArticleFilter {
            return when {
                tag != null -> Tag(tag)
                author != null -> Author(author)
                favoritedBy != null -> FavoritedBy(favoritedBy)
                else -> All
            }
        }
    }
}

class NewArticle private constructor(val title: String, val description: String, val body: String, val tags: List<String>) {
    companion object {
        fun of(title: String?, description: String?, body: String?, tags: List<String>?): NewArticle {
            val tagList = tags.orEmpty()
            for (tag in tagList) {
                if (tag.isEmpty()) throw ValidationException("tagList must contain non-empty strings")
            }
            return NewArticle(title.requireNotEmpty("title"), description.requireNotEmpty("description"), body.requireNotEmpty("body"), tagList)
        }
    }
}

/** null fields stay unchanged; a new title also changes the slug. */
class ArticleChanges private constructor(val title: String?, val description: String?, val body: String?) {
    companion object {
        fun of(title: String?, description: String?, body: String?): ArticleChanges {
            return ArticleChanges(title.requireNotEmptyIfGiven("title"), description.requireNotEmptyIfGiven("description"), body.requireNotEmptyIfGiven("body"))
        }
    }
}
