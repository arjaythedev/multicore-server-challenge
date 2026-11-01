package dev.mccue.vertx.realworld;

import io.vertx.core.Context;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.Vertx;
import io.vertx.core.http.HttpServerRequest;
import org.jspecify.annotations.Nullable;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/// bcrypt, cost 10. A hash is tens of milliseconds of CPU, which must never run on an event loop: it runs on a few
/// dedicated threads (so a burst of logins can't take every core from Postgres), four at a time (see Bcrypt), and
/// the request continues on its event loop when it's done.
///
/// A thread takes the oldest waiting hash, then waits up to the collection window for up to three more. Under load
/// there are always more waiting and nothing waits; when they're rare a login waits the window at most. A hash whose
/// client has hung up while it waited is dropped, not computed: it would be CPU taken from requests still being
/// waited for.
final class Passwords {
    private static final int COST = 10;

    private record Pending(Bcrypt.Job job, HttpServerRequest request, Context context, Promise<byte[]> promise) {
    }

    private final SecureRandom salts = new SecureRandom();
    private final LinkedBlockingQueue<Pending> queue = new LinkedBlockingQueue<>();
    private final long windowNanos;

    Passwords(int threads, long windowMillis) {
        this.windowNanos = TimeUnit.MILLISECONDS.toNanos(windowMillis);
        for (int i = 0; i < threads; i++) {
            Thread.ofPlatform().name("bcrypt-" + i).daemon().start(this::work);
        }
    }

    static boolean tooLong(String password) {
        return password.getBytes(StandardCharsets.UTF_8).length > 72;
    }

    Future<String> hash(String password, HttpServerRequest request) {
        var salt = new byte[16];
        salts.nextBytes(salt);
        return compute(new Bcrypt.Job(Bcrypt.key(password), salt, COST), request)
                .map(hash -> Bcrypt.encode("2a", COST, salt, hash));
    }

    /// Checks against the stored hash, at whatever cost it was made with.
    Future<Boolean> matches(String password, String hash, HttpServerRequest request) {
        if (tooLong(password)) {
            return Future.succeededFuture(false);
        }
        var job = Bcrypt.checkJob(password, hash);
        if (job == null) {
            return Future.succeededFuture(false);
        }
        return compute(job, request).map(computed -> Bcrypt.sameHash(hash, computed));
    }

    private Future<byte[]> compute(Bcrypt.Job job, HttpServerRequest request) {
        var context = Vertx.currentContext();
        var promise = Promise.<byte[]>promise();
        queue.add(new Pending(job, request, context, promise));
        return promise.future();
    }

    private void work() {
        var batch = new Pending[Bcrypt.LANES];
        var jobs = new Bcrypt.Job[Bcrypt.LANES];
        @Nullable Pending carried = null;
        while (true) {
            try {
                int count = 0;
                var first = carried != null ? carried : queue.take();
                carried = null;
                if (abandoned(first)) {
                    continue;
                }
                batch[count++] = first;
                long deadline = System.nanoTime() + windowNanos;
                while (count < Bcrypt.LANES) {
                    var next = queue.poll(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
                    if (next == null) {
                        break;
                    }
                    if (abandoned(next)) {
                        continue;
                    }
                    // A hash at another cost (an old stored hash) starts the next batch.
                    if (next.job().cost() != batch[0].job().cost()) {
                        carried = next;
                        break;
                    }
                    batch[count++] = next;
                }
                for (int i = 0; i < count; i++) {
                    jobs[i] = batch[i].job();
                }
                try {
                    var results = Bcrypt.compute(jobs, count);
                    for (int i = 0; i < count; i++) {
                        var pending = batch[i];
                        var result = results[i];
                        pending.context().runOnContext(v -> pending.promise().complete(result));
                    }
                }
                catch (RuntimeException e) {
                    for (int i = 0; i < count; i++) {
                        var pending = batch[i];
                        pending.context().runOnContext(v -> pending.promise().fail(e));
                    }
                }
            }
            catch (InterruptedException e) {
                return;
            }
        }
    }

    /// Whether the client hung up. The request is never answered; its connection is already gone.
    private static boolean abandoned(Pending pending) {
        return pending.request().response().closed();
    }
}
