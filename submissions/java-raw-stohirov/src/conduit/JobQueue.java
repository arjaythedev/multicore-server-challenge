package conduit;

import java.util.ArrayDeque;
import java.util.List;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

/**
 * A queue whose consumer takes batches: it waits for the first job, then until {@code want} jobs are waiting or the
 * oldest has waited the window, and takes up to {@code max}. Producers only wake the consumer when its batch is
 * ready (or on the first job, which starts the window).
 */
final class JobQueue {
    private final ReentrantLock lock = new ReentrantLock();
    private final Condition ready = lock.newCondition();
    private final ArrayDeque<Job> q = new ArrayDeque<>();
    private int want = 1;

    void push(Job j) {
        j.t0 = System.nanoTime();
        lock.lock();
        try {
            q.addLast(j);
            int n = q.size();
            if (n == 1 || n >= want) ready.signal();
        } finally {
            lock.unlock();
        }
    }

    void pushAll(List<Job> js) {
        if (js.isEmpty()) return;
        long now = System.nanoTime();
        lock.lock();
        try {
            int before = q.size();
            for (Job j : js) {
                j.t0 = now;
                q.addLast(j);
            }
            if (before == 0 || q.size() >= want) ready.signal();
        } finally {
            lock.unlock();
        }
    }

    void take(int want, long windowNanos, int max, List<Job> out) throws InterruptedException {
        lock.lock();
        try {
            this.want = Math.max(1, want);
            while (q.isEmpty()) ready.await();
            while (q.size() < want) {
                long left = q.peekFirst().t0 + windowNanos - System.nanoTime();
                if (left <= 0) break;
                ready.awaitNanos(left);
            }
            for (int i = 0; i < max && !q.isEmpty(); i++) out.add(q.pollFirst());
            this.want = Integer.MAX_VALUE; // nobody is gathering until the next take
        } finally {
            lock.unlock();
        }
    }

    /** Takes whatever is waiting (at least one job, waiting at most timeout for it); empty on timeout. */
    void takeAny(int max, long timeoutNanos, List<Job> out) throws InterruptedException {
        lock.lock();
        try {
            this.want = 1;
            long left = timeoutNanos;
            while (q.isEmpty()) {
                if (left <= 0) return;
                left = ready.awaitNanos(left);
            }
            for (int i = 0; i < max && !q.isEmpty(); i++) out.add(q.pollFirst());
        } finally {
            lock.unlock();
        }
    }
}
