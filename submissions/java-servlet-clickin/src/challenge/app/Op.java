package challenge.app;

import challenge.pg.Stmt;

/**
 * One API operation. Properties are constructor fields, not switches: a field
 * load per request instead of a jump table, and a new operation fails
 * compilation until every property is given.
 */
enum Op {
    // (statement, auth, writes, targeted)
    TAGS(Stmt.TAGS, Auth.NONE, false, false),
    REGISTER(Stmt.REGISTER, Auth.NONE, true, false),
    LOGIN(Stmt.LOGIN, Auth.NONE, false, false),
    USER(Stmt.USER, Auth.REQUIRED, false, false),
    UPDATE(Stmt.UPDATE_USER, Auth.REQUIRED, true, false),
    PROFILE(Stmt.PROFILE, Auth.OPTIONAL, false, true),
    FOLLOW(Stmt.FOLLOW, Auth.REQUIRED, true, true),
    UNFOLLOW(Stmt.UNFOLLOW, Auth.REQUIRED, true, true),
    ARTICLES(Stmt.ARTICLES, Auth.OPTIONAL, false, false),
    ARTICLES_TAG(Stmt.ARTICLES_TAG, Auth.OPTIONAL, false, false),
    ARTICLES_AUTHOR(Stmt.ARTICLES_AUTHOR, Auth.OPTIONAL, false, false),
    ARTICLES_FAVORITED(Stmt.ARTICLES_FAVORITED, Auth.OPTIONAL, false, false),
    FEED(Stmt.FEED, Auth.REQUIRED, false, false),
    ARTICLE(Stmt.ARTICLE, Auth.OPTIONAL, false, true),
    COMMENTS(Stmt.COMMENTS, Auth.OPTIONAL, false, true),
    CREATE_ARTICLE(Stmt.CREATE_ARTICLE, Auth.REQUIRED, true, false),
    UPDATE_ARTICLE(Stmt.UPDATE_ARTICLE, Auth.REQUIRED, true, true),
    DELETE_ARTICLE(Stmt.DELETE_ARTICLE, Auth.REQUIRED, true, true),
    FAVORITE(Stmt.FAVORITE, Auth.REQUIRED, true, true),
    UNFAVORITE(Stmt.UNFAVORITE, Auth.REQUIRED, true, true),
    CREATE_COMMENT(Stmt.CREATE_COMMENT, Auth.REQUIRED, true, true),
    DELETE_COMMENT(Stmt.DELETE_COMMENT, Auth.REQUIRED, true, true);

    enum Auth {
        NONE,
        OPTIONAL,
        REQUIRED
    }

    final int stmt;
    final Auth auth;
    final boolean writes;

    /** The third path segment names the profile or article. */
    final boolean targeted;

    Op(int stmt, Auth auth, boolean writes,
       boolean targeted) {
        this.stmt = stmt;
        this.auth = auth;
        this.writes = writes;
        this.targeted = targeted;
    }
}
