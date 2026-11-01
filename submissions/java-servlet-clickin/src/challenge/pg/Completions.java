package challenge.pg;

/** Thread-safe handoff to the event loop which owns a unit. */
public interface Completions {
    void post(Unit unit);
}
