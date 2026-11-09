package conduit.usecases.queries;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.contracts.tag.TagReader;
import java.util.List;
import org.junit.jupiter.api.Test;

class ListTagsTest {
    @Test
    void delegatesToTagReader() {
        var reader = new StubTagReader();
        reader.tags = List.of("java", "testing");
        var tags = new ListTags(reader);

        assertEquals(reader.tags, tags.execute());
        assertEquals(1, reader.calls);
    }

    @Test
    void readsFreshTagsOnEveryInvocation() {
        var reader = new StubTagReader();
        var tags = new ListTags(reader);
        reader.tags = List.of("java");

        assertEquals(List.of("java"), tags.execute());

        reader.tags = List.of("java", "testing");

        assertEquals(List.of("java", "testing"), tags.execute());
        assertEquals(2, reader.calls);
    }

    @Test
    void propagatesReaderFailureUnchanged() {
        var reader = new StubTagReader();
        reader.failure = new IllegalStateException("tag storage unavailable");
        var tags = new ListTags(reader);

        var failure = assertThrows(IllegalStateException.class, tags::execute);

        assertSame(reader.failure, failure);
        assertEquals(1, reader.calls);
    }

    private static final class StubTagReader implements TagReader {
        private List<String> tags = List.of();
        private RuntimeException failure;
        private int calls;

        @Override
        public List<String> listTags() {
            calls++;
            if (failure != null) {
                throw failure;
            }
            return tags;
        }
    }
}
