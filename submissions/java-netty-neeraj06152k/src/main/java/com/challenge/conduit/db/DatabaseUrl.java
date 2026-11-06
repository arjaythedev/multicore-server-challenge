package com.challenge.conduit.db;

import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

/**
 * High-performance parser for PostgreSQL connection URLs.
 * Example: postgres://conduit:conduit@127.0.0.1:5432/conduit
 */
public record DatabaseUrl(String host, int port, String user, String password, String database) {

    public static DatabaseUrl parse(String urlString) {
        try {
            URI uri = URI.create(urlString);
            String host = uri.getHost() != null ? uri.getHost() : "127.0.0.1";
            int port = uri.getPort() != -1 ? uri.getPort() : 5432;
            String path = uri.getPath();
            String database = (path != null && path.length() > 1) ? path.substring(1) : "conduit";

            String user = "conduit";
            String password = "";
            String userInfo = uri.getUserInfo();
            if (userInfo != null) {
                int colon = userInfo.indexOf(':');
                if (colon != -1) {
                    user = URLDecoder.decode(userInfo.substring(0, colon), StandardCharsets.UTF_8);
                    password = URLDecoder.decode(userInfo.substring(colon + 1), StandardCharsets.UTF_8);
                } else {
                    user = URLDecoder.decode(userInfo, StandardCharsets.UTF_8);
                }
            }
            return new DatabaseUrl(host, port, user, password, database);
        } catch (Exception e) {
            throw new IllegalArgumentException("Invalid DATABASE_URL: " + urlString, e);
        }
    }
}
