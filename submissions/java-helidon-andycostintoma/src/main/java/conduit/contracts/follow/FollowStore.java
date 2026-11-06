package conduit.contracts.follow;

public interface FollowStore {
    void add(long follower, long followee);

    void remove(long follower, long followee);
}
