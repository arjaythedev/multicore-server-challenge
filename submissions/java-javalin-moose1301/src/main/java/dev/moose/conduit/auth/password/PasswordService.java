package dev.moose.conduit.auth.password;

import dev.moose.conduit.config.ConduitConfig;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Executor;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

public class PasswordService {

    private static final Logger LOGGER = LoggerFactory.getLogger(PasswordService.class);
    private static final String SEED_PASSWORD = "password123";
    private static final String SEED_HASH = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

    private record PendingHash(Bcrypt.Job job, CompletableFuture<byte[]> future) {
    }

    private final SecureRandom random = new SecureRandom();
    private final LinkedBlockingQueue<PendingHash> queue = new LinkedBlockingQueue<>();
    private final long windowNanos;
    private final Executor responder;

    public PasswordService(ConduitConfig config, Executor responder) {
        this.windowNanos = TimeUnit.MILLISECONDS.toNanos(config.getBcryptWindowMillis());
        this.responder = responder;

        for (int i = 0; i < config.getBcryptThreads(); i++) {
            Thread.ofPlatform().name("bcrypt-" + i).daemon().start(() -> {
                lowerPriority(config.getBcryptNice());
                this.work();
            });
        }
    }

    public CompletableFuture<String> hash(String password) {
        final byte[] salt = new byte[16];
        this.random.nextBytes(salt);
        return this.submit(Bcrypt.hashJob(password, salt)).thenApply(hash -> Bcrypt.encode(salt, hash));
    }

    public CompletableFuture<Boolean> matches(String password, String storedHash) {
        if (Bcrypt.tooLong(password)) {
            return CompletableFuture.completedFuture(false);
        }

        final Bcrypt.Job job = Bcrypt.checkJob(password, storedHash);
        if (job == null) {
            return CompletableFuture.completedFuture(false);
        }

        return this.submit(job).thenApply(computed -> Bcrypt.matches(storedHash, computed));
    }

    public static void selfCheck() {
        final Bcrypt.Job job = Bcrypt.checkJob(SEED_PASSWORD, SEED_HASH);
        if (job == null) {
            throw new IllegalStateException("bcrypt self-check failed");
        }

        final long singleStart = System.nanoTime();
        final byte[][] single = Bcrypt.compute(new Bcrypt.Job[]{job}, 1);
        final long batchStart = System.nanoTime();
        final byte[][] batch = Bcrypt.compute(new Bcrypt.Job[]{job, job, job, job}, Bcrypt.LANES);
        final long batchEnd = System.nanoTime();

        if (!Bcrypt.matches(SEED_HASH, single[0])) {
            throw new IllegalStateException("bcrypt self-check failed");
        }
        for (final byte[] lane : batch) {
            if (!Bcrypt.matches(SEED_HASH, lane)) {
                throw new IllegalStateException("bcrypt four-lane self-check failed");
            }
        }
        for (final byte[] lane : Bcrypt.compute(new Bcrypt.Job[]{job, job}, 2)) {
            if (!Bcrypt.matches(SEED_HASH, lane)) {
                throw new IllegalStateException("bcrypt two-lane self-check failed");
            }
        }

        LOGGER.info("bcrypt self-check ok: one hash {} ms, four hashes {} ms (cold)",
                (batchStart - singleStart) / 1_000_000, (batchEnd - batchStart) / 1_000_000);
    }

    private CompletableFuture<byte[]> submit(Bcrypt.Job job) {
        final CompletableFuture<byte[]> future = new CompletableFuture<>();
        this.queue.add(new PendingHash(job, future));
        return future;
    }

    private void work() {
        final PendingHash[] batch = new PendingHash[Bcrypt.LANES];
        final Bcrypt.Job[] jobs = new Bcrypt.Job[Bcrypt.LANES];
        PendingHash carried = null;

        while (true) {
            try {
                final PendingHash first = carried != null ? carried : this.queue.take();
                carried = null;
                int count = 0;
                batch[count++] = first;

                final long deadline = System.nanoTime() + this.windowNanos;
                while (count < Bcrypt.LANES) {
                    final PendingHash next = this.queue.poll(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
                    if (next == null) {
                        break;
                    }
                    if (next.job().cost() != first.job().cost()) {
                        carried = next;
                        break;
                    }
                    batch[count++] = next;
                }

                for (int i = 0; i < count; i++) {
                    jobs[i] = batch[i].job();
                }
                this.complete(batch, jobs, count);
            } catch (InterruptedException exception) {
                return;
            }
        }
    }

    private void complete(PendingHash[] batch, Bcrypt.Job[] jobs, int count) {
        try {
            final byte[][] results = Bcrypt.compute(jobs, count);
            for (int i = 0; i < count; i++) {
                final PendingHash pending = batch[i];
                final byte[] result = results[i];
                this.responder.execute(() -> pending.future().complete(result));
            }
        } catch (RuntimeException exception) {
            for (int i = 0; i < count; i++) {
                final PendingHash pending = batch[i];
                this.responder.execute(() -> pending.future().completeExceptionally(exception));
            }
        }
    }

    private static void lowerPriority(int niceness) {
        if (niceness <= 0) {
            return;
        }

        try {
            final String threadId = Files.readSymbolicLink(Path.of("/proc/thread-self")).getFileName().toString();
            new ProcessBuilder("renice", "-n", Integer.toString(niceness), "-p", threadId)
                    .redirectErrorStream(true)
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .start()
                    .waitFor();
        } catch (IOException | InterruptedException | RuntimeException exception) {
            LOGGER.warn("Could not lower bcrypt thread priority: {}", exception.toString());
        }
    }

}
