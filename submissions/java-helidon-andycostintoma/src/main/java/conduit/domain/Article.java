package conduit.domain;

import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;
import java.util.List;
import java.util.Locale;
import java.util.function.LongSupplier;

public final class Article {
    private final long id;
    private final long authorId;
    private final String slug;
    private final String title;
    private final String description;
    private final String body;

    public long id() {
        return id;
    }

    public long authorId() {
        return authorId;
    }

    public String slug() {
        return slug;
    }

    public String title() {
        return title;
    }

    public String description() {
        return description;
    }

    public String body() {
        return body;
    }

    public record Props(
        long id,
        long authorId,
        String slug,
        String title,
        String description,
        String body
    ) {
    }

    public record Input(
        long authorId,
        String title,
        String description,
        String body
    ) {
    }

    public record UpdateInput(
        String title,
        String description,
        String body
    ) {
    }

    public static Article create(Input input, LongSupplier nextId) {
        if (missing(input.title()) || missing(input.description()) || missing(input.body())) {
            throw new InvalidInput("A non-empty string is required");
        }
        var id = nextId.getAsLong();
        return new Article(new Props(id, input.authorId(), slug(input.title(), id), input.title(),
            input.description(), input.body()));
    }

    public static Article reconstitute(Props props) {
        return new Article(props);
    }

    public static List<String> tags(List<String> tags) {
        if (tags == null) {
            return List.of();
        }
        for (var tag : tags) {
            if (missing(tag)) {
                throw new InvalidInput("A non-empty string is required");
            }
        }
        return tags.stream().distinct().toList();
    }

    public Article update(long viewer, UpdateInput input) {
        authorize(viewer);
        if ("".equals(input.title()) || "".equals(input.description()) || "".equals(input.body())) {
            throw new InvalidInput("A non-empty string is required");
        }
        return new Article(
            new Props(id, authorId, input.title() == null ? slug : slug(input.title(), id),
                input.title() == null ? title : input.title(),
                input.description() == null ? description : input.description(),
                input.body() == null ? body : input.body()));
    }

    public void authorize(long viewer) {
        if (viewer != authorId) {
            throw new Forbidden("Only the author may change this article");
        }
    }

    private static boolean missing(String value) {
        return value == null || value.isEmpty();
    }

    private static String slug(String title, long id) {
        return title.replaceAll("[^A-Za-z0-9]+", "-").toLowerCase(Locale.ROOT).replaceAll("^-+|-+$",
            "") + "-" + id;
    }

    private Article(Props props) {
        this.id = props.id();
        this.authorId = props.authorId();
        this.slug = props.slug();
        this.title = props.title();
        this.description = props.description();
        this.body = props.body();
    }
}
