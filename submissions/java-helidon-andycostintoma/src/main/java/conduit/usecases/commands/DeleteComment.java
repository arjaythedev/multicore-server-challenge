package conduit.usecases.commands;

import conduit.contracts.UnitOfWork;

public final class DeleteComment {
    private final UnitOfWork uow;

    public DeleteComment(UnitOfWork uow) {
        this.uow = uow;
    }

    public void execute(long viewer, String slug, long id) {
        uow.run(tx -> {
            var comment = tx.comments().comment(slug, id);
            comment.authorize(viewer);
            tx.comments().deleteComment(comment.id());
            return null;
        });
    }
}
