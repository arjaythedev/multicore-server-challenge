package challenge.pg;

import java.util.concurrent.atomic.AtomicReference;

/** Intrusive MPSC queue. Returned units are no longer retained by the queue. */
final class UnitQueue {
    private final Unit stub = new Unit(u -> {}, u -> {}, false, false);
    private final AtomicReference<Unit> tail = new AtomicReference<>(stub);
    private Unit head = stub;

    void offer(Unit unit) {
        unit.next = null;
        Unit previous = tail.getAndSet(unit);
        previous.next = unit;
    }

    Unit poll() {
        Unit current = head;
        Unit next = current.next;
        if (current == stub) {
            if (next == null) {
                return null;
            }
            head = current = next;
            next = current.next;
        }
        if (next != null) {
            head = next;
            return current;
        }
        if (current != tail.get()) {
            return null;
        }
        offer(stub);
        next = current.next;
        if (next == null) {
            return null;
        }
        head = next;
        return current;
    }

    boolean hasPending() {
        return head.next != null || head != tail.get();
    }
}
