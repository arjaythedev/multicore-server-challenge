package conduit;

import conduit.wiring.Application;
import conduit.wiring.Config;

public final class Main {
    // The shutdown hook owns the process-scoped application lifetime.
    @SuppressWarnings("resource")
    static void main() {
        var application = Application.start(Config.from(System.getenv()));
        Runtime.getRuntime().addShutdownHook(new Thread(application::close, "conduit-shutdown"));
    }
}
