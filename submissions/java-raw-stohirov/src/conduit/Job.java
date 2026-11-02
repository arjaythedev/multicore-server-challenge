package conduit;

/** One request waiting for Postgres or bcrypt. Fields are used per kind, as noted. */
final class Job {
    // reads
    static final int TAGS = 0, USER = 1, LOGIN = 2, PROFILE = 3, ARTICLE = 4, ARTICLE_ID = 5, COMMENTS = 6,
            GLOBAL = 7, TAG = 8, AUTHOR = 9, FAVORITED = 10, FEED = 11;
    // writes
    static final int REGISTER = 20, UPDATE_USER = 21, FOLLOW = 22, UNFOLLOW = 23, FAV = 24, UNFAV = 25,
            CREATE_ARTICLE = 26, UPDATE_ARTICLE = 27, DELETE_ARTICLE = 28, CREATE_COMMENT = 29, DELETE_COMMENT = 30;
    // bcrypt
    static final int HASH = 40, VERIFY = 41;

    int kind;
    final Http.Conn conn;
    long viewer;
    long t0;
    /** answered (or handed to bcrypt) before the rest of its batch finished */
    boolean done;

    /** slug, username, tag or e-mail (reads); slug or username (writes) */
    String key;
    long lim, off;
    /** article id (ARTICLE_ID), comment id (DELETE_COMMENT), user id (VERIFY) */
    long id;
    /** status of an ARTICLE_ID answer: 200, or 201 after a create */
    int status = 200;
    /** the presented token (USER, UPDATE_USER) */
    String token;
    /** a plain password (LOGIN, VERIFY, HASH) */
    byte[] password;
    /** stored hash (VERIFY), or the new hash (REGISTER, UPDATE_USER) */
    String hash;
    /** REGISTER: username, email. UPDATE_USER: email, username, bio, image. articles: title, description, body. comments: body */
    String f1, f2, f3, f4;
    String[] tags;
    /** VERIFY: the user's row, to answer with */
    byte[] uname, email, bio, image;
    /** HASH: the write to queue once hashed */
    Job then;

    Job(int kind, Http.Conn conn, long viewer) {
        this.kind = kind;
        this.conn = conn;
        this.viewer = viewer;
    }
}
