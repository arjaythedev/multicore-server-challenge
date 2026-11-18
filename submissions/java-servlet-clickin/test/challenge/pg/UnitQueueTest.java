package challenge.pg;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

public final class UnitQueueTest {
    public static void main(String[] args) throws Exception {
        UnitQueue queue = new UnitQueue();
        int producers = 4;
        int count = 4000;
        CountDownLatch start = new CountDownLatch(1);
        AtomicInteger completed = new AtomicInteger();
        Thread[] threads = new Thread[producers];
        for (int i = 0; i < producers; i++) {
            threads[i] = new Thread(() -> {
                try {
                    start.await();
                } catch (InterruptedException e) {
                    throw new AssertionError(e);
                }
                for (int j = 0; j < count; j++) {
                    queue.offer(new Unit(u -> {}, u -> completed.incrementAndGet(), false,
                            false));
                }
            });
            threads[i].start();
        }
        start.countDown();
        while (completed.get() < producers * count) {
            Unit u = queue.poll();
            if (u == null) {
                Thread.onSpinWait();
            } else {
                u.callback.done(u);
            }
        }
        for (Thread t : threads) {
            t.join();
        }
        Unit reusable = new Unit(u -> {}, u -> {}, false, false);
        for (int i = 0; i < 1000; i++) {
            queue.offer(reusable);
            if (queue.poll() != reusable) {
                throw new AssertionError("recycle");
            }
        }
        if (queue.poll() != null) {
            throw new AssertionError("queue not empty");
        }
    }
}
