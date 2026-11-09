package conduit.usecases.queries;

import conduit.contracts.tag.TagReader;
import java.util.List;

public final class ListTags {
    private final TagReader tags;

    public ListTags(TagReader tags) {
        this.tags = tags;
    }

    public List<String> execute() {
        return tags.listTags();
    }
}
