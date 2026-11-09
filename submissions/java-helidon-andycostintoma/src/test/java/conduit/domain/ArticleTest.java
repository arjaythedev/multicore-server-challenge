package conduit.domain;

import static org.junit.jupiter.api.Assertions.*;

import conduit.errors.Forbidden;
import conduit.errors.InvalidInput;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import org.junit.jupiter.api.Test;

class ArticleTest {
    @Test
    void slugUsesAsciiAndKeepsBigintIdentity() {
        var article = Article.create(new Article.Input(7, "  HELLO, wörld! 2026  ", "d", "b"),
            () -> 4_000_000_000L);
        assertEquals("hello-w-rld-2026-4000000000", article.slug());
        assertEquals("-9", Article.create(new Article.Input(7, "你好!!!", "d", "b"), () -> 9).slug());
    }

    @Test
    void slugIsIndependentOfDefaultLocale() {
        var previous = Locale.getDefault();
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"));
            assertEquals("i-9",
                Article.create(new Article.Input(7, "I", "d", "b"), () -> 9).slug());
        } finally {
            Locale.setDefault(previous);
        }
    }

    @Test
    void updatePreservesNullsAndChangesSlugOnlyWithTitle() {
        var original = Article
            .reconstitute(new Article.Props(9, 7, "historical-9", "Old", "d", "b"));
        var bodyOnly = original.update(7, new Article.UpdateInput(null, null, "new body"));
        assertEquals("historical-9", bodyOnly.slug());
        assertEquals("Old", bodyOnly.title());
        assertEquals("d", bodyOnly.description());
        assertEquals("new body", bodyOnly.body());
        var renamed = bodyOnly.update(7, new Article.UpdateInput("New Title!", null, null));
        assertEquals("new-title-9", renamed.slug());
        assertEquals("New Title!", renamed.title());
        assertEquals("new body", renamed.body());
    }

    @Test
    void updateRejectsEmptyRequiredFields() {
        var article = Article.create(new Article.Input(7, "Old", "d", "b"), () -> 9);
        assertThrows(InvalidInput.class,
            () -> article.update(7, new Article.UpdateInput("", null, null)));
        assertThrows(InvalidInput.class,
            () -> article.update(7, new Article.UpdateInput(null, "", null)));
        assertThrows(InvalidInput.class,
            () -> article.update(7, new Article.UpdateInput(null, null, "")));
    }

    @Test
    void authorPermissionsProtectBothUpdateAndDeletion() {
        var article = Article.create(new Article.Input(7, "Old", "d", "b"), () -> 9);
        assertThrows(Forbidden.class,
            () -> article.update(8, new Article.UpdateInput("New", null, null)));
        assertThrows(Forbidden.class, () -> article.authorize(8));
        assertDoesNotThrow(() -> article.authorize(7));
    }

    @Test
    void creationRequiresNonEmptyFieldsAndTags() {
        assertThrows(InvalidInput.class,
            () -> Article.create(new Article.Input(7, "", "d", "b"), ArticleTest::unallocatedId));
        assertThrows(InvalidInput.class,
            () -> Article.create(new Article.Input(7, "t", null, "b"), ArticleTest::unallocatedId));
        assertThrows(InvalidInput.class,
            () -> Article.create(new Article.Input(7, "t", "d", ""), ArticleTest::unallocatedId));
        assertThrows(InvalidInput.class, () -> Article.tags(List.of("ok", "")));
        assertThrows(InvalidInput.class, () -> Article.tags(Arrays.asList("ok", null)));
        assertEquals(List.of(), Article.tags(null));
        assertEquals(List.of("x"), Article.tags(List.of("x", "x")));
    }

    private static long unallocatedId() {
        throw new AssertionError("invalid article allocated an id");
    }
}
