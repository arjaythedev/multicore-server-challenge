package conduit.adapters.inbound.http.tags;

import conduit.adapters.inbound.http.tags.handlers.ListTagsHandler;
import io.helidon.webserver.http.HttpRouting;

public final class TagRoutes {
    private final ListTagsHandler tags;

    public TagRoutes(ListTagsHandler tags) {
        this.tags = tags;
    }

    public void register(HttpRouting.Builder routes) {
        routes.get("/api/tags", tags::handle);
    }
}
