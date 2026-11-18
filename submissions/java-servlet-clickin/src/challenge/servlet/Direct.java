package challenge.servlet;

import java.util.Arrays;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Supplier;

import challenge.JsonWriter;
import jakarta.servlet.ServletRequest;

/**
 * Everything this container offers beyond the Servlet API, in one place. The
 * standard getters build Strings; these read the request where it already is
 * (offsets into the connection's read buffer) and write the response body
 * straight into its buffer. Valid only while the request is being handled, like
 * the request itself.
 *
 * <p>A servlet that uses only the standard API never needs this; {@link #of} is
 * the one cast to container internals.
 */
public interface Direct {
    /** The container request behind {@code request} and any wrappers around it. */
    static Direct of(ServletRequest request) {
        return Request.of(request);
    }

    /** The read buffer; every offset below indexes into it. */
    byte[] bytes();

    int pathOffset();

    int pathLength();

    /** Query string after '?', or -1 when there is none. */
    int queryOffset();

    int queryLength();

    int bodyOffset();

    int bodyLength();

    /** Authorization header value, or -1 when there is none. */
    int authorizationOffset();

    int authorizationLength();

    /** More than one Authorization header was sent (only the last is recorded). */
    boolean multipleAuthorization();

    /**
     * Path segments as split by the container's mapper, or -1 for a path it
     * rejects (empty segment, too deep).
     */
    int segmentCount();

    int segmentStart(int index);

    int segmentEnd(int index);

    /** Segment {@code index} is exactly {@code word} (ASCII). */
    default boolean segmentIs(int index, String word) {
        int start = segmentStart(index);
        int length = segmentEnd(index) - start;
        if (length != word.length()) {
            return false;
        }
        byte[] b = bytes();
        for (int i = 0; i < length; i++) {
            if (b[start + i] != word.charAt(i)) {
                return false;
            }
        }
        return true;
    }

    /**
     * An object pooled with this request across exchanges on the connection's
     * loop, for per-request state.
     */
    Object slot();

    void slot(Object value);

    /**
     * The value of {@code key} for the thread this request runs on, created on
     * first use (see {@link Local}).
     */
    <T> T local(Local<T> key);

    /** The response body buffer. */
    JsonWriter output();

    /**
     * A per-event-loop value: one instance for each loop thread, shared by
     * every request that loop handles. For objects that are not thread-safe but
     * too big to keep per request (a Mac, scratch buffers).
     */
    final class Local<T> {
        private static final AtomicInteger COUNT = new AtomicInteger();
        final int index = COUNT.getAndIncrement();
        final Supplier<T> initial;

        public Local(Supplier<T> initial) {
            this.initial = initial;
        }
    }

    /** Storage for {@link Local} values, owned by one thread. */
    final class Locals {
        private Object[] values = new Object[4];

        @SuppressWarnings("unchecked")
        public <T> T get(Local<T> key) {
            if (key.index >= values.length) {
                values = Arrays.copyOf(values,
                        Math.max(key.index + 1, values.length * 2));
            }
            Object v = values[key.index];
            if (v == null) {
                values[key.index] = v = key.initial.get();
            }
            return (T) v;
        }
    }
}
