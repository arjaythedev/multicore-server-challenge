package challenge;

import java.util.Arrays;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.locks.ReentrantLock;

import challenge.pg.Unit;

/** CPU-bound password work runs only on these platform threads. */
public final class BcryptPool implements AutoCloseable {
    private static final AtomicBoolean priorityWarning = new AtomicBoolean();
    private final int nice = Integer.parseInt(System.getenv().getOrDefault("BCRYPT_NICE", "5"));
    private final ConcurrentLinkedQueue<Unit> queue = new ConcurrentLinkedQueue<>();
    private final Semaphore available = new Semaphore(0);
    private final AtomicInteger publishers = new AtomicInteger();
    private final Thread[] threads;
    private final int lanes = Integer.parseInt(System.getenv().getOrDefault("BCRYPT_LANES", "4"));
    private volatile boolean closed;

    public BcryptPool() {
        this(Integer.parseInt(System.getenv().getOrDefault("BCRYPT_THREADS", "4")));
    }

    public BcryptPool(int count) {
        if (lanes < 1 || lanes > 4) {
            throw new IllegalArgumentException("BCRYPT_LANES must be between 1 and 4");
        }
        if (count < 1) {
            throw new IllegalArgumentException("BCRYPT_THREADS must be positive");
        }
        threads = new Thread[count];
        for (int i = 0; i < count; i++) {
            threads[i] = new Thread(this::run, "bcrypt-" + i);
            threads[i].start();
        }
    }

    /** Set bcryptPassword and, for verification, bcryptHash before submitting. */
    public void submit(Unit unit) {
        publishers.incrementAndGet();
        try {
            if (closed) {
                throw new IllegalStateException("pool is closed");
            }
            queue.add(unit);
            available.release();
        } finally {
            publishers.decrementAndGet();
            if (closed) {
                available.release(threads.length);
            }
        }
    }

    private final long gatherNanos = Long.parseLong(System.getenv().getOrDefault("BCRYPT_GATHER_MS", "400")) * 1_000_000L;
    private final ReentrantLock gathering = new ReentrantLock();

    private boolean acquireUntil(long deadline) {
        long left = deadline - System.nanoTime();
        if (left <= 0) {
            return available.tryAcquire();
        }
        try {
            return available.tryAcquire(left, TimeUnit.NANOSECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return false;
        }
    }

    private void run() {
        try {
            int error = Sys.niceCurrentThread(nice);
            if (error != 0 && priorityWarning.compareAndSet(false, true)) {
                System.err.println("bcrypt setpriority failed: errno " + error);
            }
        } catch (Throwable e) {
            if (priorityWarning.compareAndSet(false, true)) {
                System.err.println("bcrypt setpriority failed: " + e);
            }
        }
        BCrypt bcrypt = new BCrypt();
        for (; ; ) {
            Unit[] jobs = new Unit[lanes];
            int count = 0;
            // one thread gathers at a time, the others hash: with every thread gathering on its own, ~30 logins/s
            // spread one per thread and a 4-lane loop mostly ran a lone hash (~1.8x the CPU of a full set on EPYC)
            gathering.lock();
            try {
                available.acquireUninterruptibly();
                Unit unit = queue.poll();
                if (unit == null) {
                    if (closed && publishers.get() == 0 && queue.isEmpty()) {
                        available.release();
                        return;
                    }
                    continue;
                }
                jobs[count++] = unit;
                // wait up to BCRYPT_GATHER_MS for a full set: lanes interleave in one loop, so a full set costs
                // little more CPU than a lone hash
                long gatherEnd = System.nanoTime() + gatherNanos;
                while (count < lanes && acquireUntil(gatherEnd)) {
                    Unit next = queue.poll();
                    if (next != null) {
                        jobs[count++] = next;
                    } else {
                        if (closed) {
                            available.release();
                        }
                        break;
                    }
                }
            } finally {
                gathering.unlock();
            }
            Unit[] valid = new Unit[count];
            String[] passwords = new String[count];
            String[] salts = new String[count];
            int size = 0;
            for (int i = 0; i < count; i++) {
                Unit job = jobs[i];
                try {
                    if (job.bcryptHash != null) {
                        job.bcryptMatches = false;
                    }
                    String salt = job.bcryptHash == null ? bcrypt.newSalt() : job.bcryptHash;
                    if (job.bcryptHash != null && salt.length() != 60) {
                        continue;
                    }
                    BCrypt.validate(job.bcryptPassword, salt);
                    valid[size] = job;
                    passwords[size] = job.bcryptPassword;
                    salts[size++] = salt;
                } catch (IllegalArgumentException e) {
                    if (job.bcryptHash == null) {
                        job.errorMessage = e.toString();
                    }
                } catch (RuntimeException e) {
                    job.errorMessage = e.toString();
                }
            }
            if (size > 0) {
                try {
                    String[] results = bcrypt.calculateBatch(Arrays.copyOf(passwords, size), Arrays.copyOf(salts, size));
                    for (int i = 0; i < size; i++) {
                        if (valid[i].bcryptHash == null) {
                            valid[i].bcryptHash = results[i];
                        } else {
                            valid[i].bcryptMatches = bcrypt.matches(results[i], valid[i].bcryptHash);
                        }
                    }
                } catch (RuntimeException e) {
                    for (int i = 0; i < size; i++) {
                        valid[i].errorMessage = e.toString();
                    }
                }
            }
            for (int i = 0; i < count; i++) {
                jobs[i].owner.post(jobs[i]);
            }
        }
    }

    @Override
    public void close() {
        closed = true;
        available.release(threads.length);
    }
}
