package dev.moose.conduit.json;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class JsonReader {

    public static final Object NULL = new Object();

    public static class MalformedException extends Exception {
        MalformedException() {
            super(null, null, false, false);
        }
    }

    private final String text;
    private int position;

    private JsonReader(String text) {
        this.text = text;
    }

    public static Object parse(byte[] body) throws MalformedException {
        final JsonReader parser = new JsonReader(new String(body, StandardCharsets.UTF_8));
        parser.skipWhitespace();
        final Object value = parser.value(0);
        parser.skipWhitespace();
        if (parser.position != parser.text.length()) {
            throw new MalformedException();
        }
        return value;
    }

    @SuppressWarnings("unchecked")
    public static Map<String, Object> wrapped(byte[] body, String wrapper) {
        try {
            final Object root = parse(body);
            if (!(root instanceof Map<?, ?> rootObject)) {
                return null;
            }
            final Object inner = rootObject.get(wrapper);
            if (!(inner instanceof Map<?, ?> innerObject)) {
                return null;
            }
            return (Map<String, Object>) innerObject;
        } catch (MalformedException exception) {
            return null;
        }
    }

    private Object value(int depth) throws MalformedException {
        if (depth > 64 || this.position >= this.text.length()) {
            throw new MalformedException();
        }
        final char character = this.text.charAt(this.position);
        return switch (character) {
            case '{' -> object(depth);
            case '[' -> array(depth);
            case '"' -> string();
            case 't' -> literal("true", Boolean.TRUE);
            case 'f' -> literal("false", Boolean.FALSE);
            case 'n' -> literal("null", NULL);
            default -> number();
        };
    }

    private Map<String, Object> object(int depth) throws MalformedException {
        this.position++;
        final Map<String, Object> result = new HashMap<>();
        skipWhitespace();
        if (peek() == '}') {
            this.position++;
            return result;
        }
        while (true) {
            skipWhitespace();
            if (peek() != '"') {
                throw new MalformedException();
            }
            final String key = string();
            skipWhitespace();
            expect(':');
            skipWhitespace();
            result.put(key, value(depth + 1));
            skipWhitespace();
            final char next = peek();
            this.position++;
            if (next == '}') {
                return result;
            }
            if (next != ',') {
                throw new MalformedException();
            }
        }
    }

    private List<Object> array(int depth) throws MalformedException {
        this.position++;
        final List<Object> result = new ArrayList<>();
        skipWhitespace();
        if (peek() == ']') {
            this.position++;
            return result;
        }
        while (true) {
            skipWhitespace();
            result.add(value(depth + 1));
            skipWhitespace();
            final char next = peek();
            this.position++;
            if (next == ']') {
                return result;
            }
            if (next != ',') {
                throw new MalformedException();
            }
        }
    }

    private String string() throws MalformedException {
        this.position++;
        StringBuilder builder = null;
        int start = this.position;
        while (true) {
            if (this.position >= this.text.length()) {
                throw new MalformedException();
            }
            final char character = this.text.charAt(this.position);
            if (character == '"') {
                final String tail = this.text.substring(start, this.position);
                this.position++;
                if (builder == null) {
                    return tail;
                }
                return builder.append(tail).toString();
            }
            if (character < 0x20) {
                throw new MalformedException();
            }
            if (character != '\\') {
                this.position++;
                continue;
            }
            if (builder == null) {
                builder = new StringBuilder();
            }
            builder.append(this.text, start, this.position);
            this.position++;
            if (this.position >= this.text.length()) {
                throw new MalformedException();
            }
            final char escaped = this.text.charAt(this.position++);
            switch (escaped) {
                case '"', '\\', '/' -> builder.append(escaped);
                case 'b' -> builder.append('\b');
                case 'f' -> builder.append('\f');
                case 'n' -> builder.append('\n');
                case 'r' -> builder.append('\r');
                case 't' -> builder.append('\t');
                case 'u' -> builder.append(unicodeEscape());
                default -> throw new MalformedException();
            }
            start = this.position;
        }
    }

    private char unicodeEscape() throws MalformedException {
        if (this.position + 4 > this.text.length()) {
            throw new MalformedException();
        }
        int value = 0;
        for (int i = 0; i < 4; i++) {
            final int digit = Character.digit(this.text.charAt(this.position++), 16);
            if (digit < 0) {
                throw new MalformedException();
            }
            value = value * 16 + digit;
        }
        return (char) value;
    }

    private Object literal(String word, Object result) throws MalformedException {
        if (!this.text.startsWith(word, this.position)) {
            throw new MalformedException();
        }
        this.position += word.length();
        return result;
    }

    private Double number() throws MalformedException {
        final int start = this.position;
        while (this.position < this.text.length() && "+-0123456789.eE".indexOf(this.text.charAt(this.position)) >= 0) {
            this.position++;
        }
        if (start == this.position) {
            throw new MalformedException();
        }
        try {
            return Double.parseDouble(this.text.substring(start, this.position));
        } catch (NumberFormatException exception) {
            throw new MalformedException();
        }
    }

    private char peek() throws MalformedException {
        if (this.position >= this.text.length()) {
            throw new MalformedException();
        }
        return this.text.charAt(this.position);
    }

    private void expect(char wanted) throws MalformedException {
        if (peek() != wanted) {
            throw new MalformedException();
        }
        this.position++;
    }

    private void skipWhitespace() {
        while (this.position < this.text.length()) {
            final char character = this.text.charAt(this.position);
            if (character != ' ' && character != '\t' && character != '\n' && character != '\r') {
                return;
            }
            this.position++;
        }
    }

}
