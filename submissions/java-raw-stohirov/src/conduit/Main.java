package conduit;

/** Reads DATABASE_URL, JWT_SECRET, HOST and PORT (plus optional tuning variables) and starts everything. */
public final class Main {
    private static int env(String k, int def) {
        String v = System.getenv(k);
        return v == null || v.isBlank() ? def : Integer.parseInt(v.trim());
    }

    private static String env(String k, String def) {
        String v = System.getenv(k);
        return v == null || v.isBlank() ? def : v;
    }

    public static void main(String[] args) throws Exception {
        int cores = Runtime.getRuntime().availableProcessors();
        Jwt.init(env("JWT_SECRET", "multicore-server-challenge"));
        Pg.Config cfg = Pg.Config.parse(env("DATABASE_URL", "postgres://conduit:conduit@127.0.0.1:5432/conduit"));
        Lanes.Settings s = new Lanes.Settings(cfg,
                env("READ_MIN", 4096),
                env("READ_WINDOW_US", 40_000) * 1000L,
                env("READ_BATCH", 4096),
                env("WRITE_BATCH", 256),
                env("WRITE_WINDOW_US", 3_000) * 1000L,
                env("FEED_CONN", 1) != 0);
        Lanes.start(s, env("READ_LANES", cores), env("WRITE_LANES", 1), env("BCRYPT_THREADS", 3),
                env("BCRYPT_LANES", 0), env("BCRYPT_WINDOW_MS", 400) * 1_000_000L);
        Http.start(env("HOST", "0.0.0.0"), env("PORT", 3000), env("IO_THREADS", Math.max(1, cores / 2)));
        System.out.println("listening on " + env("HOST", "0.0.0.0") + ":" + env("PORT", 3000));
    }
}
