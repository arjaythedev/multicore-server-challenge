package conduit;

import java.util.List;

import io.avaje.jsonb.Json;
import org.jspecify.annotations.Nullable;

/**
 * Request body shapes from SPEC.md. Jsonb rejects a value of the wrong JSON type (a number where a string is
 * expected), and reads a missing or null field as null; {@link Body} turns both into a 422.
 */
final class Requests {

    private Requests() {
    }

    @Json
    record Register(@Nullable Registration user) {
        @Json
        record Registration(@Nullable String username, @Nullable String email, @Nullable String password) {
        }
    }

    @Json
    record Login(@Nullable Credentials user) {
        @Json
        record Credentials(@Nullable String email, @Nullable String password) {
        }
    }

    @Json
    record UpdateUser(@Nullable Changes user) {
        @Json
        record Changes(@Nullable String email, @Nullable String username, @Nullable String password, @Nullable String bio,
                @Nullable String image) {
        }
    }

    @Json
    record CreateArticle(@Nullable NewArticle article) {
        @Json
        record NewArticle(@Nullable String title, @Nullable String description, @Nullable String body,
                @Nullable List<@Nullable String> tagList) {
        }
    }

    @Json
    record UpdateArticle(@Nullable Changes article) {
        @Json
        record Changes(@Nullable String title, @Nullable String description, @Nullable String body) {
        }
    }

    @Json
    record CreateComment(@Nullable NewComment comment) {
        @Json
        record NewComment(@Nullable String body) {
        }
    }
}
