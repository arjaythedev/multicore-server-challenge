package conduit.adapters.inbound.http;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.errors.Unauthenticated;
import org.junit.jupiter.api.Test;

class HttpSupportTest {
    @Test
    void extractsTokenFromExactScheme() {
        assertEquals("signed", HttpSupport.token("Token signed"));
    }

    @Test
    void rejectsOtherSchemesAndMalformedTokens() {
        for (var header : new String[]{"", "Bearer signed", "signed", "token signed", "Token ",
                "Token signed extra"}) {
            assertThrows(Unauthenticated.class, () -> HttpSupport.token(header));
        }
    }
}
