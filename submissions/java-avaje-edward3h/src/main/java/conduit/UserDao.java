package conduit;

import org.ethelred.kiwiproc.annotation.DAO;
import org.ethelred.kiwiproc.annotation.SqlQuery;
import org.ethelred.kiwiproc.annotation.SqlUpdate;
import org.jspecify.annotations.Nullable;

/** Users, profiles and follows. */
@DAO
public interface UserDao {

    record UserRow(long id, String username, String email, @Nullable String bio, @Nullable String image) {
    }

    record LoginRow(long id, String username, String email, @Nullable String bio, @Nullable String image,
            String passwordHash) {
    }

    record ProfileRow(long id, String username, @Nullable String bio, @Nullable String image, boolean following) {
    }

    record FolloweeRow(long id, String username, @Nullable String bio, @Nullable String image) {
    }

    @SqlQuery("""
            INSERT INTO users (username, email, password_hash) VALUES (:username, :email, :hash)
            RETURNING id, username, email, bio, image""")
    UserRow insert(String username, String email, String hash);

    @SqlQuery("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = :email")
    @Nullable
    LoginRow findByEmail(String email);

    @SqlQuery("SELECT id, username, email, bio, image FROM users WHERE id = :id")
    @Nullable
    UserRow findById(long id);

    @SqlQuery("""
            UPDATE users SET email = COALESCE(:email, email), username = COALESCE(:username, username),
                             password_hash = COALESCE(:hash, password_hash), bio = COALESCE(:bio, bio), image = COALESCE(:image, image)
             WHERE id = :id
            RETURNING id, username, email, bio, image""")
    @Nullable
    UserRow update(long id, @Nullable String email, @Nullable String username, @Nullable String hash,
            @Nullable String bio, @Nullable String image);

    @SqlQuery("""
            SELECT u.id, u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = :viewer AND fo.followee_id = u.id) AS following
              FROM users u WHERE u.username = :username""")
    @Nullable
    ProfileRow profile(long viewer, String username);

    @SqlQuery("SELECT id, username, bio, image FROM users WHERE username = :username")
    @Nullable
    FolloweeRow findByUsername(String username);

    @SqlUpdate("INSERT INTO follows (follower_id, followee_id) VALUES (:viewer, :followee) ON CONFLICT DO NOTHING")
    void follow(long viewer, long followee);

    @SqlUpdate("DELETE FROM follows WHERE follower_id = :viewer AND followee_id = :followee")
    void unfollow(long viewer, long followee);
}
