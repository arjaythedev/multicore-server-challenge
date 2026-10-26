package conduit.reads;

import conduit.Exchange;
import conduit.db.MessageWriter;
import conduit.db.Row;
import conduit.db.Statement;
import conduit.json.JsonWriter;
import conduit.json.Keys;
import io.netty.buffer.ByteBufAllocator;

/**
 * GET /api/tags: all tag names, sorted. The answer doesn't depend on who asks, so a batch runs the query once and
 * every request of the batch (all of them waiting when it was sent) gets that same fresh result.
 */
final class TagsRead extends BatchedRead<JsonWriter> {
    private final Statement allTags = Statement.define("SELECT name FROM tags ORDER BY name");

    TagsRead(int maxBatch) {
        super("tags", null, maxBatch);
    }

    @Override
    protected void writeBatch(MessageWriter out, Exchange[] requests, int count) {
        out.bind(allTags).execute();
        out.sync();
    }

    /** The batch's {"tags": [...]}, written once. */
    @Override
    protected JsonWriter newBatch(int count) {
        JsonWriter tags = new JsonWriter(ByteBufAllocator.DEFAULT, 4096);
        tags.beginObject().key(Keys.TAGS).beginArray();
        return tags;
    }

    @Override
    protected void onRow(JsonWriter tags, Exchange[] requests, int count, Row row) {
        tags.column(row, 0);
    }

    @Override
    protected void finish(JsonWriter tags, Exchange[] requests, int count) {
        tags.endArray().endObject();
        answerEach(requests, count, i -> {
            requests[i].json().raw(tags.body());
            requests[i].respond(200);
        });
    }

    @Override
    protected void release(JsonWriter tags) {
        tags.release();
    }
}
