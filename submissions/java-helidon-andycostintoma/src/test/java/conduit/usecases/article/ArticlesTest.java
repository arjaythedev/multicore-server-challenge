package conduit.usecases.article;

import static org.junit.jupiter.api.Assertions.*;

import conduit.contracts.UnitOfWork;
import conduit.contracts.article.ArticleReader;
import conduit.contracts.article.ArticleRepository;
import conduit.contracts.article.readmodel.ArticleDetails;
import conduit.contracts.article.readmodel.ArticlePage;
import conduit.contracts.article.readmodel.CommentView;
import conduit.contracts.article.readmodel.ProfileView;
import conduit.contracts.comment.CommentRepository;
import conduit.contracts.favorite.FavoriteStore;
import conduit.domain.Article;
import conduit.domain.Comment;
import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;
import conduit.errors.NotFound;
import conduit.usecases.commands.AddComment;
import conduit.usecases.commands.CreateArticle;
import conduit.usecases.commands.DeleteArticle;
import conduit.usecases.commands.DeleteComment;
import conduit.usecases.commands.FavoriteArticle;
import conduit.usecases.commands.UnfavoriteArticle;
import conduit.usecases.commands.UpdateArticle;
import conduit.usecases.queries.GetArticle;
import conduit.usecases.queries.ListArticles;
import conduit.usecases.queries.ListComments;
import conduit.usecases.queries.ListFeed;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import org.junit.jupiter.api.Test;

class ArticlesTest {
    @Test
    void createUsesOneScopedTransactionAndReadsOnlyAfterCommit() {
        var fixture = new Fixture();
        var response = fixture.create.execute(7,
            new CreateArticle.Request("Hello World", "d", "b", List.of("z", "a", "z")));
        assertEquals(List.of("begin", "next-id", "insert", "commit", "read"), fixture.events);
        assertEquals("hello-world-4000000000", response.slug());
        assertEquals(List.of("z", "a"), fixture.tags);
    }

    @Test
    void invalidTagsDoNotOpenTransactionAndInvalidFieldsAllocateNoId() {
        var fixture = new Fixture();
        assertThrows(InvalidInput.class,
            () -> fixture.create.execute(7, new CreateArticle.Request("t", "d", "b", List.of(""))));
        assertEquals(List.of(), fixture.events);
        assertThrows(InvalidInput.class,
            () -> fixture.create.execute(7, new CreateArticle.Request("", "d", "b", List.of())));
        assertEquals(List.of("begin", "rollback"), fixture.events);
    }

    @Test
    void directCreationValidatesEveryRequiredFieldAndNormalizesNullTags() {
        var fixture = new Fixture();
        for (String empty : new String[]{null, ""}) {
            assertThrows(InvalidInput.class,
                () -> fixture.create.execute(7, new CreateArticle.Request(empty, "d", "b", null)));
            assertThrows(InvalidInput.class,
                () -> fixture.create.execute(7, new CreateArticle.Request("t", empty, "b", null)));
            assertThrows(InvalidInput.class,
                () -> fixture.create.execute(7, new CreateArticle.Request("t", "d", empty, null)));
        }
        assertFalse(fixture.events.contains("next-id"));
        assertFalse(fixture.events.contains("insert"));
        fixture.create.execute(7, new CreateArticle.Request("t", "d", "b", null));
        assertEquals(List.of(), fixture.tags);
    }

    @Test
    void directUpdatesValidateFieldsAfterLookupAndAuthorization() {
        var fixture = new Fixture();
        assertThrows(NotFound.class,
            () -> fixture.update.execute(7, "missing", new UpdateArticle.Request("", null, null)));
        assertThrows(Forbidden.class,
            () -> fixture.update.execute(8, "old-1", new UpdateArticle.Request("", null, null)));
        for (var input : List.of(new UpdateArticle.Request("", null, null),
            new UpdateArticle.Request(null, "", null), new UpdateArticle.Request(null, null, ""))) {
            assertThrows(InvalidInput.class, () -> fixture.update.execute(7, "old-1", input));
        }
        assertFalse(fixture.events.contains("update"));
        var response = fixture.update.execute(7, "old-1",
            new UpdateArticle.Request(null, null, "new body"));
        assertEquals("new body", response.body());
        assertEquals("old-1", response.slug());
    }

    @Test
    void failedWriteDoesNotReadOrCommit() {
        var fixture = new Fixture();
        fixture.failInsert = true;
        assertThrows(IllegalStateException.class,
            () -> fixture.create.execute(7, new CreateArticle.Request("t", "d", "b", List.of())));
        assertEquals(List.of("begin", "next-id", "insert", "rollback"), fixture.events);
    }

    @Test
    void deniedMutationsRollBackBeforeWriting() {
        var fixture = new Fixture();
        assertThrows(Forbidden.class,
            () -> fixture.update.execute(8, "old-1", new UpdateArticle.Request("new", null, null)));
        assertEquals(List.of("begin", "load", "rollback"), fixture.events);
        fixture.events.clear();
        assertThrows(Forbidden.class, () -> fixture.delete.execute(8, "old-1"));
        assertEquals(List.of("begin", "load", "rollback"), fixture.events);
        fixture.events.clear();
        assertThrows(Forbidden.class, () -> fixture.deleteComment.execute(8, "old-1", 2));
        assertEquals(List.of("begin", "load-comment", "rollback"), fixture.events);
    }

    @Test
    void favoritesReadFullArticleAfterCommit() {
        var fixture = new Fixture();
        assertNotNull(fixture.favorite.execute(8, "old-1").body());
        assertEquals(Boolean.TRUE, fixture.favoriteIntent);
        assertEquals(List.of("begin", "load", "favorite", "commit", "read"), fixture.events);
    }

    @Test
    void unfavoritesUseExplicitRemovalAndReadOnlyAfterCommit() {
        var fixture = new Fixture();
        assertNotNull(fixture.unfavorite.execute(8, "old-1").body());
        assertEquals(Boolean.FALSE, fixture.favoriteIntent);
        assertEquals(List.of("begin", "load", "favorite", "commit", "read"), fixture.events);
        fixture.events.clear();
        assertThrows(NotFound.class, () -> fixture.unfavorite.execute(8, "missing"));
        assertEquals(List.of("begin", "load", "rollback"), fixture.events);
    }

    @Test
    void queriesBypassTransactions() {
        var fixture = new Fixture();
        assertEquals("old-1", fixture.get.execute(0, "old-1").slug());
        assertEquals(List.of(), fixture.comments.execute(0, "old-1"));
        assertEquals(0, fixture.feed.execute(7, 20, 0).articlesCount());
        assertEquals(List.of("get", "comments", "feed"), fixture.events);
    }

    @Test
    void authorizedDeletesCommitWithoutPostCommitReads() {
        var fixture = new Fixture();
        fixture.delete.execute(7, "old-1");
        assertEquals(List.of("begin", "load", "delete", "commit"), fixture.events);
        fixture.events.clear();
        fixture.deleteComment.execute(7, "old-1", 2);
        assertEquals(List.of("begin", "load-comment", "delete-comment", "commit"), fixture.events);
    }

    @Test
    void listBypassesTransactionsAndNormalizesEmptyFilters() {
        var fixture = new Fixture();
        fixture.list.execute(0, 5, 10, "", "author", "favoriter");
        assertEquals(List.of("list"), fixture.events);
        assertNull(fixture.tagFilter);
        assertEquals("author", fixture.authorFilter);
        assertEquals("favoriter", fixture.favoritedFilter);
        assertThrows(InvalidInput.class, () -> fixture.list.execute(0, 0, 0, null, null, null));
        assertThrows(InvalidInput.class, () -> fixture.feed.execute(7, 101, 0));
        assertThrows(InvalidInput.class, () -> fixture.feed.execute(7, 20, -1));
    }

    @Test
    void paginationRejectsAllInvalidBoundsBeforeReading() {
        var fixture = new Fixture();
        for (int limit : new int[]{Integer.MIN_VALUE, 0, 101, Integer.MAX_VALUE}) {
            assertThrows(InvalidInput.class,
                () -> fixture.list.execute(0, limit, 0, null, null, null));
            assertThrows(InvalidInput.class, () -> fixture.feed.execute(7, limit, 0));
        }
        assertThrows(InvalidInput.class, () -> fixture.list.execute(0, 20, -1, null, null, null));
        assertThrows(InvalidInput.class, () -> fixture.feed.execute(7, 20, -1));
        assertEquals(List.of(), fixture.events);
        fixture.list.execute(0, 1, Long.MAX_VALUE, "tag", "", "");
        assertEquals("tag", fixture.tagFilter);
        assertNull(fixture.authorFilter);
        assertNull(fixture.favoritedFilter);
        fixture.feed.execute(7, 100, Long.MAX_VALUE);
    }

    @Test
    void invalidCommentsRollBackWithoutWriting() {
        var fixture = new Fixture();
        for (String body : new String[]{null, ""}) {
            assertThrows(InvalidInput.class, () -> fixture.comment.execute(7, "old-1", body));
            assertEquals(List.of("begin", "load", "rollback"), fixture.events);
            fixture.events.clear();
        }
        var response = fixture.comment.execute(7, "old-1", "comment");
        assertEquals(4_000_000_001L, response.id());
        assertEquals("comment", response.body());
        assertFalse(response.author().following());
        assertEquals(List.of("begin", "load", "insert-comment", "commit", "read-comment"),
            fixture.events);
    }

    @Test
    void missingCommentArticleRollsBackWithoutWritingOrReading() {
        var fixture = new Fixture();
        assertThrows(NotFound.class, () -> fixture.comment.execute(7, "missing", "body"));
        assertEquals(List.of("begin", "load", "rollback"), fixture.events);
    }

    @Test
    void failedCommentWriteOrCommitDoesNotReadProjection() {
        var fixture = new Fixture();
        fixture.failInsert = true;
        assertThrows(IllegalStateException.class,
            () -> fixture.comment.execute(7, "old-1", "body"));
        assertEquals(List.of("begin", "load", "insert-comment", "rollback"), fixture.events);
        fixture.events.clear();
        fixture.failInsert = false;
        fixture.failCommit = true;
        assertThrows(IllegalStateException.class,
            () -> fixture.comment.execute(7, "old-1", "body"));
        assertEquals(List.of("begin", "load", "insert-comment", "rollback"), fixture.events);
    }

    @Test
    void missingCommentProjectionReturnsNotFoundAfterCommit() {
        var fixture = new Fixture();
        fixture.missingCommentProjection = true;
        assertThrows(NotFound.class, () -> fixture.comment.execute(7, "old-1", "body"));
        assertEquals(List.of("begin", "load", "insert-comment", "commit", "read-comment"),
            fixture.events);
    }

    @Test
    void missingArticlesReturnFailureWithoutWritingOrReading() {
        var fixture = new Fixture();
        assertThrows(NotFound.class, () -> fixture.favorite.execute(7, "missing"));
        assertEquals(List.of("begin", "load", "rollback"), fixture.events);
        fixture.events.clear();
        assertThrows(NotFound.class, () -> fixture.update.execute(7, "missing",
            new UpdateArticle.Request("new", null, null)));
        assertEquals(List.of("begin", "load", "rollback"), fixture.events);
    }

    private static final class Fixture
        implements
            ArticleReader,
            UnitOfWork,
            ArticleRepository,
            CommentRepository,
            FavoriteStore {
        private final List<String> events = new ArrayList<>();
        private final CreateArticle create = new CreateArticle(this, this);
        private final UpdateArticle update = new UpdateArticle(this, this);
        private final DeleteArticle delete = new DeleteArticle(this);
        private final FavoriteArticle favorite = new FavoriteArticle(this, this);
        private final UnfavoriteArticle unfavorite = new UnfavoriteArticle(this, this);
        private final AddComment comment = new AddComment(this, this);
        private final DeleteComment deleteComment = new DeleteComment(this);
        private final GetArticle get = new GetArticle(this);
        private final ListArticles list = new ListArticles(this);
        private final ListFeed feed = new ListFeed(this);
        private final ListComments comments = new ListComments(this);
        private Article article = Article.create(7, "old", "d", "b", () -> 1);
        private List<String> tags;
        private String tagFilter;
        private String authorFilter;
        private String favoritedFilter;
        private Boolean favoriteIntent;
        private boolean failInsert;
        private boolean failCommit;
        private boolean missingCommentProjection;
        private Comment insertedComment;

        @Override
        public <T> T run(Function<Context, T> work) {
            events.add("begin");
            try {
                var result = work.apply(new Context(null, this, this, null, this));
                if (failCommit) {
                    throw new IllegalStateException("commit failed");
                }
                events.add("commit");
                return result;
            } catch (RuntimeException failure) {
                events.add("rollback");
                throw failure;
            }
        }

        @Override
        public long nextArticleId() {
            events.add("next-id");
            return 4_000_000_000L;
        }

        @Override
        public long articleId(String slug) {
            events.add("load");
            if (slug.equals("missing")) {
                throw new NotFound("Article not found");
            }
            return article.id();
        }

        @Override
        public Article article(String slug) {
            events.add("load");
            if (slug.equals("missing")) {
                throw new NotFound("Article not found");
            }
            return article;
        }

        @Override
        public void insert(Article article, List<String> tags) {
            events.add("insert");
            if (failInsert) {
                throw new IllegalStateException("write failed");
            }
            this.article = article;
            this.tags = tags;
        }

        @Override
        public void update(Article article) {
            events.add("update");
            this.article = article;
        }

        @Override
        public void deleteArticle(long id) {
            events.add("delete");
        }

        @Override
        public void add(long articleId, long viewer) {
            events.add("favorite");
            favoriteIntent = true;
        }

        @Override
        public void remove(long articleId, long viewer) {
            events.add("favorite");
            favoriteIntent = false;
        }

        @Override
        public Comment insertComment(Comment comment) {
            events.add("insert-comment");
            if (failInsert) {
                throw new IllegalStateException("write failed");
            }
            insertedComment = Comment.reconstitute(new Comment.Props(4_000_000_001L,
                comment.articleId(), comment.authorId(), comment.body()));
            return insertedComment;
        }

        @Override
        public Comment comment(String slug, long id) {
            events.add("load-comment");
            return Comment.reconstitute(new Comment.Props(id, 1, 7, "body"));
        }

        @Override
        public void deleteComment(long id) {
            events.add("delete-comment");
        }

        @Override
        public ArticlePage list(long viewer, int limit, long offset, String tag, String author,
            String favorited) {
            events.add("list");
            tagFilter = tag;
            authorFilter = author;
            favoritedFilter = favorited;
            return new ArticlePage(List.of(), 0);
        }

        @Override
        public ArticlePage feed(long viewer, int limit, long offset) {
            events.add("feed");
            return new ArticlePage(List.of(), 0);
        }

        @Override
        public ArticleDetails bySlug(long viewer, String slug) {
            events.add("get");
            return fullArticle();
        }

        @Override
        public ArticleDetails byId(long viewer, long id) {
            assertEquals("commit", events.getLast());
            events.add("read");
            return fullArticle();
        }

        private ArticleDetails fullArticle() {
            return new ArticleDetails(article.slug(), article.title(), article.description(),
                article.body(), List.of(), "time", "time", false, 0,
                new ProfileView("author", null, null, false));
        }

        @Override
        public List<CommentView> comments(long viewer, String slug) {
            events.add("comments");
            return List.of();
        }

        @Override
        public CommentView comment(long viewer, String slug, long id) {
            assertEquals("commit", events.getLast());
            assertEquals(insertedComment.id(), id);
            assertEquals(insertedComment.authorId(), viewer);
            assertEquals("old-1", slug);
            events.add("read-comment");
            if (missingCommentProjection) {
                throw new NotFound("Not found");
            }
            return new CommentView(id, "time", "time", insertedComment.body(),
                new ProfileView("author", null, null, false));
        }
    }
}
