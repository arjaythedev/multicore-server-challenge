package conduit.reads;

import conduit.db.Row;
import conduit.json.JsonWriter;
import conduit.json.Render;
import io.netty.buffer.ByteBufAllocator;
import java.util.Arrays;
import java.util.HashMap;

/**
 * What a batch of article reads or article lists collects while its rows arrive. The statement returns each distinct
 * article once (a "shared" row, rendered once here into a JSON fragment that stops at the author's "following") and,
 * per request, which articles it shows together with that viewer's flags. Each response then copies the fragments
 * of its articles and adds its own flags.
 */
final class ArticleBatch {
    private final JsonWriter fragments = new JsonWriter(ByteBufAllocator.DEFAULT, 8192);
    /** Article id -> where its fragment is: offset << 32 | length. */
    private final HashMap<Long, Long> fragmentById = new HashMap<>();
    private final Page[] pages;

    /** One request's articles (in arrival order, with the viewer's flags) and its articlesCount. */
    static final class Page {
        long[] ids = new long[10];
        boolean[] favorited = new boolean[10];
        boolean[] following = new boolean[10];
        int size;
        long total;

        void add(long id, boolean favoritedByViewer, boolean followedByViewer) {
            if (size == ids.length) {
                ids = Arrays.copyOf(ids, size * 2);
                favorited = Arrays.copyOf(favorited, size * 2);
                following = Arrays.copyOf(following, size * 2);
            }
            ids[size] = id;
            favorited[size] = favoritedByViewer;
            following[size] = followedByViewer;
            size++;
        }

        /** Newest first: ids are assigned in creation order (insertion sort, a page has at most 100 articles). */
        void sortNewestFirst() {
            for (int i = 1; i < size; i++) {
                long id = ids[i];
                boolean fav = favorited[i], fol = following[i];
                int j = i - 1;
                for (; j >= 0 && ids[j] < id; j--) {
                    ids[j + 1] = ids[j];
                    favorited[j + 1] = favorited[j];
                    following[j + 1] = following[j];
                }
                ids[j + 1] = id;
                favorited[j + 1] = fav;
                following[j + 1] = fol;
            }
        }
    }

    ArticleBatch(int requests) {
        pages = new Page[requests];
    }

    /** The page of request {@code index} (null if no row of the statement named it). */
    Page page(int index) {
        return pages[index];
    }

    Page pageFor(int index) {
        if (pages[index] == null) pages[index] = new Page();
        return pages[index];
    }

    /** Renders a shared article row (columns from the article id on) once, for all the responses that show it. */
    void addArticle(Row row, int firstColumn, boolean withBody) {
        long id = row.getLong(firstColumn);
        int start = fragments.position();
        fragments.startFragment();
        Render.articleOpen(fragments, row, firstColumn, withBody);
        fragmentById.put(id, ((long) start << 32) | (fragments.position() - start));
    }

    /** Writes article {@code index} of a page: the shared fragment, then the viewer's flags. */
    void writeArticle(JsonWriter out, Page page, int index) {
        long where = fragmentById.get(page.ids[index]);
        out.openFragment(fragments.buffer(), (int) (where >>> 32), (int) where);
        Render.articleClose(out, page.following[index], page.favorited[index]);
    }

    void release() {
        fragments.release();
    }
}
