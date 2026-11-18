package conduit;

import io.avaje.jsonb.Json;
import io.avaje.validation.constraints.NotEmpty;
import io.avaje.validation.constraints.NotNull;
import io.avaje.validation.constraints.Valid;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * Request body shapes from SPEC.md. Jsonb rejects a value of the wrong JSON type (a number where a string is
 * expected) and reads a missing or null field as null. Validation runs before the controller method: a constraint
 * without {@code @Nullable} makes the field required, and one with it applies only when the field is present.
 * A violation is a 422 (see {@code Main}).
 */
final class Requests {

    private Requests() {}

    @Json
    @Valid
    record Register(@NotNull @Valid Registration user) {
        @Json
        @Valid
        record Registration(
                @NotEmpty String username,
                @NotEmpty String email,
                @NotEmpty String password) {}
    }

    @Json
    @Valid
    record Login(@NotNull @Valid Credentials user) {
        @Json
        @Valid
        record Credentials(@NotEmpty String email, @NotEmpty String password) {}
    }

    @Json
    @Valid
    record UpdateUser(@NotNull @Valid Changes user) {
        @Json
        @Valid
        record Changes(
                @Nullable @NotEmpty String email,
                @Nullable @NotEmpty String username,
                @Nullable @NotEmpty String password,
                @Nullable String bio,
                @Nullable String image) {}
    }

    @Json
    @Valid
    record CreateArticle(@NotNull @Valid NewArticle article) {
        @Json
        @Valid
        record NewArticle(
                @NotEmpty String title,
                @NotEmpty String description,
                @NotEmpty String body,
                @Nullable List<@NotEmpty String> tagList) {}
    }

    @Json
    @Valid
    record UpdateArticle(@NotNull @Valid Changes article) {
        @Json
        @Valid
        record Changes(
                @Nullable @NotEmpty String title,
                @Nullable @NotEmpty String description,
                @Nullable @NotEmpty String body) {}
    }

    @Json
    @Valid
    record CreateComment(@NotNull @Valid NewComment comment) {
        @Json
        @Valid
        record NewComment(@NotEmpty String body) {}
    }
}
