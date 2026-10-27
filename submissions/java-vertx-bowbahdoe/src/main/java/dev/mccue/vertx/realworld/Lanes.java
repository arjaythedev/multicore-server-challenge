package dev.mccue.vertx.realworld;

import io.vertx.core.Context;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.Vertx;
import io.vertx.core.buffer.Buffer;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.pgclient.PgConnection;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.Tuple;
import org.jspecify.annotations.Nullable;

import java.lang.System.Logger.Level;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

/// Reads, answered in large batches.
///
/// Postgres pays a fixed cost per statement, and most of what concurrent requests read is the same (the newest
/// page, the tag list, a popular article's author and favorite count). So reads from every event loop go into one
/// queue, and read lanes (each a thread with its own connection) take turns collecting it: one lane gathers for up
/// to the window while the others run what they gathered. A batch is answered in two pipelined round trips:
///
/// 1. Phase A, one statement per kind of read present, over arrays of the batch's distinct keys: one page per
///    (limit, offset), one count per tag, one lookup per slug, ...
/// 2. Phase B, over the union of the articles phase A found: each article's tags, favorite count and author once,
///    and the favorited/following flags each viewer needs, one primary key scan per viewer.
///
/// Each response is then assembled from those rows. Only requests already waiting share a batch, every value in a
/// response was read while its request waited, and nothing outlives the batch.
final class Lanes {
    private static final System.Logger LOG = System.getLogger(Lanes.class.getName());

    /// A read, and the viewer (0 when anonymous) it's for.
    sealed interface Read {
        record Tags() implements Read {
        }

        record CurrentUser(long id, String token) implements Read {
        }

        /// The account for an email, for a login to check the password against. Answered with Credentials (or null).
        record Login(String email) implements Read {
        }

        record Profile(String username) implements Read {
        }

        record Article(String slug) implements Read {
        }

        record Comments(String slug) implements Read {
        }

        record Global(int limit, long offset) implements Read {
        }

        record ByTag(String tag, int limit, long offset) implements Read {
        }

        record ByAuthor(String username, int limit, long offset) implements Read {
        }

        record Favorited(String username, int limit, long offset) implements Read {
        }

        record Feed(int limit, long offset) implements Read {
        }
    }

    record Credentials(long id, String username, String email, @Nullable String bio, @Nullable String image,
                       String passwordHash) {
    }

    private record Job(Read read, long viewer, Context context, Promise<Object> promise) {
    }

    private final ReentrantLock lock = new ReentrantLock();
    private final Condition waiting = lock.newCondition();
    private final ArrayList<Job> queue = new ArrayList<>();
    /// Held by the lane that is gathering.
    private final ReentrantLock gather = new ReentrantLock();
    private final long windowNanos;
    private final int maxBatch;

    Lanes(Vertx vertx, PgConnectOptions options, int lanes, long windowMicros, int maxBatch) {
        this.windowNanos = TimeUnit.MICROSECONDS.toNanos(windowMicros);
        this.maxBatch = maxBatch;
        for (int i = 0; i < lanes; i++) {
            var lane = new Lane(vertx, options);
            Thread.ofPlatform().name("read-lane-" + i).daemon().start(lane::run);
        }
    }

    /// Answered with a Reply, except Login (Credentials, or null when there's no such account).
    @SuppressWarnings("unchecked")
    <T> Future<T> read(Read read, long viewer) {
        var promise = Promise.promise();
        var job = new Job(read, viewer, Vertx.currentContext(), promise);
        lock.lock();
        try {
            queue.add(job);
            if (queue.size() == 1) {
                waiting.signal();
            }
        }
        finally {
            lock.unlock();
        }
        return (Future<T>) promise.future();
    }

    /// Waits for a job, then up to the window (from that first job) for more; takes up to the batch cap.
    private List<Job> take() throws InterruptedException {
        lock.lock();
        try {
            while (queue.isEmpty()) {
                waiting.await();
            }
            long deadline = System.nanoTime() + windowNanos;
            long left;
            while (queue.size() < maxBatch && (left = deadline - System.nanoTime()) > 0) {
                waiting.awaitNanos(left);
            }
            int n = Math.min(queue.size(), maxBatch);
            var batch = new ArrayList<>(queue.subList(0, n));
            queue.subList(0, n).clear();
            return batch;
        }
        finally {
            lock.unlock();
        }
    }

    /// Distinct keys, each with its 1-based ordinal (the k the statements return).
    private static final class Keys<K> {
        final LinkedHashMap<K, Integer> map = new LinkedHashMap<>();

        int index(K key) {
            return map.computeIfAbsent(key, k -> map.size() + 1);
        }

        boolean isEmpty() {
            return map.isEmpty();
        }

        int size() {
            return map.size();
        }
    }

    private record Page(String key, int limit, long offset) {
    }

    private record FeedPage(long viewer, int limit, long offset) {
    }

    private record Pair(long a, long b) {
    }

    /// An article row from phase A.
    private record ArticleRow(long id, long authorId, String slug, String title, String description,
                              OffsetDateTime createdAt, OffsetDateTime updatedAt, @Nullable String body) {
        static ArticleRow of(Row row, boolean withBody) {
            return new ArticleRow(row.getLong(1), row.getLong(2), row.getString(3), row.getString(4),
                    row.getString(5), row.getOffsetDateTime(6), row.getOffsetDateTime(7),
                    withBody ? row.getString(8) : null);
        }
    }

    /// An article's phase B row.
    private record Extras(Integer[] tagIds, long favoritesCount, String username, @Nullable String bio,
                          @Nullable String image) {
    }

    /// A list kind's counts and pages, by key ordinal.
    private static final class ListResult {
        final long[] counts;
        final List<List<ArticleRow>> pages;

        ListResult(int counts, int pages) {
            this.counts = new long[counts + 1];
            this.pages = new ArrayList<>(pages + 1);
            for (int i = 0; i <= pages; i++) {
                this.pages.add(new ArrayList<>());
            }
        }

        void add(Row row) {
            long k = row.getLong(0);
            if (k <= 0) {
                counts[(int) -k] = row.getLong(1);
            }
            else {
                pages.get((int) k).add(ArticleRow.of(row, false));
            }
        }
    }

    private final class Lane {
        private final Vertx vertx;
        private final PgConnectOptions options;
        private @Nullable PgConnection connection;

        Lane(Vertx vertx, PgConnectOptions options) {
            this.vertx = vertx;
            this.options = options;
        }

        void run() {
            while (true) {
                List<Job> jobs;
                try {
                    gather.lock();
                    try {
                        jobs = take();
                    }
                    finally {
                        gather.unlock();
                    }
                }
                catch (InterruptedException e) {
                    return;
                }
                try {
                    batch(jobs);
                }
                catch (RuntimeException e) {
                    LOG.log(Level.ERROR, "Read batch failed", e);
                    if (connection != null) {
                        connection.close();
                        connection = null;
                    }
                    for (var job : jobs) {
                        job.context().runOnContext(v -> job.promise().tryFail(e));
                    }
                }
            }
        }

        private PgConnection connection() {
            if (connection == null) {
                connection = PgConnection.connect(vertx, options).await();
            }
            return connection;
        }

        private Future<RowSet<Row>> query(String sql, Tuple parameters) {
            return connection().preparedQuery(sql).execute(parameters);
        }

        private void batch(List<Job> jobs) {
            // ---- distinct keys ----
            boolean tags = false;
            var userIds = new Keys<Long>();
            var emails = new Keys<String>();
            var profiles = new Keys<String>();
            var slugs = new Keys<String>();
            var commentSlugs = new Keys<String>();
            var globalPages = new Keys<Page>();
            var tagCounts = new Keys<String>();
            var tagPages = new Keys<Page>();
            var authorCounts = new Keys<String>();
            var authorPages = new Keys<Page>();
            var favoritedCounts = new Keys<String>();
            var favoritedPages = new Keys<Page>();
            var feedCounts = new Keys<Long>();
            var feedPages = new Keys<FeedPage>();

            // per job: the ordinal(s) it asked for
            var asks = new int[jobs.size()][];
            for (int i = 0; i < jobs.size(); i++) {
                var job = jobs.get(i);
                asks[i] = switch (job.read()) {
                    case Read.Tags t -> {
                        tags = true;
                        yield new int[0];
                    }
                    case Read.CurrentUser u -> new int[]{userIds.index(u.id())};
                    case Read.Login l -> new int[]{emails.index(l.email())};
                    case Read.Profile p -> new int[]{profiles.index(p.username())};
                    case Read.Article a -> new int[]{slugs.index(a.slug())};
                    case Read.Comments c -> new int[]{commentSlugs.index(c.slug())};
                    case Read.Global g -> new int[]{globalPages.index(new Page("", g.limit(), g.offset()))};
                    case Read.ByTag t -> new int[]{tagCounts.index(t.tag()), tagPages.index(new Page(t.tag(), t.limit(), t.offset()))};
                    case Read.ByAuthor a -> new int[]{authorCounts.index(a.username()), authorPages.index(new Page(a.username(), a.limit(), a.offset()))};
                    case Read.Favorited f -> new int[]{favoritedCounts.index(f.username()), favoritedPages.index(new Page(f.username(), f.limit(), f.offset()))};
                    case Read.Feed f -> new int[]{feedCounts.index(job.viewer()), feedPages.index(new FeedPage(job.viewer(), f.limit(), f.offset()))};
                };
            }

            // ---- phase A, pipelined ----
            var tagsResult = tags ? query(Sql.LANE_TAGS, Tuple.tuple()) : null;
            var usersResult = userIds.isEmpty() ? null : query(Sql.LANE_USERS_BY_ID, Tuple.of(longs(userIds.map.keySet())));
            var emailsResult = emails.isEmpty() ? null : query(Sql.LANE_USERS_BY_EMAIL, Tuple.of(strings(emails.map.keySet())));
            var profilesResult = profiles.isEmpty() ? null : query(Sql.LANE_PROFILES, Tuple.of(strings(profiles.map.keySet())));
            var articlesResult = slugs.isEmpty() ? null : query(Sql.LANE_ARTICLES, Tuple.of(strings(slugs.map.keySet())));
            var commentsResult = commentSlugs.isEmpty() ? null : query(Sql.LANE_COMMENTS, Tuple.of(strings(commentSlugs.map.keySet())));
            var globalResult = globalPages.isEmpty() ? null : query(Sql.LANE_GLOBAL, Tuple.tuple()
                    .addArrayOfInteger(globalPages.map.keySet().stream().map(Page::limit).toArray(Integer[]::new))
                    .addArrayOfLong(globalPages.map.keySet().stream().map(Page::offset).toArray(Long[]::new)));
            var tagResult = tagPages.isEmpty() ? null : query(Sql.LANE_BY_TAG, listParameters(tagCounts, tagPages));
            var authorResult = authorPages.isEmpty() ? null : query(Sql.LANE_BY_AUTHOR, listParameters(authorCounts, authorPages));
            var favoritedResult = favoritedPages.isEmpty() ? null : query(Sql.LANE_FAVORITED, listParameters(favoritedCounts, favoritedPages));
            var feedResult = feedPages.isEmpty() ? null : query(Sql.LANE_FEED, Tuple.tuple()
                    .addArrayOfLong(longs(feedCounts.map.keySet()))
                    .addArrayOfLong(feedPages.map.keySet().stream().map(FeedPage::viewer).toArray(Long[]::new))
                    .addArrayOfInteger(feedPages.map.keySet().stream().map(FeedPage::limit).toArray(Integer[]::new))
                    .addArrayOfLong(feedPages.map.keySet().stream().map(FeedPage::offset).toArray(Long[]::new)));

            // ---- decode phase A ----
            List<String> tagNames = tagsResult == null ? List.of() : List.of(firstRow(tagsResult.await()).getArrayOfStrings(0));
            var users = byOrdinal(usersResult, userIds.size());
            var credentials = byOrdinal(emailsResult, emails.size());
            var profileRows = byOrdinal(profilesResult, profiles.size());
            var articleRows = byOrdinal(articlesResult, slugs.size());
            var commentRows = new ArrayList<List<Row>>();
            for (int i = 0; i <= commentSlugs.size(); i++) {
                commentRows.add(new ArrayList<>());
            }
            if (commentsResult != null) {
                for (var row : commentsResult.await()) {
                    commentRows.get(row.getLong(0).intValue()).add(row);
                }
            }
            var global = lists(globalResult, 0, globalPages.size());
            var byTag = lists(tagResult, tagCounts.size(), tagPages.size());
            var byAuthor = lists(authorResult, authorCounts.size(), authorPages.size());
            var favorited = lists(favoritedResult, favoritedCounts.size(), favoritedPages.size());
            var feed = lists(feedResult, feedCounts.size(), feedPages.size());

            // ---- what phase B needs ----
            // every article (id -> author) and every (viewer, article) / (viewer, user) flag a response will show
            var articleAuthors = new LinkedHashMap<Long, Long>();
            var favoriteAsks = new LinkedHashSet<Pair>();
            var followAsks = new LinkedHashSet<Pair>();
            for (int i = 0; i < jobs.size(); i++) {
                var job = jobs.get(i);
                long viewer = job.viewer();
                switch (job.read()) {
                    case Read.Profile p -> {
                        var row = profileRows[asks[i][0]];
                        if (row != null && viewer != 0) {
                            followAsks.add(new Pair(viewer, row.getLong(1)));
                        }
                    }
                    case Read.Article a -> {
                        var row = articleRows[asks[i][0]];
                        if (row != null) {
                            ask(ArticleRow.of(row, true), viewer, articleAuthors, favoriteAsks, followAsks);
                        }
                    }
                    case Read.Comments c -> {
                        if (viewer != 0) {
                            for (var row : commentRows.get(asks[i][0])) {
                                var author = row.getLong(6);
                                if (author != null) {
                                    followAsks.add(new Pair(viewer, author));
                                }
                            }
                        }
                    }
                    case Read.Global g -> askAll(global.pages.get(asks[i][0]), viewer, articleAuthors, favoriteAsks, followAsks);
                    case Read.ByTag t -> askAll(byTag.pages.get(asks[i][1]), viewer, articleAuthors, favoriteAsks, followAsks);
                    case Read.ByAuthor a -> askAll(byAuthor.pages.get(asks[i][1]), viewer, articleAuthors, favoriteAsks, followAsks);
                    case Read.Favorited f -> askAll(favorited.pages.get(asks[i][1]), viewer, articleAuthors, favoriteAsks, followAsks);
                    case Read.Feed f -> {
                        // every author in a feed is followed: only favorited is asked
                        for (var article : feed.pages.get(asks[i][1])) {
                            articleAuthors.putIfAbsent(article.id(), article.authorId());
                            favoriteAsks.add(new Pair(viewer, article.id()));
                        }
                    }
                    default -> {
                    }
                }
            }

            // ---- phase B, pipelined ----
            Future<RowSet<Row>> extrasResult = null;
            Future<RowSet<Row>> tagNamesResult = null;
            Future<RowSet<Row>> flagsResult = null;
            if (!articleAuthors.isEmpty()) {
                var ids = articleAuthors.keySet().toArray(new Long[0]);
                extrasResult = query(Sql.LANE_ARTICLE_EXTRAS, Tuple.tuple()
                        .addArrayOfLong(ids)
                        .addArrayOfLong(articleAuthors.values().toArray(new Long[0])));
                tagNamesResult = query(Sql.LANE_TAG_NAMES, Tuple.tuple().addArrayOfLong(ids));
            }
            if (!favoriteAsks.isEmpty() || !followAsks.isEmpty()) {
                flagsResult = query(Sql.LANE_FLAGS, Tuple.tuple()
                        .addArrayOfLong(favoriteAsks.stream().map(Pair::a).toArray(Long[]::new))
                        .addArrayOfLong(favoriteAsks.stream().map(Pair::b).toArray(Long[]::new))
                        .addArrayOfLong(followAsks.stream().map(Pair::a).toArray(Long[]::new))
                        .addArrayOfLong(followAsks.stream().map(Pair::b).toArray(Long[]::new)));
            }

            var extras = new HashMap<Long, Extras>();
            if (extrasResult != null) {
                for (var row : extrasResult.await()) {
                    extras.put(row.getLong(0), new Extras(row.getArrayOfIntegers(1), row.getLong(2),
                            row.getString(3), row.getString(4), row.getString(5)));
                }
            }
            // each tag's name, and its rank in name order
            var tagRank = new HashMap<Integer, Integer>();
            var tagName = new HashMap<Integer, String>();
            if (tagNamesResult != null) {
                int rank = 0;
                for (var row : tagNamesResult.await()) {
                    tagRank.put(row.getInteger(0), rank++);
                    tagName.put(row.getInteger(0), row.getString(1));
                }
            }
            var favorites = new HashSet<Pair>();
            var follows = new HashSet<Pair>();
            if (flagsResult != null) {
                for (var row : flagsResult.await()) {
                    (row.getInteger(0) == 0 ? favorites : follows).add(new Pair(row.getLong(1), row.getLong(2)));
                }
            }
            var view = new View(extras, tagRank, tagName, favorites, follows);

            // ---- answer ----
            for (int i = 0; i < jobs.size(); i++) {
                var job = jobs.get(i);
                long viewer = job.viewer();
                Object answer = switch (job.read()) {
                    case Read.Tags t -> {
                        var out = new Out().open().key("tags").openArray();
                        for (var name : tagNames) {
                            out.string(name);
                        }
                        yield reply(200, out.closeArray().close());
                    }
                    case Read.CurrentUser u -> {
                        var row = users[asks[i][0]];
                        yield row == null
                                ? Api.unauthenticated()
                                : reply(200, user(row.getString(3), u.token(), row.getString(2), row.getString(4), row.getString(5)));
                    }
                    case Read.Login l -> {
                        var row = credentials[asks[i][0]];
                        yield row == null ? null : new Credentials(row.getLong(1), row.getString(2), row.getString(3),
                                row.getString(4), row.getString(5), row.getString(6));
                    }
                    case Read.Profile p -> {
                        var row = profileRows[asks[i][0]];
                        yield row == null ? Api.notFound() : reply(200, new Out().open().key("profile").open()
                                .key("username").string(row.getString(2))
                                .key("bio").string(row.getString(3))
                                .key("image").string(row.getString(4))
                                .key("following").bool(follows.contains(new Pair(viewer, row.getLong(1))))
                                .close().close());
                    }
                    case Read.Article a -> {
                        var row = articleRows[asks[i][0]];
                        if (row == null || !view.has(ArticleRow.of(row, true))) {
                            yield Api.notFound();
                        }
                        var out = new Out().open().key("article");
                        view.article(out, ArticleRow.of(row, true), viewer, false);
                        yield reply(200, out.close());
                    }
                    case Read.Comments c -> comments(commentRows.get(asks[i][0]), viewer, follows);
                    case Read.Global g -> view.list(global.counts[0], global.pages.get(asks[i][0]), viewer, false);
                    case Read.ByTag t -> view.list(byTag.counts[asks[i][0]], byTag.pages.get(asks[i][1]), viewer, false);
                    case Read.ByAuthor a -> view.list(byAuthor.counts[asks[i][0]], byAuthor.pages.get(asks[i][1]), viewer, false);
                    case Read.Favorited f -> view.list(favorited.counts[asks[i][0]], favorited.pages.get(asks[i][1]), viewer, false);
                    case Read.Feed f -> view.list(feed.counts[asks[i][0]], feed.pages.get(asks[i][1]), viewer, true);
                };
                job.context().runOnContext(v -> job.promise().complete(answer));
            }
        }
    }

    /// Phase B's answers.
    private record View(Map<Long, Extras> extras, Map<Integer, Integer> tagRank, Map<Integer, String> tagName,
                        Set<Pair> favorites, Set<Pair> follows) {
        /// Whether phase B saw the article. It runs in a later snapshot than phase A, so an article deleted in
        /// between is gone.
        boolean has(ArticleRow article) {
            return extras.containsKey(article.id());
        }

        /// An Article; `feed`: the author is followed (every feed author is).
        void article(Out out, ArticleRow article, long viewer, boolean feed) {
            var extra = extras.get(article.id());
            var tagIds = extra.tagIds().clone();
            Arrays.sort(tagIds, Comparator.comparingInt(tagId -> tagRank.getOrDefault(tagId, Integer.MAX_VALUE)));
            out.open()
                    .key("slug").string(article.slug())
                    .key("title").string(article.title())
                    .key("description").string(article.description());
            if (article.body() != null) {
                out.key("body").string(article.body());
            }
            out.key("tagList").openArray();
            for (var tagId : tagIds) {
                var name = tagName.get(tagId);
                if (name != null) {
                    out.string(name);
                }
            }
            out.closeArray()
                    .key("createdAt").timestamp(article.createdAt())
                    .key("updatedAt").timestamp(article.updatedAt())
                    .key("favorited").bool(favorites.contains(new Pair(viewer, article.id())))
                    .key("favoritesCount").number(extra.favoritesCount())
                    .key("author").open()
                        .key("username").string(extra.username())
                        .key("bio").string(extra.bio())
                        .key("image").string(extra.image())
                        .key("following").bool(feed || follows.contains(new Pair(viewer, article.authorId())))
                    .close()
                    .close();
        }

        /// {"articles": [...], "articlesCount": n}, newest first.
        Api.Reply list(long count, List<ArticleRow> page, long viewer, boolean feed) {
            var sorted = new ArrayList<>(page);
            sorted.sort(Comparator.comparingLong(ArticleRow::id).reversed());
            var out = new Out().open().key("articles").openArray();
            for (var article : sorted) {
                if (has(article)) {
                    article(out, article, viewer, feed);
                }
            }
            return reply(200, out.closeArray().key("articlesCount").number(count).close());
        }
    }

    private static Api.Reply comments(List<Row> rows, long viewer, Set<Pair> follows) {
        if (rows.isEmpty()) {
            return Api.notFound();
        }
        var comments = new ArrayList<Row>();
        for (var row : rows) {
            if (row.getValue(2) != null) {
                comments.add(row);
            }
        }
        comments.sort(Comparator.comparing((Row row) -> row.getOffsetDateTime(4))
                .thenComparingLong(row -> row.getLong(2))
                .reversed());
        var out = new Out().open().key("comments").openArray();
        for (var row : comments) {
            out.open()
                    .key("id").number(row.getLong(2))
                    .key("createdAt").timestamp(row.getOffsetDateTime(4))
                    .key("updatedAt").timestamp(row.getOffsetDateTime(5))
                    .key("body").string(row.getString(3))
                    .key("author").open()
                        .key("username").string(row.getString(7))
                        .key("bio").string(row.getString(8))
                        .key("image").string(row.getString(9))
                        .key("following").bool(follows.contains(new Pair(viewer, row.getLong(6))))
                    .close()
                    .close();
        }
        return reply(200, out.closeArray().close());
    }

    private static Out user(String email, String token, String username, @Nullable String bio, @Nullable String image) {
        return new Out().open().key("user").open()
                .key("email").string(email)
                .key("token").string(token)
                .key("username").string(username)
                .key("bio").string(bio)
                .key("image").string(image)
                .close().close();
    }

    private static Api.Reply reply(int status, Out out) {
        return new Api.Reply(status, out.toBuffer());
    }

    private static void ask(ArticleRow article, long viewer, Map<Long, Long> articleAuthors,
                            Set<Pair> favoriteAsks, Set<Pair> followAsks) {
        articleAuthors.putIfAbsent(article.id(), article.authorId());
        if (viewer != 0) {
            favoriteAsks.add(new Pair(viewer, article.id()));
            followAsks.add(new Pair(viewer, article.authorId()));
        }
    }

    private static void askAll(List<ArticleRow> page, long viewer, Map<Long, Long> articleAuthors,
                               Set<Pair> favoriteAsks, Set<Pair> followAsks) {
        for (var article : page) {
            ask(article, viewer, articleAuthors, favoriteAsks, followAsks);
        }
    }

    private static Row firstRow(RowSet<Row> rows) {
        return rows.iterator().next();
    }

    /// Rows by their key ordinal (column 0); index 0 is unused.
    private static @Nullable Row[] byOrdinal(@Nullable Future<RowSet<Row>> result, int keys) {
        var rows = new Row[keys + 1];
        if (result != null) {
            for (var row : result.await()) {
                rows[row.getLong(0).intValue()] = row;
            }
        }
        return rows;
    }

    private static ListResult lists(@Nullable Future<RowSet<Row>> result, int counts, int pages) {
        var lists = new ListResult(counts, pages);
        if (result != null) {
            for (var row : result.await()) {
                lists.add(row);
            }
        }
        return lists;
    }

    private static Tuple listParameters(Keys<String> counts, Keys<Page> pages) {
        return Tuple.tuple()
                .addArrayOfString(strings(counts.map.keySet()))
                .addArrayOfString(pages.map.keySet().stream().map(Page::key).toArray(String[]::new))
                .addArrayOfInteger(pages.map.keySet().stream().map(Page::limit).toArray(Integer[]::new))
                .addArrayOfLong(pages.map.keySet().stream().map(Page::offset).toArray(Long[]::new));
    }

    private static Long[] longs(Set<Long> values) {
        return values.toArray(new Long[0]);
    }

    private static String[] strings(Set<String> values) {
        return values.toArray(new String[0]);
    }
}
