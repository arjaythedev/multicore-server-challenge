package conduit.adapters.inbound.http;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.cfg.CoercionAction;
import com.fasterxml.jackson.databind.cfg.CoercionInputShape;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.databind.type.LogicalType;
import conduit.errors.InvalidInput;
import conduit.errors.Unauthenticated;
import io.helidon.common.media.type.MediaTypes;
import io.helidon.http.HeaderNames;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;
import java.io.IOException;

public final class HttpSupport {
    private static final ObjectMapper INPUT = JsonMapper.builder()
        .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
        .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
        .withCoercionConfig(LogicalType.Textual,
            coercion -> coercion.setCoercion(CoercionInputShape.Integer, CoercionAction.Fail)
                .setCoercion(CoercionInputShape.Float, CoercionAction.Fail)
                .setCoercion(CoercionInputShape.Boolean, CoercionAction.Fail))
        .build();

    public static <T> T body(ServerRequest request, Class<T> type) {
        if (!request.content().hasEntity()) {
            throw new InvalidInput("Expected a JSON object");
        }
        return body(request.content().as(String.class), type);
    }

    public static <T> T body(String input, Class<T> type) {
        try {
            var document = INPUT.readValue(input, type);
            if (document == null) {
                throw new InvalidInput("Expected a JSON object");
            }
            return document;
        } catch (JsonProcessingException failure) {
            throw new InvalidInput("Invalid JSON");
        }
    }

    public static String token(ServerRequest request) {
        var values = request.headers().values(HeaderNames.AUTHORIZATION);
        if (values.isEmpty()) {
            return null;
        }
        return token(values.size() == 1 ? values.getFirst() : "");
    }

    static String token(String authorization) {
        if (!authorization.startsWith("Token ")) {
            throw new Unauthenticated("A valid Token authorization header is required");
        }
        var token = authorization.substring(6);
        if (token.isEmpty() || token.chars().anyMatch(Character::isWhitespace)) {
            throw new Unauthenticated("Invalid token");
        }
        return token;
    }

    public static void send(ServerResponse response, ObjectMapper json, int status, Object value)
        throws IOException {
        response.status(status);
        if (status == 204) {
            response.send();
            return;
        }
        response.headers().contentType(MediaTypes.APPLICATION_JSON);
        response.send(json.writeValueAsBytes(value));
    }

    public static void error(ServerResponse response, ObjectMapper json, int status,
        String message) {
        var body = json.createObjectNode();
        body.putObject("errors").putArray("body").add(message);
        response.status(status);
        response.headers().contentType(MediaTypes.APPLICATION_JSON);
        response.send(body.toString());
    }

    private HttpSupport() {
    }
}
