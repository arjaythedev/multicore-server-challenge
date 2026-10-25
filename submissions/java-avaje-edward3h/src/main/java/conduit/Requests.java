package conduit;

import java.util.List;

import io.avaje.jsonb.Json;

/**
 * Request body shapes from SPEC.md. Jsonb rejects a value of the wrong JSON type (a number where a string is
 * expected), and reads a missing or null field as null; {@link Body} turns both into a 422.
 */
final class Requests {

    private Requests() {
    }

    @Json
    record Register(Registration user) {
        @Json
        record Registration(String username, String email, String password) {
        }
    }

    @Json
    record Login(Credentials user) {
        @Json
        record Credentials(String email, String password) {
        }
    }

    @Json
    record UpdateUser(Changes user) {
        @Json
        record Changes(String email, String username, String password, String bio, String image) {
        }
    }

    @Json
    record CreateArticle(NewArticle article) {
        @Json
        record NewArticle(String title, String description, String body, List<String> tagList) {
        }
    }

    @Json
    record UpdateArticle(Changes article) {
        @Json
        record Changes(String title, String description, String body) {
        }
    }

    @Json
    record CreateComment(NewComment comment) {
        @Json
        record NewComment(String body) {
        }
    }
}
