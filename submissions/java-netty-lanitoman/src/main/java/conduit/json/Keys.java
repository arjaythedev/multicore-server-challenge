package conduit.json;

import java.nio.charset.StandardCharsets;

/** JSON member names, encoded once as {@code "name":}. */
public final class Keys {
    private Keys() {
    }

    public static final byte[] ARTICLE = key("article");
    public static final byte[] ARTICLES = key("articles");
    public static final byte[] ARTICLES_COUNT = key("articlesCount");
    public static final byte[] AUTHOR = key("author");
    public static final byte[] BIO = key("bio");
    public static final byte[] BODY = key("body");
    public static final byte[] COMMENT = key("comment");
    public static final byte[] COMMENTS = key("comments");
    public static final byte[] CREATED_AT = key("createdAt");
    public static final byte[] DESCRIPTION = key("description");
    public static final byte[] EMAIL = key("email");
    public static final byte[] ERRORS = key("errors");
    public static final byte[] FAVORITED = key("favorited");
    public static final byte[] FAVORITES_COUNT = key("favoritesCount");
    public static final byte[] FOLLOWING = key("following");
    public static final byte[] ID = key("id");
    public static final byte[] IMAGE = key("image");
    public static final byte[] PROFILE = key("profile");
    public static final byte[] SLUG = key("slug");
    public static final byte[] TAG_LIST = key("tagList");
    public static final byte[] TAGS = key("tags");
    public static final byte[] TITLE = key("title");
    public static final byte[] TOKEN = key("token");
    public static final byte[] UPDATED_AT = key("updatedAt");
    public static final byte[] USER = key("user");
    public static final byte[] USERNAME = key("username");

    private static byte[] key(String name) {
        return ("\"" + name + "\":").getBytes(StandardCharsets.US_ASCII);
    }
}
