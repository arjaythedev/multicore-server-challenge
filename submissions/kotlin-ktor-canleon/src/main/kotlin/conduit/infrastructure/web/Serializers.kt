package conduit.infrastructure.web

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.nullable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.encoding.encodeStructure
import conduit.domain.article.Article
import conduit.domain.article.ArticleList
import conduit.domain.comment.Comment
import conduit.domain.profile.Profile
import conduit.domain.user.AuthenticatedUser
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeFormatterBuilder

// The wire format (SPEC.md "Objects"), written straight from the domain objects: no DTO copies per response, and no
// serialization annotations in the domain. Encode-only: requests are decoded into the request bodies in Messages.kt.

/** RFC 3339 UTC with exactly 3 fractional digits (truncated, not rounded), e.g. 2025-04-01T12:00:00.000Z. ISO instant printer: no zone conversion per value. */
private val TIMESTAMP: DateTimeFormatter = DateTimeFormatterBuilder().appendInstant(3).toFormatter()

private val NULLABLE_STRING = String.serializer().nullable
private val STRING_LIST = ListSerializer(String.serializer())

/** Base for the response serializers: they only ever encode. */
abstract class EncodeOnlySerializer<T> : KSerializer<T> {
    override fun deserialize(decoder: Decoder): T {
        throw SerializationException("${descriptor.serialName} is only written, never read")
    }
}

object ProfileSerializer : EncodeOnlySerializer<Profile>() {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Profile") {
        element("username", String.serializer().descriptor)
        element("bio", NULLABLE_STRING.descriptor)
        element("image", NULLABLE_STRING.descriptor)
        element("following", Boolean.serializer().descriptor)
    }

    override fun serialize(encoder: Encoder, value: Profile) {
        encoder.encodeStructure(descriptor) {
            encodeStringElement(descriptor, 0, value.username)
            encodeSerializableElement(descriptor, 1, NULLABLE_STRING, value.bio)
            encodeSerializableElement(descriptor, 2, NULLABLE_STRING, value.image)
            encodeBooleanElement(descriptor, 3, value.following)
        }
    }
}

/** body is only written when the article has one (list endpoints leave it out). */
object ArticleSerializer : EncodeOnlySerializer<Article>() {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Article") {
        element("slug", String.serializer().descriptor)
        element("title", String.serializer().descriptor)
        element("description", String.serializer().descriptor)
        element("body", String.serializer().descriptor, isOptional = true)
        element("tagList", STRING_LIST.descriptor)
        element("createdAt", String.serializer().descriptor)
        element("updatedAt", String.serializer().descriptor)
        element("favorited", Boolean.serializer().descriptor)
        element("favoritesCount", Long.serializer().descriptor)
        element("author", ProfileSerializer.descriptor)
    }

    override fun serialize(encoder: Encoder, value: Article) {
        encoder.encodeStructure(descriptor) {
            encodeStringElement(descriptor, 0, value.slug)
            encodeStringElement(descriptor, 1, value.title)
            encodeStringElement(descriptor, 2, value.description)
            val body = value.body
            if (body != null) {
                encodeStringElement(descriptor, 3, body)
            }
            encodeSerializableElement(descriptor, 4, STRING_LIST, value.tagList)
            encodeStringElement(descriptor, 5, value.createdAt.toWire())
            encodeStringElement(descriptor, 6, value.updatedAt.toWire())
            encodeBooleanElement(descriptor, 7, value.favorited)
            encodeLongElement(descriptor, 8, value.favoritesCount)
            encodeSerializableElement(descriptor, 9, ProfileSerializer, value.author)
        }
    }
}

object ArticleListSerializer : EncodeOnlySerializer<ArticleList>() {
    private val articleListSerializer = ListSerializer(ArticleSerializer)

    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("ArticleList") {
        element("articles", articleListSerializer.descriptor)
        element("articlesCount", Long.serializer().descriptor)
    }

    override fun serialize(encoder: Encoder, value: ArticleList) {
        encoder.encodeStructure(descriptor) {
            encodeSerializableElement(descriptor, 0, articleListSerializer, value.articles)
            encodeLongElement(descriptor, 1, value.totalCount)
        }
    }
}

object CommentSerializer : EncodeOnlySerializer<Comment>() {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Comment") {
        element("id", Long.serializer().descriptor)
        element("createdAt", String.serializer().descriptor)
        element("updatedAt", String.serializer().descriptor)
        element("body", String.serializer().descriptor)
        element("author", ProfileSerializer.descriptor)
    }

    override fun serialize(encoder: Encoder, value: Comment) {
        encoder.encodeStructure(descriptor) {
            encodeLongElement(descriptor, 0, value.id)
            encodeStringElement(descriptor, 1, value.createdAt.toWire())
            encodeStringElement(descriptor, 2, value.updatedAt.toWire())
            encodeStringElement(descriptor, 3, value.body)
            encodeSerializableElement(descriptor, 4, ProfileSerializer, value.author)
        }
    }
}

/** SPEC's User object: the account plus the token. */
object UserSerializer : EncodeOnlySerializer<AuthenticatedUser>() {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("User") {
        element("email", String.serializer().descriptor)
        element("token", String.serializer().descriptor)
        element("username", String.serializer().descriptor)
        element("bio", NULLABLE_STRING.descriptor)
        element("image", NULLABLE_STRING.descriptor)
    }

    override fun serialize(encoder: Encoder, value: AuthenticatedUser) {
        val account = value.account
        encoder.encodeStructure(descriptor) {
            encodeStringElement(descriptor, 0, account.email)
            encodeStringElement(descriptor, 1, value.token)
            encodeStringElement(descriptor, 2, account.username)
            encodeSerializableElement(descriptor, 3, NULLABLE_STRING, account.bio)
            encodeSerializableElement(descriptor, 4, NULLABLE_STRING, account.image)
        }
    }
}

private fun Instant.toWire(): String {
    return TIMESTAMP.format(this)
}
