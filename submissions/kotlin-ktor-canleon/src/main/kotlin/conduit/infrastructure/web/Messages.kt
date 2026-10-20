package conduit.infrastructure.web

import kotlinx.serialization.Serializable
import conduit.domain.article.Article
import conduit.domain.comment.Comment
import conduit.domain.profile.Profile
import conduit.domain.user.AuthenticatedUser

// ---- responses: the {"key": ...} envelopes; the objects inside are written by Serializers.kt ----

@Serializable
class UserResponse(@Serializable(with = UserSerializer::class) val user: AuthenticatedUser)

@Serializable
class ProfileResponse(@Serializable(with = ProfileSerializer::class) val profile: Profile)

@Serializable
class ArticleResponse(@Serializable(with = ArticleSerializer::class) val article: Article)

@Serializable
class CommentResponse(@Serializable(with = CommentSerializer::class) val comment: Comment)

@Serializable
class CommentsResponse(val comments: List<@Serializable(with = CommentSerializer::class) Comment>)

@Serializable
class TagsResponse(val tags: List<String>)

@Serializable
class ErrorBody(val body: List<String>)

@Serializable
class ErrorResponse(val errors: ErrorBody)

// ---- requests: every field optional here, the domain's value objects validate ----

@Serializable
class RegisterRequest(val user: RegistrationBody)

@Serializable
class RegistrationBody(val username: String? = null, val email: String? = null, val password: String? = null)

@Serializable
class LoginRequest(val user: LoginBody)

@Serializable
class LoginBody(val email: String? = null, val password: String? = null)

@Serializable
class UpdateUserRequest(val user: UserChangesBody)

@Serializable
class UserChangesBody(
    val email: String? = null,
    val username: String? = null,
    val password: String? = null,
    val bio: String? = null,
    val image: String? = null,
)

@Serializable
class NewArticleRequest(val article: NewArticleBody)

@Serializable
class NewArticleBody(
    val title: String? = null,
    val description: String? = null,
    val body: String? = null,
    val tagList: List<String>? = null,
)

@Serializable
class UpdateArticleRequest(val article: ArticleChangesBody)

@Serializable
class ArticleChangesBody(val title: String? = null, val description: String? = null, val body: String? = null)

@Serializable
class NewCommentRequest(val comment: NewCommentBody)

@Serializable
class NewCommentBody(val body: String? = null)
