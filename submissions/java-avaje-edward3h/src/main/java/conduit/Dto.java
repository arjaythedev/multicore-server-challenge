package conduit;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;

import io.avaje.jsonb.Json;
import org.jspecify.annotations.Nullable;

/** Response shapes from SPEC.md. */
final class Dto {

    private Dto() {
    }

    /** RFC 3339 UTC with exactly 3 fractional digits (the formatter truncates, it doesn't round). */
    private static final DateTimeFormatter TIMESTAMP =
            DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);

    static String timestamp(OffsetDateTime instant) {
        return TIMESTAMP.format(instant);
    }

    @Json
    record User(String email, String token, String username, @Nullable String bio, @Nullable String image) {
    }

    @Json
    record UserResponse(User user) {
    }

    @Json
    record Profile(String username, @Nullable String bio, @Nullable String image, boolean following) {
    }

    @Json
    record ProfileResponse(Profile profile) {
    }

    /** List endpoints omit "body". */
    @Json
    record ArticleSummary(String slug, String title, String description, List<String> tagList, String createdAt,
            String updatedAt, boolean favorited, long favoritesCount, Profile author) {
    }

    @Json
    record Article(String slug, String title, String description, String body, List<String> tagList,
            String createdAt, String updatedAt, boolean favorited, long favoritesCount, Profile author) {
    }

    @Json
    record ArticleResponse(Article article) {
    }

    @Json
    record ArticleList(List<ArticleSummary> articles, long articlesCount) {
    }

    @Json
    record Comment(long id, String createdAt, String updatedAt, String body, Profile author) {
    }

    @Json
    record CommentResponse(Comment comment) {
    }

    @Json
    record CommentList(List<Comment> comments) {
    }

    @Json
    record TagList(List<String> tags) {
    }

    @Json
    record Errors(Map<String, List<String>> errors) {
        static Errors of(String message) {
            return new Errors(Map.of("body", List.of(message)));
        }
    }
}
