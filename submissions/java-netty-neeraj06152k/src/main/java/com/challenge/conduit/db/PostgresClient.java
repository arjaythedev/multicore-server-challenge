package com.challenge.conduit.db;

import com.challenge.conduit.ffm.FfmBatchEngine;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.pgclient.PgPool;
import io.vertx.sqlclient.PoolOptions;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.Tuple;

/**
 * High-performance, reactive, pipelined PostgreSQL client using Eclipse Vert.x Reactive PG Client
 * backed by FfmBatchEngine for Foreign Function & Memory (FFM) native zero-heap SQL batching.
 */
public final class PostgresClient {
    private final Vertx vertx;
    private final PgPool pool;
    private final FfmBatchEngine ffmBatchEngine;

    public PostgresClient(DatabaseUrl dbUrl, int maxPoolSize, int pipeliningLimit, boolean cachePreparedStatements) {
        // Constrain Vert.x thread pools to prevent thread explosion on 8-vCPU host (shared with PG 18)
        VertxOptions vertxOptions = new VertxOptions()
                .setEventLoopPoolSize(2)
                .setWorkerPoolSize(2)
                .setInternalBlockingPoolSize(2);
        this.vertx = Vertx.vertx(vertxOptions);

        PgConnectOptions connectOptions = new PgConnectOptions()
                .setPort(dbUrl.port())
                .setHost(dbUrl.host())
                .setDatabase(dbUrl.database())
                .setUser(dbUrl.user())
                .setPassword(dbUrl.password())
                .setCachePreparedStatements(cachePreparedStatements)
                .setPipeliningLimit(pipeliningLimit)
                .addProperty("plan_cache_mode", "force_generic_plan")
                .addProperty("jit", "off")
                .addProperty("max_parallel_workers_per_gather", "0")
                .addProperty("work_mem", "32MB")
                .addProperty("random_page_cost", "1.1")
                .addProperty("effective_io_concurrency", "200");

        PoolOptions poolOptions = new PoolOptions()
                .setMaxSize(maxPoolSize)
                .setShared(true);

        this.pool = PgPool.pool(vertx, connectOptions, poolOptions);
        this.ffmBatchEngine = new FfmBatchEngine(this);
    }

    public Future<RowSet<Row>> query(String sql) {
        return pool.query(sql).execute();
    }

    public Future<RowSet<Row>> preparedQuery(String sql, Tuple tuple) {
        return pool.preparedQuery(sql).execute(tuple);
    }

    public Future<Void> checkConnection() {
        return pool.query("SELECT 1").execute().mapEmpty();
    }

    public PgPool pool() {
        return pool;
    }

    public FfmBatchEngine ffmBatchEngine() {
        return ffmBatchEngine;
    }

    public void close() {
        ffmBatchEngine.close();
        pool.close();
        vertx.close();
    }
}
