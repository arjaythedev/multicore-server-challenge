package conduit.wiring;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.zaxxer.hikari.HikariDataSource;
import conduit.adapters.inbound.http.HttpServer;
import conduit.adapters.inbound.http.article.ArticleRoutes;
import conduit.adapters.inbound.http.article.handlers.AddCommentHandler;
import conduit.adapters.inbound.http.article.handlers.CreateArticleHandler;
import conduit.adapters.inbound.http.article.handlers.DeleteArticleHandler;
import conduit.adapters.inbound.http.article.handlers.DeleteCommentHandler;
import conduit.adapters.inbound.http.article.handlers.FavoriteArticleHandler;
import conduit.adapters.inbound.http.article.handlers.GetArticleHandler;
import conduit.adapters.inbound.http.article.handlers.ListArticlesHandler;
import conduit.adapters.inbound.http.article.handlers.ListCommentsHandler;
import conduit.adapters.inbound.http.article.handlers.ListFeedHandler;
import conduit.adapters.inbound.http.article.handlers.UnfavoriteArticleHandler;
import conduit.adapters.inbound.http.article.handlers.UpdateArticleHandler;
import conduit.adapters.inbound.http.tags.TagRoutes;
import conduit.adapters.inbound.http.tags.handlers.ListTagsHandler;
import conduit.adapters.inbound.http.user.UserRoutes;
import conduit.adapters.inbound.http.user.handlers.FollowUserHandler;
import conduit.adapters.inbound.http.user.handlers.GetProfileHandler;
import conduit.adapters.inbound.http.user.handlers.GetUserHandler;
import conduit.adapters.inbound.http.user.handlers.LoginHandler;
import conduit.adapters.inbound.http.user.handlers.RegisterUserHandler;
import conduit.adapters.inbound.http.user.handlers.UnfollowUserHandler;
import conduit.adapters.inbound.http.user.handlers.UpdateUserHandler;
import conduit.adapters.outbound.postgres.jooq.article.JooqArticleReader;
import conduit.adapters.outbound.postgres.jooq.JooqUnitOfWork;
import conduit.adapters.outbound.postgres.jooq.tag.JooqTagReader;
import conduit.adapters.outbound.postgres.jooq.user.JooqLoginReader;
import conduit.adapters.outbound.postgres.jooq.user.JooqUserReader;
import conduit.adapters.outbound.security.BCryptPasswords;
import conduit.adapters.outbound.security.JwtTokens;
import conduit.contracts.UnitOfWork;
import conduit.usecases.commands.AddComment;
import conduit.usecases.commands.CreateArticle;
import conduit.usecases.commands.DeleteArticle;
import conduit.usecases.commands.DeleteComment;
import conduit.usecases.commands.FavoriteArticle;
import conduit.usecases.commands.FollowUser;
import conduit.usecases.commands.Login;
import conduit.usecases.commands.RegisterUser;
import conduit.usecases.commands.UnfavoriteArticle;
import conduit.usecases.commands.UnfollowUser;
import conduit.usecases.commands.UpdateArticle;
import conduit.usecases.commands.UpdateUser;
import conduit.usecases.queries.Authenticate;
import conduit.usecases.queries.GetArticle;
import conduit.usecases.queries.GetProfile;
import conduit.usecases.queries.GetUser;
import conduit.usecases.queries.ListArticles;
import conduit.usecases.queries.ListComments;
import conduit.usecases.queries.ListFeed;
import conduit.usecases.queries.ListTags;
import io.helidon.webserver.WebServer;
import java.time.Clock;
import org.jooq.DSLContext;
import org.jooq.SQLDialect;
import org.jooq.conf.Settings;
import org.jooq.impl.DSL;

public final class Application implements AutoCloseable {
    private final HikariDataSource database;
    private final WebServer server;

    public static Application start(Config config) {
        var database = Database.open(config.databaseUrl(), config.databasePoolSize());
        try {
            var sql = DSL.using(database, SQLDialect.POSTGRES,
                new Settings().withExecuteLogging(false));
            var json = new ObjectMapper();
            var tagRoutes = new TagRoutes(
                new ListTagsHandler(new ListTags(new JooqTagReader(sql)), json));
            var tokens = new JwtTokens(config.jwtSecret(), Clock.systemUTC());
            var authentication = new Authenticate(tokens);
            var uow = new JooqUnitOfWork(sql);
            var userRoutes = userRoutes(sql, uow, authentication, tokens, json);
            var articleRoutes = articleRoutes(sql, uow, authentication, json);
            var server = HttpServer.create(json, routes -> {
                tagRoutes.register(routes);
                userRoutes.register(routes);
                articleRoutes.register(routes);
            }, config.host(), config.port()).start();
            return new Application(database, server);
        } catch (RuntimeException | Error failure) {
            database.close();
            throw failure;
        }
    }

    public int port() {
        return server.port();
    }

    @Override
    public void close() {
        try {
            server.stop();
        } finally {
            database.close();
        }
    }

    private Application(HikariDataSource database, WebServer server) {
        this.database = database;
        this.server = server;
    }

    private static UserRoutes userRoutes(DSLContext sql, UnitOfWork uow,
        Authenticate authentication, JwtTokens tokens, ObjectMapper json) {
        var reader = new JooqUserReader(sql);
        var passwords = new BCryptPasswords();
        return new UserRoutes(
            new RegisterUserHandler(new RegisterUser(uow, passwords, tokens::issue), json),
            new LoginHandler(new Login(new JooqLoginReader(sql), passwords, tokens::issue), json),
            new GetUserHandler(new GetUser(reader), authentication, json),
            new UpdateUserHandler(new UpdateUser(uow, passwords), authentication, json),
            new GetProfileHandler(new GetProfile(reader), authentication, json),
            new FollowUserHandler(new FollowUser(uow), authentication, json),
            new UnfollowUserHandler(new UnfollowUser(uow), authentication, json));
    }

    private static ArticleRoutes articleRoutes(DSLContext sql, UnitOfWork uow,
        Authenticate authentication, ObjectMapper json) {
        var reader = new JooqArticleReader(sql);
        return new ArticleRoutes(
            new CreateArticleHandler(new CreateArticle(reader, uow), authentication, json),
            new UpdateArticleHandler(new UpdateArticle(reader, uow), authentication, json),
            new DeleteArticleHandler(new DeleteArticle(uow), authentication, json),
            new FavoriteArticleHandler(new FavoriteArticle(reader, uow), authentication, json),
            new UnfavoriteArticleHandler(new UnfavoriteArticle(reader, uow), authentication, json),
            new AddCommentHandler(new AddComment(reader, uow), authentication, json),
            new DeleteCommentHandler(new DeleteComment(uow), authentication, json),
            new GetArticleHandler(new GetArticle(reader), authentication, json),
            new ListArticlesHandler(new ListArticles(reader), authentication, json),
            new ListFeedHandler(new ListFeed(reader), authentication, json),
            new ListCommentsHandler(new ListComments(reader), authentication, json));
    }
}
