package dev.moose.conduit.read;

import dev.moose.conduit.config.ConduitConfig;
import dev.moose.conduit.database.DatabaseService;
import dev.moose.conduit.database.DatabaseSession;
import dev.moose.conduit.database.NumberedSql;
import dev.moose.conduit.http.HttpReply;
import dev.moose.conduit.http.render.ResponseRenderer;
import dev.moose.conduit.json.JsonWriter;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.sql.ResultSet;
import java.sql.SQLException;
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
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

public class ReadService {

    private static final Logger LOGGER = LoggerFactory.getLogger(ReadService.class);
    private static final int RESPONSE_CHUNK = 16;

    public sealed interface Read {
    }

    public record Tags() implements Read {
    }

    public record CurrentUser(long id, String token) implements Read {
    }

    public record Login(String email) implements Read {
    }

    public record Profile(String username) implements Read {
    }

    public record Article(String slug) implements Read {
    }

    public record Comments(String slug) implements Read {
    }

    public record Global(int limit, long offset) implements Read {
    }

    public record ByTag(String tag, int limit, long offset) implements Read {
    }

    public record ByAuthor(String username, int limit, long offset) implements Read {
    }

    public record FavoritedBy(String username, int limit, long offset) implements Read {
    }

    public record Feed(int limit, long offset) implements Read {
    }

    public record Credentials(long id, String username, String email, String bio, String image, String passwordHash) {
    }

    private record Job(Read read, long viewer, CompletableFuture<Object> future) {
    }

    private record Page(String key, int limit, long offset) {
    }

    private record FeedPage(long viewer, int limit, long offset) {
    }

    private record Pair(long first, long second) {
    }

    private record ArticleRow(long id, long authorId, String slug, String title, String description,
                              OffsetDateTime createdAt, OffsetDateTime updatedAt, String body) {

        static ArticleRow of(ResultSet row, boolean withBody) throws SQLException {
            return new ArticleRow(row.getLong(2), row.getLong(3), row.getString(4), row.getString(5), row.getString(6),
                    row.getObject(7, OffsetDateTime.class), row.getObject(8, OffsetDateTime.class),
                    withBody ? row.getString(9) : null);
        }
    }

    private record CommentRow(long id, String body, OffsetDateTime createdAt, OffsetDateTime updatedAt,
                              long authorId, String username, String bio, String image) {
    }

    private record UserRow(long id, String username, String email, String bio, String image, String passwordHash) {
    }

    private record Extras(Integer[] tagIds, long favoritesCount, String username, String bio, String image) {
    }

    private static class Keys<K> {

        private final LinkedHashMap<K, Integer> ordinals = new LinkedHashMap<>();

        int index(K key) {
            final Integer existing = this.ordinals.get(key);
            if (existing != null) {
                return existing;
            }
            final int ordinal = this.ordinals.size() + 1;
            this.ordinals.put(key, ordinal);
            return ordinal;
        }

        boolean isEmpty() {
            return this.ordinals.isEmpty();
        }

        int size() {
            return this.ordinals.size();
        }

        Set<K> keys() {
            return this.ordinals.keySet();
        }
    }

    private static class ListResult {

        private final long[] counts;
        private final List<List<ArticleRow>> pages;

        ListResult(int countKeys, int pageKeys) {
            this.counts = new long[countKeys + 1];
            this.pages = new ArrayList<>(pageKeys + 1);
            for (int i = 0; i <= pageKeys; i++) {
                this.pages.add(new ArrayList<>());
            }
        }

        void read(ResultSet rows) throws SQLException {
            while (rows.next()) {
                final long ordinal = rows.getLong(1);
                if (ordinal <= 0) {
                    this.counts[(int) -ordinal] = rows.getLong(2);
                    continue;
                }
                this.pages.get((int) ordinal).add(ArticleRow.of(rows, false));
            }
        }
    }

    private final ReentrantLock lock = new ReentrantLock();
    private final Condition waiting = this.lock.newCondition();
    private final ReentrantLock gather = new ReentrantLock();
    private final ArrayList<Job> queue = new ArrayList<>();
    private final long windowNanos;
    private final int maxBatch;
    private final Executor responder;

    public ReadService(DatabaseService databaseService, ConduitConfig config, Executor responder) {
        this.windowNanos = TimeUnit.MICROSECONDS.toNanos(config.getReadWindowMicros());
        this.maxBatch = config.getReadMaxBatch();
        this.responder = responder;

        for (int i = 0; i < config.getReadLanes(); i++) {
            final DatabaseSession session = new DatabaseSession(databaseService);
            Thread.ofPlatform().name("read-lane-" + i).daemon().start(() -> this.run(session));
        }
    }

    public CompletableFuture<Object> read(Read read, long viewer) {
        final CompletableFuture<Object> future = new CompletableFuture<>();
        this.lock.lock();
        try {
            this.queue.add(new Job(read, viewer, future));
            if (this.queue.size() == 1) {
                this.waiting.signal();
            }
        } finally {
            this.lock.unlock();
        }
        return future;
    }

    private List<Job> take() throws InterruptedException {
        this.lock.lock();
        try {
            while (this.queue.isEmpty()) {
                this.waiting.await();
            }

            final long deadline = System.nanoTime() + this.windowNanos;
            long remaining = deadline - System.nanoTime();
            while (this.queue.size() < this.maxBatch && remaining > 0) {
                this.waiting.awaitNanos(remaining);
                remaining = deadline - System.nanoTime();
            }

            final int count = Math.min(this.queue.size(), this.maxBatch);
            final List<Job> batch = new ArrayList<>(this.queue.subList(0, count));
            this.queue.subList(0, count).clear();
            return batch;
        } finally {
            this.lock.unlock();
        }
    }

    private void run(DatabaseSession session) {
        while (true) {
            final List<Job> jobs;
            try {
                this.gather.lock();
                try {
                    jobs = this.take();
                } finally {
                    this.gather.unlock();
                }
            } catch (InterruptedException exception) {
                return;
            }

            try {
                this.batch(session, jobs);
            } catch (SQLException | RuntimeException exception) {
                LOGGER.error("Read batch of {} failed", jobs.size(), exception);
                session.reset();
                for (final Job job : jobs) {
                    this.responder.execute(() -> job.future().complete(HttpReply.INTERNAL));
                }
            }
        }
    }

    private void batch(DatabaseSession session, List<Job> jobs) throws SQLException {
        boolean tagsWanted = false;
        final Keys<Long> userIds = new Keys<>();
        final Keys<String> emails = new Keys<>();
        final Keys<String> profiles = new Keys<>();
        final Keys<String> slugs = new Keys<>();
        final Keys<String> commentSlugs = new Keys<>();
        final Keys<Page> globalPages = new Keys<>();
        final Keys<String> tagCounts = new Keys<>();
        final Keys<Page> tagPages = new Keys<>();
        final Keys<String> authorCounts = new Keys<>();
        final Keys<Page> authorPages = new Keys<>();
        final Keys<String> favoritedCounts = new Keys<>();
        final Keys<Page> favoritedPages = new Keys<>();
        final Keys<Long> feedCounts = new Keys<>();
        final Keys<FeedPage> feedPages = new Keys<>();

        final int[] countOrdinals = new int[jobs.size()];
        final int[] ordinals = new int[jobs.size()];
        for (int i = 0; i < jobs.size(); i++) {
            final Job job = jobs.get(i);
            switch (job.read()) {
                case Tags ignored -> tagsWanted = true;
                case CurrentUser currentUser -> ordinals[i] = userIds.index(currentUser.id());
                case Login login -> ordinals[i] = emails.index(login.email());
                case Profile profile -> ordinals[i] = profiles.index(profile.username());
                case Article article -> ordinals[i] = slugs.index(article.slug());
                case Comments comments -> ordinals[i] = commentSlugs.index(comments.slug());
                case Global global -> ordinals[i] = globalPages.index(new Page("", global.limit(), global.offset()));
                case ByTag byTag -> {
                    countOrdinals[i] = tagCounts.index(byTag.tag());
                    ordinals[i] = tagPages.index(new Page(byTag.tag(), byTag.limit(), byTag.offset()));
                }
                case ByAuthor byAuthor -> {
                    countOrdinals[i] = authorCounts.index(byAuthor.username());
                    ordinals[i] = authorPages.index(new Page(byAuthor.username(), byAuthor.limit(), byAuthor.offset()));
                }
                case FavoritedBy favoritedBy -> {
                    countOrdinals[i] = favoritedCounts.index(favoritedBy.username());
                    ordinals[i] = favoritedPages.index(new Page(favoritedBy.username(), favoritedBy.limit(), favoritedBy.offset()));
                }
                case Feed feed -> {
                    countOrdinals[i] = feedCounts.index(job.viewer());
                    ordinals[i] = feedPages.index(new FeedPage(job.viewer(), feed.limit(), feed.offset()));
                }
            }
        }

        final List<String> tagNames = tagsWanted ? readTags(session) : List.of();
        final UserRow[] users = userIds.isEmpty() ? null : readUsers(session.query(ReadSql.USERS_BY_ID,
                session.longs(userIds.keys().toArray(Long[]::new))), userIds.size(), false);
        final UserRow[] credentials = emails.isEmpty() ? null : readUsers(session.query(ReadSql.USERS_BY_EMAIL,
                session.texts(emails.keys().toArray(String[]::new))), emails.size(), true);
        final UserRow[] profileRows = profiles.isEmpty() ? null : readProfiles(session.query(ReadSql.PROFILES,
                session.texts(profiles.keys().toArray(String[]::new))), profiles.size());
        final ArticleRow[] articleRows = slugs.isEmpty() ? null : readArticles(session.query(ReadSql.ARTICLES_BY_SLUG,
                session.texts(slugs.keys().toArray(String[]::new))), slugs.size());
        final List<List<CommentRow>> commentRows = commentSlugs.isEmpty() ? null : readComments(session.query(ReadSql.COMMENTS,
                session.texts(commentSlugs.keys().toArray(String[]::new))), commentSlugs.size());

        final ListResult global = new ListResult(0, globalPages.size());
        if (!globalPages.isEmpty()) {
            global.read(session.query(ReadSql.GLOBAL,
                    session.ints(globalPages.keys().stream().map(Page::limit).toArray(Integer[]::new)),
                    session.longs(globalPages.keys().stream().map(Page::offset).toArray(Long[]::new))));
        }
        final ListResult byTag = readList(session, ReadSql.BY_TAG, tagCounts, tagPages);
        final ListResult byAuthor = readList(session, ReadSql.BY_AUTHOR, authorCounts, authorPages);
        final ListResult favoritedBy = readList(session, ReadSql.FAVORITED_BY, favoritedCounts, favoritedPages);
        final ListResult feed = new ListResult(feedCounts.size(), feedPages.size());
        if (!feedPages.isEmpty()) {
            feed.read(session.query(ReadSql.FEED,
                    session.longs(feedCounts.keys().toArray(Long[]::new)),
                    session.longs(feedPages.keys().stream().map(FeedPage::viewer).toArray(Long[]::new)),
                    session.ints(feedPages.keys().stream().map(FeedPage::limit).toArray(Integer[]::new)),
                    session.longs(feedPages.keys().stream().map(FeedPage::offset).toArray(Long[]::new))));
        }

        final LinkedHashMap<Long, Long> articleAuthors = new LinkedHashMap<>();
        final LinkedHashSet<Pair> favoriteAsks = new LinkedHashSet<>();
        final LinkedHashSet<Pair> followAsks = new LinkedHashSet<>();
        for (int i = 0; i < jobs.size(); i++) {
            final Job job = jobs.get(i);
            final long viewer = job.viewer();
            switch (job.read()) {
                case Profile ignored -> {
                    final UserRow row = profileRows[ordinals[i]];
                    if (row != null && viewer != 0) {
                        followAsks.add(new Pair(viewer, row.id()));
                    }
                }
                case Article ignored -> {
                    final ArticleRow row = articleRows[ordinals[i]];
                    if (row != null) {
                        ask(row, viewer, articleAuthors, favoriteAsks, followAsks);
                    }
                }
                case Comments ignored -> {
                    if (viewer != 0) {
                        for (final CommentRow row : commentRows.get(ordinals[i])) {
                            followAsks.add(new Pair(viewer, row.authorId()));
                        }
                    }
                }
                case Global ignored -> askAll(global.pages.get(ordinals[i]), viewer, articleAuthors, favoriteAsks, followAsks);
                case ByTag ignored -> askAll(byTag.pages.get(ordinals[i]), viewer, articleAuthors, favoriteAsks, followAsks);
                case ByAuthor ignored -> askAll(byAuthor.pages.get(ordinals[i]), viewer, articleAuthors, favoriteAsks, followAsks);
                case FavoritedBy ignored -> askAll(favoritedBy.pages.get(ordinals[i]), viewer, articleAuthors, favoriteAsks, followAsks);
                case Feed ignored -> {
                    for (final ArticleRow article : feed.pages.get(ordinals[i])) {
                        articleAuthors.putIfAbsent(article.id(), article.authorId());
                        favoriteAsks.add(new Pair(viewer, article.id()));
                    }
                }
                default -> {
                }
            }
        }

        final Map<Long, Extras> extras = new HashMap<>();
        final Map<Integer, Integer> tagRank = new HashMap<>();
        final Map<Integer, String> tagName = new HashMap<>();
        if (!articleAuthors.isEmpty()) {
            final Long[] ids = articleAuthors.keySet().toArray(Long[]::new);
            try (ResultSet rows = session.query(ReadSql.ARTICLE_EXTRAS, session.longs(ids),
                    session.longs(articleAuthors.values().toArray(Long[]::new)))) {
                while (rows.next()) {
                    extras.put(rows.getLong(1), new Extras((Integer[]) rows.getArray(2).getArray(), rows.getLong(3),
                            rows.getString(4), rows.getString(5), rows.getString(6)));
                }
            }
            try (ResultSet rows = session.query(ReadSql.TAG_NAMES, session.longs(ids))) {
                int rank = 0;
                while (rows.next()) {
                    tagRank.put(rows.getInt(1), rank++);
                    tagName.put(rows.getInt(1), rows.getString(2));
                }
            }
        }

        final Set<Pair> favorites = new HashSet<>();
        final Set<Pair> follows = new HashSet<>();
        if (!favoriteAsks.isEmpty() || !followAsks.isEmpty()) {
            try (ResultSet rows = session.query(ReadSql.FLAGS,
                    session.longs(favoriteAsks.stream().map(Pair::first).toArray(Long[]::new)),
                    session.longs(favoriteAsks.stream().map(Pair::second).toArray(Long[]::new)),
                    session.longs(followAsks.stream().map(Pair::first).toArray(Long[]::new)),
                    session.longs(followAsks.stream().map(Pair::second).toArray(Long[]::new)))) {
                while (rows.next()) {
                    (rows.getInt(1) == 0 ? favorites : follows).add(new Pair(rows.getLong(2), rows.getLong(3)));
                }
            }
        }
        final View view = new View(extras, tagRank, tagName, favorites, follows);

        for (int chunkStart = 0; chunkStart < jobs.size(); chunkStart += RESPONSE_CHUNK) {
            final int from = chunkStart;
            final int to = Math.min(jobs.size(), chunkStart + RESPONSE_CHUNK);
            this.responder.execute(() -> {
                for (int i = from; i < to; i++) {
                    final Job job = jobs.get(i);
                    final long viewer = job.viewer();
                    final int ordinal = ordinals[i];
                    final int countOrdinal = countOrdinals[i];
                    try {
                        job.future().complete(switch (job.read()) {
                            case Tags ignored -> tags(tagNames);
                            case CurrentUser currentUser -> currentUser(users[ordinal], currentUser.token());
                            case Login ignored -> credentials(credentials[ordinal]);
                            case Profile ignored -> profile(profileRows[ordinal], viewer, follows);
                            case Article ignored -> view.single(articleRows[ordinal], viewer);
                            case Comments ignored -> comments(commentRows.get(ordinal), viewer, follows);
                            case Global ignored -> view.list(global.counts[0], global.pages.get(ordinal), viewer, false);
                            case ByTag ignored -> view.list(byTag.counts[countOrdinal], byTag.pages.get(ordinal), viewer, false);
                            case ByAuthor ignored -> view.list(byAuthor.counts[countOrdinal], byAuthor.pages.get(ordinal), viewer, false);
                            case FavoritedBy ignored -> view.list(favoritedBy.counts[countOrdinal], favoritedBy.pages.get(ordinal), viewer, false);
                            case Feed ignored -> view.list(feed.counts[countOrdinal], feed.pages.get(ordinal), viewer, true);
                        });
                    } catch (RuntimeException exception) {
                        LOGGER.error("Rendering a read failed", exception);
                        job.future().complete(HttpReply.INTERNAL);
                    }
                }
            });
        }
    }

    private record View(Map<Long, Extras> extras, Map<Integer, Integer> tagRank, Map<Integer, String> tagName,
                        Set<Pair> favorites, Set<Pair> follows) {

        HttpReply single(ArticleRow article, long viewer) {
            if (article == null || !this.extras.containsKey(article.id())) {
                return HttpReply.NOT_FOUND;
            }
            final JsonWriter out = new JsonWriter(2048).open().key("article");
            this.write(out, article, viewer, false);
            return HttpReply.ok(out.close());
        }

        HttpReply list(long count, List<ArticleRow> page, long viewer, boolean feed) {
            final List<ArticleRow> sorted = new ArrayList<>(page);
            sorted.sort(Comparator.comparingLong(ArticleRow::id).reversed());
            final JsonWriter out = new JsonWriter(1024 + 640 * sorted.size()).open().key("articles").openArray();
            for (final ArticleRow article : sorted) {
                if (this.extras.containsKey(article.id())) {
                    this.write(out, article, viewer, feed);
                }
            }
            return HttpReply.ok(out.closeArray().key("articlesCount").number(count).close());
        }

        private void write(JsonWriter out, ArticleRow article, long viewer, boolean feed) {
            final Extras extra = this.extras.get(article.id());
            final Integer[] tagIds = extra.tagIds().clone();
            Arrays.sort(tagIds, Comparator.comparingInt(tagId -> this.tagRank.getOrDefault(tagId, Integer.MAX_VALUE)));
            out.open()
                    .key("slug").string(article.slug())
                    .key("title").string(article.title())
                    .key("description").string(article.description());
            if (article.body() != null) {
                out.key("body").string(article.body());
            }
            out.key("tagList").openArray();
            for (final Integer tagId : tagIds) {
                final String name = this.tagName.get(tagId);
                if (name != null) {
                    out.string(name);
                }
            }
            out.closeArray()
                    .key("createdAt").timestamp(article.createdAt())
                    .key("updatedAt").timestamp(article.updatedAt())
                    .key("favorited").bool(viewer != 0 && this.favorites.contains(new Pair(viewer, article.id())))
                    .key("favoritesCount").number(extra.favoritesCount())
                    .key("author").open()
                    .key("username").string(extra.username())
                    .key("bio").string(extra.bio())
                    .key("image").string(extra.image())
                    .key("following").bool(feed || (viewer != 0 && this.follows.contains(new Pair(viewer, article.authorId()))))
                    .close()
                    .close();
        }
    }

    private static HttpReply tags(List<String> names) {
        final JsonWriter out = new JsonWriter(4096).open().key("tags").openArray();
        for (final String name : names) {
            out.string(name);
        }
        return HttpReply.ok(out.closeArray().close());
    }

    private static HttpReply currentUser(UserRow row, String token) {
        if (row == null) {
            return HttpReply.UNAUTHORIZED;
        }
        return ResponseRenderer.user(200, row.email(), token, row.username(), row.bio(), row.image());
    }

    private static Credentials credentials(UserRow row) {
        if (row == null) {
            return null;
        }
        return new Credentials(row.id(), row.username(), row.email(), row.bio(), row.image(), row.passwordHash());
    }

    private static HttpReply profile(UserRow row, long viewer, Set<Pair> follows) {
        if (row == null) {
            return HttpReply.NOT_FOUND;
        }
        return ResponseRenderer.profile(row.username(), row.bio(), row.image(), follows.contains(new Pair(viewer, row.id())));
    }

    private static HttpReply comments(List<CommentRow> rows, long viewer, Set<Pair> follows) {
        if (rows == null) {
            return HttpReply.NOT_FOUND;
        }
        final List<CommentRow> sorted = new ArrayList<>(rows);
        sorted.sort(Comparator.comparing(CommentRow::createdAt).thenComparingLong(CommentRow::id).reversed());
        final JsonWriter out = new JsonWriter(512 + 400 * sorted.size()).open().key("comments").openArray();
        for (final CommentRow row : sorted) {
            out.open()
                    .key("id").number(row.id())
                    .key("createdAt").timestamp(row.createdAt())
                    .key("updatedAt").timestamp(row.updatedAt())
                    .key("body").string(row.body())
                    .key("author").open()
                    .key("username").string(row.username())
                    .key("bio").string(row.bio())
                    .key("image").string(row.image())
                    .key("following").bool(viewer != 0 && follows.contains(new Pair(viewer, row.authorId())))
                    .close()
                    .close();
        }
        return HttpReply.ok(out.closeArray().close());
    }

    private static void ask(ArticleRow article, long viewer, Map<Long, Long> articleAuthors,
                            Set<Pair> favoriteAsks, Set<Pair> followAsks) {
        articleAuthors.putIfAbsent(article.id(), article.authorId());
        if (viewer == 0) {
            return;
        }
        favoriteAsks.add(new Pair(viewer, article.id()));
        followAsks.add(new Pair(viewer, article.authorId()));
    }

    private static void askAll(List<ArticleRow> page, long viewer, Map<Long, Long> articleAuthors,
                               Set<Pair> favoriteAsks, Set<Pair> followAsks) {
        for (final ArticleRow article : page) {
            ask(article, viewer, articleAuthors, favoriteAsks, followAsks);
        }
    }

    private static List<String> readTags(DatabaseSession session) throws SQLException {
        try (ResultSet rows = session.query(ReadSql.TAGS)) {
            rows.next();
            return List.of((String[]) rows.getArray(1).getArray());
        }
    }

    private static UserRow[] readUsers(ResultSet rows, int keys, boolean withHash) throws SQLException {
        final UserRow[] result = new UserRow[keys + 1];
        try (rows) {
            while (rows.next()) {
                result[rows.getInt(1)] = new UserRow(rows.getLong(2), rows.getString(3), rows.getString(4),
                        rows.getString(5), rows.getString(6), withHash ? rows.getString(7) : null);
            }
        }
        return result;
    }

    private static UserRow[] readProfiles(ResultSet rows, int keys) throws SQLException {
        final UserRow[] result = new UserRow[keys + 1];
        try (rows) {
            while (rows.next()) {
                result[rows.getInt(1)] = new UserRow(rows.getLong(2), rows.getString(3), null,
                        rows.getString(4), rows.getString(5), null);
            }
        }
        return result;
    }

    private static ArticleRow[] readArticles(ResultSet rows, int keys) throws SQLException {
        final ArticleRow[] result = new ArticleRow[keys + 1];
        try (rows) {
            while (rows.next()) {
                result[rows.getInt(1)] = ArticleRow.of(rows, true);
            }
        }
        return result;
    }

    private static List<List<CommentRow>> readComments(ResultSet rows, int keys) throws SQLException {
        final List<List<CommentRow>> result = new ArrayList<>(keys + 1);
        for (int i = 0; i <= keys; i++) {
            result.add(null);
        }
        try (rows) {
            while (rows.next()) {
                final int ordinal = rows.getInt(1);
                List<CommentRow> list = result.get(ordinal);
                if (list == null) {
                    list = new ArrayList<>();
                    result.set(ordinal, list);
                }
                final long commentId = rows.getLong(3);
                if (rows.wasNull()) {
                    continue;
                }
                list.add(new CommentRow(commentId, rows.getString(4), rows.getObject(5, OffsetDateTime.class),
                        rows.getObject(6, OffsetDateTime.class), rows.getLong(7), rows.getString(8),
                        rows.getString(9), rows.getString(10)));
            }
        }
        return result;
    }

    private static ListResult readList(DatabaseSession session, NumberedSql sql, Keys<String> counts, Keys<Page> pages)
            throws SQLException {
        final ListResult result = new ListResult(counts.size(), pages.size());
        if (pages.isEmpty()) {
            return result;
        }
        try (ResultSet rows = session.query(sql,
                session.texts(counts.keys().toArray(String[]::new)),
                session.texts(pages.keys().stream().map(Page::key).toArray(String[]::new)),
                session.ints(pages.keys().stream().map(Page::limit).toArray(Integer[]::new)),
                session.longs(pages.keys().stream().map(Page::offset).toArray(Long[]::new)))) {
            result.read(rows);
        }
        return result;
    }

}
