package conduit.adapters.outbound.postgres.jooq.comment;

import static conduit.generated.postgres.jooq.tables.Comments.COMMENTS;
import static conduit.generated.postgres.jooq.tables.Users.USERS;

import conduit.contracts.article.readmodel.CommentView;
import conduit.contracts.article.readmodel.ProfileView;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.DateTimeFormatterBuilder;
import java.time.temporal.ChronoUnit;
import org.jooq.Record;

public final class CommentMapper {
    private static final DateTimeFormatter TIMESTAMP = new DateTimeFormatterBuilder()
        .appendInstant(3).toFormatter();

    private CommentMapper() {
    }

    public static CommentView toView(Record row) {
        return new CommentView(row.get(COMMENTS.ID), timestamp(row.get(COMMENTS.CREATED_AT)),
            timestamp(row.get(COMMENTS.UPDATED_AT)), row.get(COMMENTS.BODY),
            new ProfileView(row.get(USERS.USERNAME), row.get(USERS.BIO), row.get(USERS.IMAGE),
                row.get("following", Boolean.class)));
    }

    private static String timestamp(OffsetDateTime time) {
        return TIMESTAMP.format(time.toInstant().truncatedTo(ChronoUnit.MILLIS));
    }
}
