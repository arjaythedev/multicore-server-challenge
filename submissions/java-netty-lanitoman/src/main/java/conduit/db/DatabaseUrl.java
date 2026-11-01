package conduit.db;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

/** postgres://user:password@host:port/database */
public record DatabaseUrl(String host, int port, String user, String password, String database) {

    public static DatabaseUrl parse(String url) {
        URI uri = URI.create(url);
        String user = "postgres";
        String password = "";
        if (uri.getRawUserInfo() != null) {
            String[] parts = uri.getRawUserInfo().split(":", 2);
            user = decode(parts[0]);
            if (parts.length > 1) password = decode(parts[1]);
        }
        String host = uri.getHost() != null ? uri.getHost() : "127.0.0.1";
        int port = uri.getPort() > 0 ? uri.getPort() : 5432;
        String path = uri.getRawPath() == null ? "" : uri.getRawPath();
        String database = path.startsWith("/") ? decode(path.substring(1)) : decode(path);
        if (database.isEmpty()) database = user;
        return new DatabaseUrl(host, port, user, password, database);
    }

    private static String decode(String value) {
        return URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8);
    }
}
