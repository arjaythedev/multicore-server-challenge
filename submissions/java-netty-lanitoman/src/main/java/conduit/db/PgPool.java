package conduit.db;

import io.netty.channel.EventLoopGroup;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicInteger;

/** A fixed set of connections; each query goes to the connection with the fewest queries pending. */
public final class PgPool {
    private final PgConnection[] connections;
    private final AtomicInteger rotation = new AtomicInteger();

    private PgPool(PgConnection[] connections) {
        this.connections = connections;
    }

    public static PgPool open(EventLoopGroup group, DatabaseUrl url, String options, int size, String name) {
        @SuppressWarnings("unchecked")
        CompletableFuture<PgConnection>[] opening = new CompletableFuture[size];
        for (int i = 0; i < size; i++) opening[i] = PgConnection.open(group, url, options, name + "-" + i);
        PgConnection[] connections = new PgConnection[size];
        for (int i = 0; i < size; i++) connections[i] = opening[i].join();
        return new PgPool(connections);
    }

    public PgConnection[] connections() {
        return connections;
    }

    public void submit(PgQuery query) {
        leastBusy().submit(query);
    }

    /** The usable connection with the fewest pending queries; ties go round robin so the load spreads evenly. */
    private PgConnection leastBusy() {
        int start = Math.floorMod(rotation.getAndIncrement(), connections.length);
        PgConnection best = connections[start];
        int bestPending = best.isUsable() ? best.pending() : Integer.MAX_VALUE;
        for (int i = 1; i < connections.length && bestPending > 0; i++) {
            PgConnection candidate = connections[(start + i) % connections.length];
            if (!candidate.isUsable()) continue;
            int candidatePending = candidate.pending();
            if (candidatePending < bestPending) {
                best = candidate;
                bestPending = candidatePending;
            }
        }
        return best;                      // if none is usable, the query fails at once with "connection lost"
    }
}
