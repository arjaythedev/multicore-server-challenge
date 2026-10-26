package conduit.json;

import conduit.ArticleSql;
import conduit.db.Row;

/**
 * The API's objects, written from result rows. Articles and comments are written in two parts: the part that is the
 * same for every viewer, ending with the author's {@code "following":} name ({@link #articleOpen},
 * {@link #commentOpen}), and the viewer's flags ({@link #articleClose}, {@link #commentClose}). A batch renders the
 * first part once per article and copies it into every response that shows the article.
 */
public final class Render {
    private Render() {
    }

    /** Columns of an article from its id to its author's image (see {@link conduit.ArticleSql}). */
    public static int articleColumns(boolean withBody) {
        return withBody ? 13 : 12;
    }

    /**
     * An Article up to its author's "following", from the columns starting at {@code first}: id, slug, title,
     * description, [body], created_at, updated_at, tag_list, favorites_count, author_id, username, bio, image.
     */
    public static void articleOpen(JsonWriter json, Row row, int first, boolean withBody) {
        int column = first + 1;                              // the id isn't part of the response
        json.beginObject();
        json.key(Keys.SLUG).column(row, column++);
        json.key(Keys.TITLE).column(row, column++);
        json.key(Keys.DESCRIPTION).column(row, column++);
        if (withBody) json.key(Keys.BODY).column(row, column++);
        json.key(Keys.CREATED_AT).timestamp(row, column++);
        json.key(Keys.UPDATED_AT).timestamp(row, column++);
        json.key(Keys.TAG_LIST);
        if (ArticleSql.serverSortsTags) json.sortedTextArray(row, column++);
        else json.textArray(row, column++);
        json.key(Keys.FAVORITES_COUNT).value(row.getLong(column++));
        column++;                                            // author_id
        json.key(Keys.AUTHOR).beginObject()
                .key(Keys.USERNAME).column(row, column)
                .key(Keys.BIO).column(row, column + 1)
                .key(Keys.IMAGE).column(row, column + 2)
                .key(Keys.FOLLOWING);
    }

    /** Completes an article written by {@link #articleOpen} with the viewer's flags. */
    public static void articleClose(JsonWriter json, boolean following, boolean favorited) {
        json.value(following).endObject().key(Keys.FAVORITED).value(favorited).endObject();
    }

    /** {"article": Article} from a row with the article columns at {@code first}, then favorited and following. */
    public static void articleResponse(JsonWriter json, Row row, int first) {
        int flags = first + articleColumns(true);
        json.beginObject().key(Keys.ARTICLE);
        articleOpen(json, row, first, true);
        articleClose(json, row.getBoolean(flags + 1), row.getBoolean(flags));
        json.endObject();
    }

    /** A Profile from (username, bio, image) at {@code first}, with the given following flag. */
    public static void profile(JsonWriter json, Row row, int first, boolean following) {
        json.beginObject()
                .key(Keys.USERNAME).column(row, first)
                .key(Keys.BIO).column(row, first + 1)
                .key(Keys.IMAGE).column(row, first + 2)
                .key(Keys.FOLLOWING).value(following)
                .endObject();
    }

    /** {"profile": Profile} */
    public static void profileResponse(JsonWriter json, Row row, int first, boolean following) {
        json.beginObject().key(Keys.PROFILE);
        profile(json, row, first, following);
        json.endObject();
    }

    /** {"user": User} from (id, username, email, bio, image) at {@code first}. */
    public static void userResponse(JsonWriter json, Row row, int first, String token) {
        json.beginObject().key(Keys.USER).beginObject()
                .key(Keys.EMAIL).column(row, first + 2)
                .key(Keys.TOKEN).value(token)
                .key(Keys.USERNAME).column(row, first + 1)
                .key(Keys.BIO).column(row, first + 3)
                .key(Keys.IMAGE).column(row, first + 4)
                .endObject().endObject();
    }

    /**
     * A Comment up to its author's "following", from (id, body, created_at, updated_at, username, bio, image) at
     * {@code first}.
     */
    public static void commentOpen(JsonWriter json, Row row, int first) {
        json.beginObject()
                .key(Keys.ID).value(row.getLong(first))
                .key(Keys.CREATED_AT).timestamp(row, first + 2)
                .key(Keys.UPDATED_AT).timestamp(row, first + 3)
                .key(Keys.BODY).column(row, first + 1)
                .key(Keys.AUTHOR).beginObject()
                .key(Keys.USERNAME).column(row, first + 4)
                .key(Keys.BIO).column(row, first + 5)
                .key(Keys.IMAGE).column(row, first + 6)
                .key(Keys.FOLLOWING);
    }

    /** Completes a comment written by {@link #commentOpen}. */
    public static void commentClose(JsonWriter json, boolean following) {
        json.value(following).endObject().endObject();
    }
}
