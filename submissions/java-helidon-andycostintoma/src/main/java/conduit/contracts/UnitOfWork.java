package conduit.contracts;

import conduit.contracts.article.ArticleRepository;
import conduit.contracts.comment.CommentRepository;
import conduit.contracts.favorite.FavoriteStore;
import conduit.contracts.follow.FollowStore;
import conduit.contracts.user.UserRepository;
import java.util.function.Function;

public interface UnitOfWork {
    <T> T run(Function<Context, T> work);

    record Context(
        UserRepository users,
        ArticleRepository articles,
        CommentRepository comments,
        FollowStore follows,
        FavoriteStore favorites
    ) {
    }
}
