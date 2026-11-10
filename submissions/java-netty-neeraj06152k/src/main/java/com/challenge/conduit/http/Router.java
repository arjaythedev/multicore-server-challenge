package com.challenge.conduit.http;

import com.challenge.conduit.db.PostgresClient;
import com.challenge.conduit.endpoint.*;
import com.challenge.conduit.json.JsonStreamer;
import com.challenge.conduit.security.BcryptPool;
import com.challenge.conduit.security.Jwt;
import io.netty.buffer.ByteBuf;
import io.netty.channel.ChannelHandlerContext;
import io.netty.handler.codec.http.*;

import java.nio.charset.StandardCharsets;

/**
 * Single Responsibility: High-speed zero-allocation Router.
 * Dispatches parsed HTTP requests to modular endpoint classes.
 */
public final class Router {

    public static void route(
            ChannelHandlerContext ctx,
            FullHttpRequest nettyReq,
            PostgresClient pgClient,
            Jwt jwt,
            BcryptPool bcryptPool
    ) {
        String uri = nettyReq.uri();
        String path = FastHttpParser.getPath(uri);
        HttpMethod method = nettyReq.method();

        long viewerId = extractViewerId(nettyReq, jwt);

        // Check for malformed authorization header
        String authHeader = nettyReq.headers().get(HttpHeaderNames.AUTHORIZATION);
        if (authHeader != null && !authHeader.isEmpty()) {
            if (!authHeader.startsWith("Token ") || viewerId == 0) {
                // Ignore invalid token ONLY for GET /api/tags
                if (!HttpMethod.GET.equals(method) || !"/api/tags".equals(path)) {
                    ByteBuf errBuf = ctx.alloc().buffer();
                    JsonStreamer.writeError(errBuf, "Invalid or expired authorization token");
                    sendImmediate(ctx, HttpResponseStatus.UNAUTHORIZED, errBuf);
                    return;
                }
            }
        }

        RequestContext req = new RequestContext(ctx, nettyReq, path, method, viewerId);

        // 1. Tags
        if (HttpMethod.GET.equals(method) && "/api/tags".equals(path)) {
            TagsEndpoint.handle(req, pgClient);
            return;
        }

        // 2. Users and Auth
        if (HttpMethod.POST.equals(method) && "/api/users".equals(path)) {
            UserEndpoint.handleRegister(req, pgClient, bcryptPool, jwt);
            return;
        }
        if (HttpMethod.POST.equals(method) && "/api/users/login".equals(path)) {
            UserEndpoint.handleLogin(req, pgClient, bcryptPool, jwt);
            return;
        }
        if (HttpMethod.GET.equals(method) && "/api/user".equals(path)) {
            UserEndpoint.handleGetCurrent(req, pgClient);
            return;
        }
        if (HttpMethod.PUT.equals(method) && "/api/user".equals(path)) {
            UserEndpoint.handleUpdate(req, pgClient, bcryptPool);
            return;
        }

        // 3. Profiles & Follows
        if (path.startsWith("/api/profiles/")) {
            String sub = path.substring("/api/profiles/".length());
            if (sub.endsWith("/follow")) {
                String targetUsername = sub.substring(0, sub.length() - "/follow".length());
                if (HttpMethod.POST.equals(method)) {
                    ProfileEndpoint.handleFollow(req, pgClient, targetUsername);
                    return;
                } else if (HttpMethod.DELETE.equals(method)) {
                    ProfileEndpoint.handleUnfollow(req, pgClient, targetUsername);
                    return;
                }
            } else if (HttpMethod.GET.equals(method) && !sub.isEmpty()) {
                ProfileEndpoint.handleGetProfile(req, pgClient, sub);
                return;
            }
        }

        // 4. Articles
        if (HttpMethod.GET.equals(method) && "/api/articles/feed".equals(path)) {
            ArticleEndpoint.handleFeed(req, pgClient);
            return;
        }
        if (HttpMethod.GET.equals(method) && "/api/articles".equals(path)) {
            ArticleEndpoint.handleList(req, pgClient);
            return;
        }
        if (HttpMethod.POST.equals(method) && "/api/articles".equals(path)) {
            ArticleEndpoint.handleCreateArticle(req, pgClient);
            return;
        }

        if (path.startsWith("/api/articles/")) {
            String remainder = path.substring("/api/articles/".length());
            // Check for /favorite
            if (remainder.endsWith("/favorite")) {
                String slug = remainder.substring(0, remainder.length() - "/favorite".length());
                if (HttpMethod.POST.equals(method)) {
                    FavoriteEndpoint.handleFavorite(req, pgClient, slug);
                    return;
                } else if (HttpMethod.DELETE.equals(method)) {
                    FavoriteEndpoint.handleUnfavorite(req, pgClient, slug);
                    return;
                }
            }

            // Check for /comments or /comments/:id
            int commentsIdx = remainder.indexOf("/comments");
            if (commentsIdx != -1) {
                String slug = remainder.substring(0, commentsIdx);
                String commentSub = remainder.substring(commentsIdx + "/comments".length());
                if (commentSub.isEmpty()) {
                    if (HttpMethod.GET.equals(method)) {
                        CommentEndpoint.handleListComments(req, pgClient, slug);
                        return;
                    } else if (HttpMethod.POST.equals(method)) {
                        CommentEndpoint.handleCreateComment(req, pgClient, slug);
                        return;
                    }
                } else if (commentSub.startsWith("/")) {
                    String commentId = commentSub.substring(1);
                    if (HttpMethod.DELETE.equals(method)) {
                        CommentEndpoint.handleDeleteComment(req, pgClient, slug, commentId);
                        return;
                    }
                }
            }

            // Otherwise, it's /api/articles/:slug
            if (!remainder.contains("/")) {
                String slug = remainder;
                if (HttpMethod.GET.equals(method)) {
                    ArticleEndpoint.handleGetArticle(req, pgClient, slug);
                    return;
                } else if (HttpMethod.PUT.equals(method)) {
                    ArticleEndpoint.handleUpdateArticle(req, pgClient, slug);
                    return;
                } else if (HttpMethod.DELETE.equals(method)) {
                    ArticleEndpoint.handleDeleteArticle(req, pgClient, slug);
                    return;
                }
            }
        }

        // Default 404
        ByteBuf errBuf = req.alloc();
        JsonStreamer.writeError(errBuf, "Not Found");
        req.send(HttpResponseStatus.NOT_FOUND, errBuf);
    }

    private static long extractViewerId(FullHttpRequest req, Jwt jwt) {
        String auth = req.headers().get(HttpHeaderNames.AUTHORIZATION);
        if (auth != null && auth.startsWith("Token ")) {
            int start = 6;
            while (start < auth.length() && auth.charAt(start) == ' ') {
                start++;
            }
            int end = auth.length();
            while (end > start && auth.charAt(end - 1) == ' ') {
                end--;
            }
            return jwt.verifyAndGetUserId(auth, start, end - start);
        }
        return 0;
    }

    private static void sendImmediate(ChannelHandlerContext ctx, HttpResponseStatus status, ByteBuf content) {
        FullHttpResponse res = new DefaultFullHttpResponse(HttpVersion.HTTP_1_1, status, content);
        res.headers().set(HttpHeaderNames.CONTENT_TYPE, "application/json");
        res.headers().setInt(HttpHeaderNames.CONTENT_LENGTH, content.readableBytes());
        res.headers().set(HttpHeaderNames.CONNECTION, HttpHeaderValues.KEEP_ALIVE);
        ctx.writeAndFlush(res);
    }
}
