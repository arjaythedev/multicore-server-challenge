package com.challenge.conduit.ffm;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.concurrent.locks.Condition;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Ultra-High-Throughput Zero-Allocation Ring Buffer backed by FfmMemoryArena.
 * Owns a dedicated off-heap MemorySegment for tasks to guarantee absolute
 * memory isolation across queues and zero cross-queue slot collisions.
 */
public final class FfmBatchQueue {

    private final FfmMemoryArena memoryArena;
    private final MemorySegment queueSegment;
    private final int capacity;
    private final int mask;

    private final ReentrantLock lock = new ReentrantLock(false);
    private final Condition notEmpty = lock.newCondition();

    private int head = 0;
    private int tail = 0;

    public FfmBatchQueue(FfmMemoryArena memoryArena, int capacity) {
        this.memoryArena = memoryArena;
        this.capacity = capacity;
        this.mask = capacity - 1;
        this.queueSegment = memoryArena.allocateTaskSegment(capacity);
    }

    /**
     * Enqueues a task into this queue's native memory segment.
     * Guaranteed zero-heap allocation and published before tail advances.
     */
    public boolean offer(int reqId, int kind, long viewerId, int limit, int offset, int strOff, int strLen) {
        lock.lock();
        try {
            if (tail - head >= capacity) {
                return false; // Queue saturated (backpressure)
            }
            int slot = tail & mask;
            long base = (long) slot * FfmMemoryArena.SLOT_BYTES;
            queueSegment.set(ValueLayout.JAVA_INT, base + FfmMemoryArena.OFF_REQ_ID, reqId);
            queueSegment.set(ValueLayout.JAVA_INT, base + FfmMemoryArena.OFF_KIND, kind);
            queueSegment.set(ValueLayout.JAVA_LONG, base + FfmMemoryArena.OFF_VIEWER_ID, viewerId);
            queueSegment.set(ValueLayout.JAVA_INT, base + FfmMemoryArena.OFF_LIMIT, limit);
            queueSegment.set(ValueLayout.JAVA_INT, base + FfmMemoryArena.OFF_OFFSET, offset);
            queueSegment.set(ValueLayout.JAVA_INT, base + FfmMemoryArena.OFF_STR_OFF, strOff);
            queueSegment.set(ValueLayout.JAVA_INT, base + FfmMemoryArena.OFF_STR_LEN, strLen);
            tail++;
            notEmpty.signal();
            return true;
        } finally {
            lock.unlock();
        }
    }

    /**
     * Blocks until at least one task is available, then drains up to maxElements into targetSlots.
     * Guarantees zero heap allocation, zero CPU spin, and optimal batch coalescing under load.
     */
    public int takeAndDrain(int[] targetSlots, int maxElements) throws InterruptedException {
        lock.lock();
        try {
            while (tail == head) {
                notEmpty.await();
            }
            int available = tail - head;
            int count = Math.min(available, maxElements);
            for (int i = 0; i < count; i++) {
                targetSlots[i] = (head + i) & mask;
            }
            head += count;
            return count;
        } finally {
            lock.unlock();
        }
    }

    /**
     * Drains up to maxElements into the target array.
     * Waits up to waitNanos if the queue is currently empty.
     */
    public int drain(int[] targetSlots, int maxElements, long waitNanos) {
        lock.lock();
        try {
            if (tail == head && waitNanos > 0) {
                try {
                    notEmpty.awaitNanos(waitNanos);
                } catch (InterruptedException e) {
                    return 0;
                }
            }

            int available = tail - head;
            if (available <= 0) {
                return 0;
            }

            int count = Math.min(available, maxElements);
            for (int i = 0; i < count; i++) {
                targetSlots[i] = (head + i) & mask;
            }
            head += count;
            return count;
        } finally {
            lock.unlock();
        }
    }

    public int getReqId(int slot) {
        return queueSegment.get(ValueLayout.JAVA_INT, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_REQ_ID);
    }

    public int getKind(int slot) {
        return queueSegment.get(ValueLayout.JAVA_INT, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_KIND);
    }

    public long getViewerId(int slot) {
        return queueSegment.get(ValueLayout.JAVA_LONG, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_VIEWER_ID);
    }

    public int getLimit(int slot) {
        return queueSegment.get(ValueLayout.JAVA_INT, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_LIMIT);
    }

    public int getOffset(int slot) {
        return queueSegment.get(ValueLayout.JAVA_INT, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_OFFSET);
    }

    public int getStrOffset(int slot) {
        return queueSegment.get(ValueLayout.JAVA_INT, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_STR_OFF);
    }

    public int getStrLength(int slot) {
        return queueSegment.get(ValueLayout.JAVA_INT, (long) (slot & mask) * FfmMemoryArena.SLOT_BYTES + FfmMemoryArena.OFF_STR_LEN);
    }

    public int size() {
        lock.lock();
        try {
            return tail - head;
        } finally {
            lock.unlock();
        }
    }

    public boolean isEmpty() {
        lock.lock();
        try {
            return tail == head;
        } finally {
            lock.unlock();
        }
    }
}
