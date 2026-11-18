package challenge.http;

import challenge.http.Loop.Conn;
import challenge.http.Loop.Pending;

public final class PendingTest {
    public static void main(String[] args) {
        Pending queue = new Pending();
        Conn first = new Conn(1);
        Conn second = new Conn(2);
        Conn third = new Conn(3);
        queue.add(first);
        queue.add(second);
        queue.add(first);
        if (queue.poll() != first) {
            throw new AssertionError("first connection");
        }
        queue.add(first);
        queue.add(third);
        if (queue.poll() != second
                || queue.poll() != first
                || queue.poll() != third
                || queue.poll() != null
                || !queue.isEmpty()) {
            throw new AssertionError("FIFO, deduplication, or requeue");
        }
        queue.add(second);
        if (queue.poll() != second || !queue.isEmpty()) {
            throw new AssertionError("reuse after empty");
        }
    }
}
