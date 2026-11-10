package com.challenge.conduit.ffm;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * High-Performance Native Memory Manager using Java Foreign Function & Memory (FFM) API.
 * Allocates and manages structured off-heap memory segments via Arena.ofShared(),
 * completely eliminating Java heap object allocations for:
 * - Queued request tasks (represented as native 32-byte struct slots)
 * - Raw UTF-8 parameter string bytes (slugs, tags, authors, usernames)
 * - Intermediate batch execution metadata and parameter arrays
 * - Multi-row result index matrices (eliminating ArrayList and collection allocations)
 */
public final class FfmMemoryArena implements AutoCloseable {

    // Native Slot Struct Layout (32 bytes per task, cache-line friendly, 8-byte aligned)
    public static final long SLOT_BYTES = 32;
    public static final long OFF_REQ_ID    = 0;  // int (4 bytes): Request context slot index
    public static final long OFF_KIND      = 4;  // int (4 bytes): Task kind enum
    public static final long OFF_VIEWER_ID = 8;  // long (8 bytes): Viewer user ID
    public static final long OFF_LIMIT     = 16; // int (4 bytes): Pagination limit
    public static final long OFF_OFFSET    = 20; // int (4 bytes): Pagination offset
    public static final long OFF_STR_OFF   = 24; // int (4 bytes): Offset into native string segment
    public static final long OFF_STR_LEN   = 28; // int (4 bytes): Byte length of string in native segment

    // Capacities (Powers of 2 for fast bitwise masking)
    public static final int TASK_CAPACITY = 65536;
    public static final int TASK_MASK = TASK_CAPACITY - 1;

    public static final int STRING_CAPACITY = 4 * 1024 * 1024; // 4 MB off-heap string arena
    public static final int STRING_MASK = STRING_CAPACITY - 1;

    private final Arena arena;
    private final MemorySegment stringSegment;
    private final AtomicInteger stringTail = new AtomicInteger(0);

    public FfmMemoryArena() {
        this.arena = Arena.ofShared();
        this.stringSegment = arena.allocate(STRING_CAPACITY, 1);
    }

    public MemorySegment allocateTaskSegment(int capacity) {
        return arena.allocate((long) capacity * SLOT_BYTES, 8);
    }

    /**
     * Stores string bytes into the native string segment without heap object allocation.
     * Returns the offset in the native string segment.
     */
    public int storeStringBytes(byte[] utf8Bytes, int offset, int len) {
        if (len <= 0) return 0;
        int targetOffset = stringTail.getAndAdd(len) & STRING_MASK;
        if (targetOffset + len <= STRING_CAPACITY) {
            MemorySegment.copy(MemorySegment.ofArray(utf8Bytes), offset, stringSegment, targetOffset, len);
        } else {
            // Segment boundary wrap
            int firstChunk = STRING_CAPACITY - targetOffset;
            MemorySegment.copy(MemorySegment.ofArray(utf8Bytes), offset, stringSegment, targetOffset, firstChunk);
            MemorySegment.copy(MemorySegment.ofArray(utf8Bytes), offset + firstChunk, stringSegment, 0, len - firstChunk);
        }
        return targetOffset;
    }

    public String readString(int strOff, int strLen) {
        if (strLen <= 0) return "";
        byte[] bytes = new byte[strLen];
        if (strOff + strLen <= STRING_CAPACITY) {
            MemorySegment.copy(stringSegment, ValueLayout.JAVA_BYTE, strOff, bytes, 0, strLen);
        } else {
            int firstChunk = STRING_CAPACITY - strOff;
            MemorySegment.copy(stringSegment, ValueLayout.JAVA_BYTE, strOff, bytes, 0, firstChunk);
            MemorySegment.copy(stringSegment, ValueLayout.JAVA_BYTE, 0, bytes, firstChunk, strLen - firstChunk);
        }
        return new String(bytes, StandardCharsets.UTF_8);
    }

    /**
     * Allocates a dedicated off-heap intermediate scratchpad segment for batch processing.
     */
    public MemorySegment allocateScratch(long bytes, long alignment) {
        return arena.allocate(bytes, alignment);
    }

    @Override
    public void close() {
        arena.close();
    }
}
