package conduit.adapters.outbound.postgres.jooq.favorite;

import static conduit.generated.postgres.jooq.tables.Favorites.FAVORITES;

import conduit.contracts.favorite.FavoriteStore;
import org.jooq.DSLContext;

public final class JooqFavoriteStore implements FavoriteStore {
    private final DSLContext sql;

    public JooqFavoriteStore(DSLContext sql) {
        this.sql = sql;
    }

    @Override
    public void add(long articleId, long viewer) {
        sql.insertInto(FAVORITES, FAVORITES.USER_ID, FAVORITES.ARTICLE_ID).values(viewer, articleId)
            .onConflictDoNothing().execute();
    }

    @Override
    public void remove(long articleId, long viewer) {
        sql.deleteFrom(FAVORITES)
            .where(FAVORITES.USER_ID.eq(viewer).and(FAVORITES.ARTICLE_ID.eq(articleId))).execute();
    }
}
