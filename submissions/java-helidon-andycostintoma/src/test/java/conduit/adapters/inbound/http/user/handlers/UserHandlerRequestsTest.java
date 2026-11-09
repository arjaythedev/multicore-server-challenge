package conduit.adapters.inbound.http.user.handlers;

import static conduit.adapters.inbound.http.HttpSupport.body;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.errors.InvalidInput;
import conduit.usecases.commands.Login;
import conduit.usecases.commands.RegisterUser;
import conduit.usecases.commands.UpdateUser;
import org.junit.jupiter.api.Test;

class UserHandlerRequestsTest {
    @Test
    void registrationRejectsScalarCoercionAndLeavesPresenceToDomain() {
        for (var field : new String[]{"username", "email", "password"}) {
            for (var invalid : new String[]{"42", "1.5", "true", "[]", "{}"}) {
                var input = "{\"user\":{\"username\":\"alice\",\"email\":\"email\",\"password\":\"secret\"}}"
                    .replaceFirst("\"" + field + "\":\"[^\"]*\"", "\"" + field + "\":" + invalid);
                assertInvalid(input, UserHandlerRequestsTest::register);
            }
        }
        assertEquals(new RegisterUser.Request(null, "", null),
            register("{\"user\":{\"email\":\"\"}}"));
        assertEquals(new RegisterUser.Request("alice", "email", "secret"), register(
            """
                {"extra":true,"user":{"username":"alice","email":"email","password":"secret","extra":[]}}
                """));
    }

    @Test
    void loginRejectsScalarCoercionAndLeavesPresenceToUsecase() {
        for (var field : new String[]{"email", "password"}) {
            for (var invalid : new String[]{"42", "1.5", "true", "[]", "{}"}) {
                var input = "{\"user\":{\"email\":\"email\",\"password\":\"secret\"}}"
                    .replaceFirst("\"" + field + "\":\"[^\"]*\"", "\"" + field + "\":" + invalid);
                assertInvalid(input, UserHandlerRequestsTest::login);
            }
        }
        assertEquals(new Login.Request("email", null), login("{\"user\":{\"email\":\"email\"}}"));
        assertEquals(new Login.Request("", ""),
            login("{\"user\":{\"email\":\"\",\"password\":\"\"}}"));
    }

    @Test
    void updatePreservesMissingNullAndEmptyFields() {
        var unchanged = new UpdateUser.Request(null, null, null, null, null);
        assertEquals(unchanged, update("{\"user\":{}}"));
        assertEquals(unchanged, update("""
            {"user":{"email":null,"username":null,"password":null,"bio":null,"image":null}}
            """));
        assertEquals(new UpdateUser.Request("", "", "", "", ""), update("""
            {"user":{"email":"","username":"","password":"","bio":"","image":"","unknown":42}}
            """));
        for (var field : new String[]{"email", "username", "password", "bio", "image"}) {
            for (var invalid : new String[]{"42", "1.5", "true", "[]", "{}"}) {
                assertInvalid("{\"user\":{\"" + field + "\":" + invalid + "}}",
                    UserHandlerRequestsTest::update);
            }
        }
    }

    @Test
    void decodingRejectsMalformedDocumentsRootsAndTrailingTokens() {
        for (var input : new String[]{"", "{", "null", "42", "true", "[]", "\"text\"", "{}",
                "{\"user\":null}", "{\"user\":[]}", "{\"user\":42}", "{\"user\":true}",
                "{\"user\":\"text\"}", "{\"user\":{}} null", "{\"user\":{}} {}",
                "{\"user\":{}} garbage"}) {
            assertInvalid(input, UserHandlerRequestsTest::register);
            assertInvalid(input, UserHandlerRequestsTest::login);
            assertInvalid(input, UserHandlerRequestsTest::update);
        }
    }

    private static RegisterUser.Request register(String input) {
        return RegisterUserHandler.parse(body(input, RegisterUserHandler.Request.class));
    }

    private static Login.Request login(String input) {
        return LoginHandler.parse(body(input, LoginHandler.Request.class));
    }

    private static UpdateUser.Request update(String input) {
        return UpdateUserHandler.parse(body(input, UpdateUserHandler.Request.class));
    }

    @FunctionalInterface
    private interface Parser {
        void parse(String raw);
    }

    private static void assertInvalid(String input, Parser parser) {
        assertThrows(InvalidInput.class, () -> parser.parse(input));
    }
}
