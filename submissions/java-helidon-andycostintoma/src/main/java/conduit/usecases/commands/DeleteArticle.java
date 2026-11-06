package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;

public final class DeleteArticle {
    private final UnitOfWork uow;

    public DeleteArticle(UnitOfWork uow) {
        this.uow = uow;
    }

    public void execute(long viewer, String slug) {
        uow.run(tx -> {
            var article = tx.articles().article(slug);
            article.authorize(viewer);
            tx.articles().deleteArticle(article.id());
            return null;
        });
    }
}
