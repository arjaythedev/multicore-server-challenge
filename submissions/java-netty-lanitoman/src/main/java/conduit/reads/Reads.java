package conduit.reads;

import java.util.List;

/** Every batched read. {@link #define} must run before the Postgres connections open (they prepare the SQL). */
public final class Reads {
    public static BatchedRead<?> tags;
    public static BatchedRead<?> article;
    public static BatchedRead<?> comments;
    public static BatchedRead<?> profile;
    public static BatchedRead<?> user;
    public static BatchedRead<?> globalList;
    public static BatchedRead<?> tagList;
    public static BatchedRead<?> authorList;
    public static BatchedRead<?> favoritedList;
    public static BatchedRead<?> feed;

    private Reads() {
    }

    public static List<BatchedRead<?>> define(int maxBatch) {
        tags = new TagsRead(maxBatch);
        article = new ArticleRead(maxBatch);
        comments = new CommentsRead(maxBatch);
        profile = new ProfileRead(maxBatch);
        user = new UserRead(maxBatch);
        globalList = ArticleListRead.global(maxBatch);
        tagList = ArticleListRead.byTag(maxBatch);
        authorList = ArticleListRead.byAuthor(maxBatch);
        favoritedList = ArticleListRead.favoritedBy(maxBatch);
        feed = ArticleListRead.feed(maxBatch);
        return List.of(tags, article, comments, profile, user, globalList, tagList, authorList, favoritedList, feed);
    }
}
