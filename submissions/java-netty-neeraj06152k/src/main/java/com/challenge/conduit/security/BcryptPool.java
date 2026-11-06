package com.challenge.conduit.security;

import at.favre.lib.crypto.bcrypt.BCrypt;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.*;

/**
 * Dedicated parallel Bcrypt worker pool using true competing workers.
 * Eliminates Disruptor multicast false wakeups and cache-line contention.
 */
public final class BcryptPool {

    private final ExecutorService executor;
    private final int cost;

    public BcryptPool(int workerThreads, int ringBufferSize, int cost) {
        int workers = Math.max(1, workerThreads);
        this.cost = cost;
        // True competing worker thread pool with safe backpressure:
        // Never executes on Netty event loop threads (uses AbortPolicy with clean CompletableFuture error)
        this.executor = new ThreadPoolExecutor(
                workers,
                workers,
                0L, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(ringBufferSize),
                new ThreadFactory() {
                    private int count = 0;
                    @Override
                    public Thread newThread(Runnable r) {
                        Thread t = new Thread(r, "bcrypt-worker-" + (++count));
                        t.setDaemon(true);
                        t.setPriority(Thread.MIN_PRIORITY);
                        return t;
                    }
                },
                new ThreadPoolExecutor.AbortPolicy()
        );
    }

    public CompletableFuture<Boolean> verifyAsync(byte[] password, String hash) {
        CompletableFuture<Boolean> future = new CompletableFuture<>();
        try {
            executor.execute(() -> {
                try {
                    byte[] hashBytes = hash.getBytes(StandardCharsets.UTF_8);
                    BCrypt.Result result = BCrypt.verifyer().verify(password, hashBytes);
                    future.complete(result.verified);
                } catch (Exception e) {
                    future.complete(false);
                }
            });
        } catch (RejectedExecutionException e) {
            future.completeExceptionally(e);
        }
        return future;
    }

    public CompletableFuture<String> hashAsync(byte[] password) {
        CompletableFuture<String> future = new CompletableFuture<>();
        try {
            executor.execute(() -> {
                try {
                    char[] passChars = new String(password, StandardCharsets.UTF_8).toCharArray();
                    String hashed = BCrypt.withDefaults().hashToString(cost, passChars);
                    future.complete(hashed);
                } catch (Exception e) {
                    future.completeExceptionally(e);
                }
            });
        } catch (RejectedExecutionException e) {
            future.completeExceptionally(e);
        }
        return future;
    }

    public void shutdown() {
        executor.shutdown();
    }
}
