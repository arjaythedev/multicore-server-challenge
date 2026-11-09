package conduit.adapters.outbound.postgres.jooq.tag;

import static conduit.generated.postgres.jooq.tables.Tags.TAGS;

import conduit.contracts.tag.TagReader;
import java.util.List;
import org.jooq.DSLContext;

public final class JooqTagReader implements TagReader {
    private final DSLContext sql;

    public JooqTagReader(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public List<String> listTags() {
        return sql.select(TAGS.NAME).from(TAGS).orderBy(TAGS.NAME).fetch(TAGS.NAME);
    }
}
