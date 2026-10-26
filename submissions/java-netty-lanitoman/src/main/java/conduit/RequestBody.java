package conduit;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * A request body of the form {"wrapper": {...}}, e.g. {"user": {"email": ..., "password": ...}}. Fields can be
 * absent, null, a string, an array or something else; the accessors turn anything unexpected into {@link Invalid},
 * which the handlers answer with 422.
 */
public final class RequestBody {
    /** The body is malformed or a field is missing or has the wrong type. */
    public static final class Invalid extends Exception {
        public Invalid(String message) {
            super(message, null, false, false);
        }
    }

    private static final JsonFactory JSON = new JsonFactory();
    /** Marks a field whose value is JSON null (as opposed to absent). */
    private static final Object NULL = new Object();
    /** Marks a value that is neither a string, null nor an array (a number, a boolean, an object). */
    private static final Object OTHER = new Object();

    private final Map<String, Object> fields;

    private RequestBody(Map<String, Object> fields) {
        this.fields = fields;
    }

    public static RequestBody parse(byte[] body, String wrapper) throws Invalid {
        if (body.length == 0) throw new Invalid("a JSON body is required");
        Map<String, Object> fields = null;
        try (JsonParser parser = JSON.createParser(body)) {
            if (parser.nextToken() != JsonToken.START_OBJECT) throw new Invalid("the body must be a JSON object");
            while (parser.nextToken() == JsonToken.FIELD_NAME) {
                String name = parser.currentName();
                JsonToken value = parser.nextToken();
                if (name.equals(wrapper) && value == JsonToken.START_OBJECT) fields = readObject(parser);
                else parser.skipChildren();
            }
            if (parser.nextToken() != null) throw new Invalid("unexpected data after the JSON object");
        } catch (IOException e) {
            throw new Invalid("malformed JSON");
        }
        if (fields == null) throw new Invalid("the body must be {\"" + wrapper + "\": {...}}");
        return new RequestBody(fields);
    }

    private static Map<String, Object> readObject(JsonParser parser) throws IOException {
        Map<String, Object> fields = new HashMap<>();
        while (parser.nextToken() == JsonToken.FIELD_NAME) {
            String name = parser.currentName();
            fields.put(name, readValue(parser, parser.nextToken()));
        }
        return fields;
    }

    private static Object readValue(JsonParser parser, JsonToken token) throws IOException {
        switch (token) {
            case VALUE_STRING:
                return parser.getText();
            case VALUE_NULL:
                return NULL;
            case START_ARRAY: {
                List<Object> items = new ArrayList<>();
                JsonToken item;
                while ((item = parser.nextToken()) != JsonToken.END_ARRAY) items.add(readValue(parser, item));
                return items;
            }
            default:
                parser.skipChildren();
                return OTHER;
        }
    }

    /** A field that must be a non-empty string. */
    public String required(String name) throws Invalid {
        if (fields.get(name) instanceof String value && !value.isEmpty()) return value;
        throw new Invalid(name + " must be a non-empty string");
    }

    /** A field that may be absent or null (both give null); otherwise a string, non-empty unless allowEmpty. */
    public String optional(String name, boolean allowEmpty) throws Invalid {
        Object value = fields.get(name);
        if (value == null || value == NULL) return null;
        if (value instanceof String text && (allowEmpty || !text.isEmpty())) return text;
        throw new Invalid(name + " must be " + (allowEmpty ? "a string" : "a non-empty string"));
    }

    /** tagList: absent or null means no tags; otherwise an array of non-empty strings. */
    public List<String> tagList() throws Invalid {
        Object value = fields.get("tagList");
        if (value == null || value == NULL) return List.of();
        if (!(value instanceof List<?> items)) throw new Invalid("tagList must be an array of strings");
        List<String> tags = new ArrayList<>(items.size());
        for (Object item : items) {
            if (!(item instanceof String tag) || tag.isEmpty()) throw new Invalid("tagList must be an array of strings");
            tags.add(tag);
        }
        return tags;
    }
}
