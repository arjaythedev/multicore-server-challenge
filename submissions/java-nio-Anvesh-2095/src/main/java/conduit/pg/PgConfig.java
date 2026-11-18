package conduit.pg;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

/** Connection settings from a postgres://user:password@host:port/database URL. */
public record PgConfig(String host, int port, String user, String password, String database) {
    public static PgConfig parse(String url) {
        URI u = URI.create(url);
        if (!"postgres".equals(u.getScheme()) && !"postgresql".equals(u.getScheme())) {
            throw new IllegalArgumentException("DATABASE_URL must start with postgres://");
        }
        String user = "postgres", password = "";
        String info = u.getRawUserInfo();
        if (info != null) {
            int c = info.indexOf(':');
            user = dec(c < 0 ? info : info.substring(0, c));
            if (c >= 0) password = dec(info.substring(c + 1));
        }
        String db = u.getRawPath() == null || u.getRawPath().length() <= 1 ? user : dec(u.getRawPath().substring(1));
        return new PgConfig(u.getHost() == null ? "127.0.0.1" : u.getHost(), u.getPort() < 0 ? 5432 : u.getPort(),
                user, password, db);
    }

    private static String dec(String s) {
        return URLDecoder.decode(s.replace("+", "%2B"), StandardCharsets.UTF_8);
    }
}
