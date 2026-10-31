package com.challenge.conduit.endpoint;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.http.RequestContext;
import com.challenge.conduit.json.JsonReader;
import com.challenge.conduit.json.JsonStreamer;
import com.challenge.conduit.security.BcryptPool;
import com.challenge.conduit.security.Jwt;
import io.netty.buffer.ByteBuf;
import io.netty.handler.codec.http.HttpHeaderNames;
import io.netty.handler.codec.http.HttpResponseStatus;
import io.vertx.pgclient.PgException;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

import java.nio.charset.StandardCharsets;

/**
 * Single Responsibility: User & Authentication endpoints.
 * - POST /api/users (Register)
 * - POST /api/users/login (Login)
 * - GET  /api/user (Current user)
 * - PUT  /api/user (Update user)
 */
public final class UserEndpoint {

    public static void handleRegister(RequestContext req, PostgresClient pgClient, BcryptPool bcryptPool, Jwt jwt) {
        JsonReader.UserRegisterRequest r = JsonReader.parseUserRegister(req.request().content());
        if (!r.valid()) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid registration parameters");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        // Offload password hashing to BcryptPool via Disruptor
        bcryptPool.hashAsync(r.password().getBytes(StandardCharsets.UTF_8)).thenAccept(hash -> {
            pgClient.preparedQuery(
                    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
                    Tuple.of(r.username(), r.email(), hash)
            ).onComplete(ar -> {
                if (ar.succeeded()) {
                    Row row = ar.result().iterator().next();
                    long id = row.getLong("id");
                    String token = jwt.generateToken(id);

                    ByteBuf buf = req.alloc();
                    JsonStreamer.writeUser(buf, row, token);
                    req.send(HttpResponseStatus.CREATED, buf);
                } else {
                    Throwable cause = ar.cause();
                    System.err.println("User register database query failed: " + cause);
                    ByteBuf errBuf = req.alloc();
                    if (cause instanceof PgException pgEx && "23505".equals(pgEx.getCode())) {
                        JsonStreamer.writeError(errBuf, "Username or email is already taken");
                        req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
                    } else {
                        JsonStreamer.writeError(errBuf, "Registration failed");
                        req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
                    }
                }
            });
        }).exceptionally(ex -> {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Password hashing failure");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return null;
        });
    }

    public static void handleLogin(RequestContext req, PostgresClient pgClient, BcryptPool bcryptPool, Jwt jwt) {
        JsonReader.UserLoginRequest r = JsonReader.parseUserLogin(req.request().content());
        if (!r.valid()) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid email or password");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        pgClient.preparedQuery(
                "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
                Tuple.of(r.email())
        ).onComplete(ar -> {
            if (ar.succeeded() && ar.result().size() > 0) {
                Row row = ar.result().iterator().next();
                String hash = row.getString("password_hash");

                bcryptPool.verifyAsync(r.password().getBytes(StandardCharsets.UTF_8), hash).thenAccept(verified -> {
                    if (Boolean.TRUE.equals(verified)) {
                        long id = row.getLong("id");
                        String token = jwt.generateToken(id);

                        ByteBuf buf = req.alloc();
                        JsonStreamer.writeUser(buf, row, token);
                        req.send(HttpResponseStatus.OK, buf);
                    } else {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "Invalid email or password");
                        req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
                    }
                }).exceptionally(ex -> {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "Server overloaded, please retry");
                    req.send(HttpResponseStatus.SERVICE_UNAVAILABLE, errBuf);
                    return null;
                });
            } else {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Invalid email or password");
                req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            }
        });
    }

    public static void handleGetCurrent(RequestContext req, PostgresClient pgClient) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        pgClient.preparedQuery("SELECT email, username, bio, image FROM users WHERE id = $1", Tuple.of(req.viewerId()))
                .onComplete(ar -> {
                    if (ar.succeeded() && ar.result().size() > 0) {
                        Row row = ar.result().iterator().next();
                        String token = extractRawToken(req);
                        ByteBuf buf = req.alloc();
                        JsonStreamer.writeUser(buf, row, token);
                        req.send(HttpResponseStatus.OK, buf);
                    } else {
                        ByteBuf errBuf = req.alloc();
                        JsonStreamer.writeError(errBuf, "user not found");
                        req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
                    }
                });
    }

    public static void handleUpdate(RequestContext req, PostgresClient pgClient, BcryptPool bcryptPool) {
        if (req.viewerId() == 0) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "missing or invalid authorization token");
            req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
            return;
        }

        JsonReader.UserUpdateRequest r = JsonReader.parseUserUpdate(req.request().content());
        if (!r.valid()) {
            ByteBuf errBuf = req.alloc();
            JsonStreamer.writeError(errBuf, "Invalid user update request");
            req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
            return;
        }

        if (r.hasPassword()) {
            bcryptPool.hashAsync(r.password().getBytes(StandardCharsets.UTF_8)).thenAccept(hash -> {
                executeUpdate(req, pgClient, r, hash);
            }).exceptionally(ex -> {
                ByteBuf errBuf = req.alloc();
                JsonStreamer.writeError(errBuf, "Password hashing error");
                req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
                return null;
            });
        } else {
            executeUpdate(req, pgClient, r, null);
        }
    }

    private static void executeUpdate(RequestContext req, PostgresClient pgClient, JsonReader.UserUpdateRequest r, String passwordHash) {
        // UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
        //                  password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
        //  WHERE id = $1 RETURNING id, username, email, bio, image
        String emailParam = r.hasEmail() ? r.email() : null;
        String usernameParam = r.hasUsername() ? r.username() : null;
        String hashParam = passwordHash;
        String bioParam = r.hasBio() ? r.bio() : null;
        String imageParam = r.hasImage() ? r.image() : null;

        Tuple tuple = Tuple.of(req.viewerId(), emailParam, usernameParam, hashParam, bioParam, imageParam);

        pgClient.preparedQuery(
                "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " +
                "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " +
                "WHERE id = $1 RETURNING id, username, email, bio, image",
                tuple
        ).onComplete(ar -> {
            if (ar.succeeded()) {
                if (ar.result().size() > 0) {
                    Row row = ar.result().iterator().next();
                    String token = extractRawToken(req);
                    ByteBuf buf = req.alloc();
                    JsonStreamer.writeUser(buf, row, token);
                    req.send(HttpResponseStatus.OK, buf);
                } else {
                    ByteBuf errBuf = req.alloc();
                    JsonStreamer.writeError(errBuf, "User not found");
                    req.send(HttpResponseStatus.UNAUTHORIZED, errBuf);
                }
            } else {
                Throwable cause = ar.cause();
                ByteBuf errBuf = req.alloc();
                if (cause instanceof PgException pgEx && "23505".equals(pgEx.getCode())) {
                    JsonStreamer.writeError(errBuf, "Username or email is already taken");
                    req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
                } else {
                    JsonStreamer.writeError(errBuf, "Update failed");
                    req.send(HttpResponseStatus.UNPROCESSABLE_ENTITY, errBuf);
                }
            }
        });
    }

    private static String extractRawToken(RequestContext req) {
        String auth = req.request().headers().get(HttpHeaderNames.AUTHORIZATION);
        if (auth != null && auth.startsWith("Token ")) {
            return auth.substring(6).trim();
        }
        return "";
    }
}
