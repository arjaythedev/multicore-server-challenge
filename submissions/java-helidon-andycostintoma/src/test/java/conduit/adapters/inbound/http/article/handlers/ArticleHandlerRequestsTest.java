package conduit.adapters.inbound.http.article.handlers;

import static conduit.adapters.inbound.http.HttpSupport.body;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import conduit.errors.InvalidInput;
import conduit.errors.NotFound;
import conduit.usecases.commands.CreateArticle;
import conduit.usecases.commands.UpdateArticle;
import java.util.List;
import org.junit.jupiter.api.Test;

class ArticleHandlerRequestsTest {
    @Test
    void decodingRejectsMalformedDocumentsRootsAndTrailingTokens() {
        for (String raw : List.of("", "{", "null", "[]", "42", "true", "\"text\"", "{}",
            "{\"article\":null}", "{\"article\":[]}", "{\"article\":42}", "{\"article\":true}",
            "{\"article\":\"text\"}", "{\"article\":{}} null", "{\"article\":{}} {}",
            "{\"article\":{}} garbage")) {
            assertInvalid(raw, ArticleHandlerRequestsTest::create);
            assertInvalid(raw, ArticleHandlerRequestsTest::update);
            assertInvalid(raw.replace("article", "comment"), ArticleHandlerRequestsTest::comment);
        }
    }

    @Test
    void createPreservesTagOrderAndDuplicatesAndIgnoresUnknownFields() {
        assertEquals(new CreateArticle.Request("t", "d", "b", List.of("z", "a", "z")), create(
            """
                {"unknown":[],"article":{"title":"t","description":"d","body":"b","tagList":["z","a","z"],"unknown":true}}
                """));
        assertEquals(new CreateArticle.Request(null, null, null, null), create("{\"article\":{}}"));
        assertEquals(new CreateArticle.Request("", "d", "b", List.of("")), create(
            "{\"article\":{\"title\":\"\",\"description\":\"d\",\"body\":\"b\",\"tagList\":[\"\"]}}"));
    }

    @Test
    void createRejectsIncorrectlyTypedRequiredFields() {
        for (String field : List.of("title", "description", "body")) {
            for (String raw : List.of("1", "1.5", "true", "[]", "{}")) {
                var input = "{\"article\":{\"title\":\"t\",\"description\":\"d\",\"body\":\"b\"}}"
                    .replaceFirst("\"" + field + "\":\"[^\"]*\"", "\"" + field + "\":" + raw);
                assertInvalid(input, ArticleHandlerRequestsTest::create);
            }
        }
    }

    @Test
    void createRejectsNonArraysAndNonStringTagsWithoutCoercion() {
        for (String tags : List.of("\"tag\"", "{}", "42", "true", "[1]", "[1.5]", "[true]", "[[]]",
            "[{}]")) {
            assertInvalid(
                "{\"article\":{\"title\":\"t\",\"description\":\"d\",\"body\":\"b\",\"tagList\":"
                    + tags + "}}",
                ArticleHandlerRequestsTest::create);
        }
    }

    @Test
    void updatePreservesAbsentNullAndEmptyFieldsAndIgnoresUnknownFields() {
        assertEquals(new UpdateArticle.Request(null, null, null), update("{\"article\":{}}"));
        assertEquals(new UpdateArticle.Request(null, "", "new"), update(
            "{\"article\":{\"title\":null,\"description\":\"\",\"body\":\"new\",\"tagList\":42}}"));
        for (String field : List.of("title", "description", "body")) {
            for (String raw : List.of("1", "1.5", "true", "[]", "{}")) {
                assertInvalid("{\"article\":{\"" + field + "\":" + raw + "}}",
                    ArticleHandlerRequestsTest::update);
            }
        }
    }

    @Test
    void commentRequiresStringBodyAndIgnoresUnknownFields() {
        assertEquals("body", comment("{\"comment\":{\"body\":\"body\",\"extra\":false}}"));
        assertNull(comment("{\"comment\":{}}"));
        assertEquals("", comment("{\"comment\":{\"body\":\"\"}}"));
        for (String raw : List.of("42", "1.5", "true", "[]", "{}")) {
            assertInvalid("{\"comment\":{\"body\":" + raw + "}}",
                ArticleHandlerRequestsTest::comment);
        }
    }

    @Test
    void pagingDefaultsAndSyntaxAllowOnlyAsciiDigits() {
        assertEquals(new ArticlePagination.PageRequest(20, 0), ArticlePagination.parse(null, null));
        assertEquals(new ArticlePagination.PageRequest(100, Long.MAX_VALUE),
            ArticlePagination.parse("000100", "0009223372036854775807"));
        assertEquals(new ArticlePagination.PageRequest(1, 0), ArticlePagination.parse("01", "000"));
        for (String raw : List.of("", "-1", "+1", " 1", "1 ", "1.0", "1e1", "١",
            "9223372036854775808")) {
            assertInvalid(raw, input -> ArticlePagination.parse(input, "0"));
            assertInvalid(raw, input -> ArticlePagination.parse("20", input));
        }
        assertEquals(new ArticlePagination.PageRequest(0, 0), ArticlePagination.parse("0", "0"));
        assertEquals(new ArticlePagination.PageRequest(Integer.MAX_VALUE, 0),
            ArticlePagination.parse("2147483647", "0"));
        assertInvalid("2147483648", input -> ArticlePagination.parse(input, "0"));
    }

    @Test
    void commentIdsSupportSignedBigintsAndRejectOverflowWithoutThrowing() {
        assertEquals(Long.MIN_VALUE, DeleteCommentHandler.commentId("-9223372036854775808"));
        assertEquals(Long.MAX_VALUE, DeleteCommentHandler.commentId("0009223372036854775807"));
        assertEquals(0L, DeleteCommentHandler.commentId("-000"));
        for (String raw : List.of("", "-", "+1", "1.0", " 1", "9223372036854775808",
            "-9223372036854775809")) {
            assertThrows(NotFound.class, () -> DeleteCommentHandler.commentId(raw));
        }
    }

    private static CreateArticle.Request create(String input) {
        return CreateArticleHandler.parse(body(input, CreateArticleHandler.Request.class));
    }

    private static UpdateArticle.Request update(String input) {
        return UpdateArticleHandler.parse(body(input, UpdateArticleHandler.Request.class));
    }

    private static String comment(String input) {
        return AddCommentHandler.parse(body(input, AddCommentHandler.Request.class));
    }

    @FunctionalInterface
    private interface Parser {
        void parse(String raw);
    }

    private static void assertInvalid(String input, Parser parser) {
        assertThrows(InvalidInput.class, () -> parser.parse(input));
    }
}
