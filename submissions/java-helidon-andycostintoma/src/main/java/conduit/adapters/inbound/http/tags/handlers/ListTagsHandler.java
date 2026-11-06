package conduit.adapters.inbound.http.tags.handlers;

import static conduit.adapters.inbound.http.HttpSupport.send;

import com.fasterxml.jackson.databind.ObjectMapper;
import conduit.usecases.queries.ListTags;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;
import java.util.Map;

public final class ListTagsHandler {
    private final ListTags tags;
    private final ObjectMapper json;

    public ListTagsHandler(ListTags tags, ObjectMapper json) {
        this.tags = tags;
        this.json = json;
    }

    public void handle(ServerRequest ignoredRequest, ServerResponse response) throws IOException {
        send(response, json, 200, Map.of("tags", tags.execute()));
    }
}
