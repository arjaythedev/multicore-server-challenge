package dev.moose.conduit.http.render;

import dev.moose.conduit.http.HttpReply;
import dev.moose.conduit.json.JsonWriter;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;

public class ResponseRenderer {

    private ResponseRenderer() {
    }

    public static HttpReply user(int status, String email, String token, String username, String bio, String image) {
        final JsonWriter out = new JsonWriter(512).open().key("user").open()
                .key("email").string(email)
                .key("token").string(token)
                .key("username").string(username)
                .key("bio").string(bio)
                .key("image").string(image)
                .close().close();
        return new HttpReply(status, out.toBytes());
    }

    public static HttpReply profile(String username, String bio, String image, boolean following) {
        return HttpReply.ok(new JsonWriter(256).open().key("profile").open()
                .key("username").string(username)
                .key("bio").string(bio)
                .key("image").string(image)
                .key("following").bool(following)
                .close().close());
    }

    public static HttpReply article(int status, ResultSet row, int offset) throws SQLException {
        final JsonWriter out = new JsonWriter(2048).open().key("article").open()
                .key("slug").string(row.getString(offset + 2))
                .key("title").string(row.getString(offset + 3))
                .key("description").string(row.getString(offset + 4))
                .key("body").string(row.getString(offset + 5))
                .key("tagList").openArray();
        for (final String tag : (String[]) row.getArray(offset + 8).getArray()) {
            out.string(tag);
        }
        out.closeArray()
                .key("createdAt").timestamp(row.getObject(offset + 6, OffsetDateTime.class))
                .key("updatedAt").timestamp(row.getObject(offset + 7, OffsetDateTime.class))
                .key("favorited").bool(row.getBoolean(offset + 10))
                .key("favoritesCount").number(row.getLong(offset + 9))
                .key("author").open()
                .key("username").string(row.getString(offset + 11))
                .key("bio").string(row.getString(offset + 12))
                .key("image").string(row.getString(offset + 13))
                .key("following").bool(row.getBoolean(offset + 14))
                .close()
                .close().close();
        return new HttpReply(status, out.toBytes());
    }

    public static HttpReply comment(ResultSet row) throws SQLException {
        return HttpReply.created(new JsonWriter(512).open().key("comment").open()
                .key("id").number(row.getLong(1))
                .key("createdAt").timestamp(row.getObject(3, OffsetDateTime.class))
                .key("updatedAt").timestamp(row.getObject(4, OffsetDateTime.class))
                .key("body").string(row.getString(2))
                .key("author").open()
                .key("username").string(row.getString(5))
                .key("bio").string(row.getString(6))
                .key("image").string(row.getString(7))
                .key("following").bool(false)
                .close()
                .close().close());
    }

}
