package conduit.contracts.favorite;

public interface FavoriteStore {
    void add(long articleId, long viewer);

    void remove(long articleId, long viewer);
}
