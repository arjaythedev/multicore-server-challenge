package conduit;

import at.favre.lib.crypto.bcrypt.BCrypt;
import jakarta.inject.Singleton;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/**
 * bcrypt cost 10 takes about 70 ms of CPU. Requests run on virtual threads whose carriers are one per core, so a few
 * logins at once would occupy every carrier and stall unrelated requests. Hashing runs on a small pool of platform
 * threads instead (half the cores), and the calling virtual thread parks until it is done.
 */
@Singleton
final class Passwords {

    /** bcrypt cost 10 for every new hash; verification uses the cost stored in the hash. */
    private static final int COST = 10;

    private final ExecutorService pool;

    Passwords() {
        int threads = Math.max(1, Runtime.getRuntime().availableProcessors() / 2);
        this.pool = Executors.newFixedThreadPool(threads, runnable -> {
            Thread thread = new Thread(runnable, "bcrypt");
            thread.setDaemon(true);
            return thread;
        });
    }

    String hash(String password) {
        return await(pool.submit(() ->
                BCrypt.withDefaults().hashToString(COST, Body.hashable(password).toCharArray())));
    }

    /** A password bcrypt can't take (over 72 bytes) can't match a hash made from one that it could. */
    boolean verify(String password, String hash) {
        if (Body.isNotHashable(password)) {
            return false;
        }
        return await(pool.submit(() -> BCrypt.verifyer().verify(password.toCharArray(), hash).verified));
    }

    private static <T> T await(Future<T> future) {
        try {
            return future.get();
        } catch (ExecutionException ex) {
            if (ex.getCause() instanceof RuntimeException runtime) {
                throw runtime;
            }
            throw new IllegalStateException(ex.getCause());
        } catch (InterruptedException ex) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(ex);
        }
    }
}
