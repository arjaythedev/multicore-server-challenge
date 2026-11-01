package conduit.security;

import conduit.Exchange;
import conduit.ThreadPriority;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * bcrypt runs on a few dedicated threads, never on an event loop. A worker that picks up a job waits a short while
 * (like group commit) for more, up to a full batch ({@link BCrypt#lanes()}), then computes them interleaved
 * ({@link BCrypt#compute}), which costs much less CPU per hash than one at a time. Only one worker collects at a
 * time, so two workers never split what would have been one batch; the others compute meanwhile.
 *
 * <p>The workers run at a lower CPU priority (nice): when the box is saturated, Postgres and the event loops, which
 * serve hundreds of requests for every login, get the CPU first, and logins (a fraction of a percent of requests)
 * wait a little longer. When there is spare CPU, the priority makes no difference.
 */
public final class PasswordWorkers {
    /** A bcrypt job and what to do with the request once it is computed (on the worker thread). */
    private record Task(Exchange exchange, BCrypt.Job job, Runnable then) {
    }

    private static final LinkedBlockingQueue<Task> QUEUE = new LinkedBlockingQueue<>();
    private static final Object COLLECTING = new Object();
    private static long batchWindowNanos;

    private PasswordWorkers() {
    }

    /** Starts the workers; call after {@link BCrypt#start()}, which decides the batch size. */
    public static void start(int threads, int batchWindowMillis, int nice) {
        batchWindowNanos = TimeUnit.MILLISECONDS.toNanos(batchWindowMillis);
        for (int i = 0; i < threads; i++) {
            Thread worker = new Thread(() -> {
                if (nice != 0) ThreadPriority.setNice(nice);
                work();
            }, "bcrypt-" + i);
            worker.setDaemon(true);
            worker.start();
        }
    }

    /** Computes the job, then runs {@code then} on a worker thread. */
    public static void submit(Exchange exchange, BCrypt.Job job, Runnable then) {
        QUEUE.add(new Task(exchange, job, then));
    }

    private static void work() {
        Task[] batch = new Task[BCrypt.lanes()];
        BCrypt.Job[] jobs = new BCrypt.Job[BCrypt.lanes()];
        while (true) {
            int count = 0;
            try {
                synchronized (COLLECTING) {
                    count = take(QUEUE.take(), batch, count);
                    long deadline = System.nanoTime() + batchWindowNanos;
                    while (count < batch.length) {
                        Task more = QUEUE.poll(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
                        if (more == null) break;
                        count = take(more, batch, count);
                    }
                }
            } catch (InterruptedException e) {
                return;
            }
            for (int i = 0; i < count; i++) jobs[i] = batch[i].job;
            boolean computed = false;
            try {
                BCrypt.compute(jobs, count);
                computed = true;
            } catch (Throwable e) {                          // a worker must outlive any failure, or logins stop
                e.printStackTrace();
            }
            for (int i = 0; i < count; i++) {
                Task task = batch[i];
                batch[i] = null;
                jobs[i] = null;
                if (!computed) {
                    fail(task);
                    continue;
                }
                try {
                    task.then.run();
                } catch (Throwable e) {
                    e.printStackTrace();
                    fail(task);
                }
            }
        }
    }

    private static void fail(Task task) {
        try {
            task.exchange.respondError(500, "internal error");
        } catch (Throwable ignored) {
            // the response was already sent, or can't be: nothing more to do for this request
        }
    }

    /**
     * Adds a task to the batch, unless its client has already hung up: under overload, abandoned logins would
     * otherwise keep the workers busy with work nobody waits for.
     */
    private static int take(Task task, Task[] batch, int count) {
        if (task.exchange.clientIsGone()) return count;
        batch[count] = task;
        return count + 1;
    }
}
