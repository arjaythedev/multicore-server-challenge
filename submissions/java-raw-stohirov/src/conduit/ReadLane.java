package conduit;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.locks.ReentrantLock;

/**
 * The batch planner. Each read lane owns one Postgres connection and takes every read waiting in the shared queue,
 * of every endpoint, answering the whole batch in two pipelined round trips:
 * <ul>
 * <li>phase A resolves what each request is about; identical keys collapse to one element of a parameter array (one
 * global page per (limit, offset), one lookup per slug, one count per tag, ...);</li>
 * <li>phase B enriches the union of every article phase A returned, once each (tags, favorite count, author), plus
 * the per-viewer favorited / following flags.</li>
 * </ul>
 * Every value in a response was read from Postgres while that request waited; nothing outlives the batch.
 */
final class ReadLane implements Runnable {
    /** Held by the lane that is forming a batch: one collects while the others execute theirs. */
    private static final ReentrantLock TURN = new ReentrantLock();
    /** Moving average of batch sizes. */
    private static volatile int avg;

    private static final byte[] E500 = Http.error(500, "internal error");
    private static final byte[] E401 = Http.error(401, "unauthorized");
    private static final byte[] E401_LOGIN = Http.error(401, "invalid email or password");
    private static final byte[] E404_ARTICLE = Http.error(404, "article not found");
    private static final byte[] E404_PROFILE = Http.error(404, "profile not found");

    private final Lanes.Settings s;
    private Pg pg;

    ReadLane(Lanes.Settings s) {
        this.s = s;
    }

    @Override
    public void run() {
        List<Job> jobs = new ArrayList<>(s.readMax());
        while (true) {
            jobs.clear();
            TURN.lock();
            try {
                Lanes.READS.take(Math.max(avg, s.readMin()), s.readWindowNanos(), s.readMax(), jobs);
            } catch (InterruptedException e) {
                return;
            } finally {
                TURN.unlock();
            }
            // under overload, clients give up (10 s) and close: their queued reads are dropped unrun
            jobs.removeIf(j -> j.conn.closed);
            int n = jobs.size();
            if (n == 0) continue;
            int prev = avg;
            avg = prev == 0 ? n : (prev * 7 + n) / 8;
            List<Http.Resp> out = new ArrayList<>(n);
            List<Job> verify = new ArrayList<>();
            try {
                if (pg == null) pg = Lanes.connect(Sql.reads());
                batch(jobs, out, verify);
            } catch (Throwable e) {
                System.err.println("read batch failed: " + e);
                if (pg != null) pg.close();
                pg = null;
                out.clear();
                verify.clear();
                for (Job j : jobs) out.add(new Http.Resp(j.conn, E500));
            }
            Http.deliver(out);
            Lanes.BCRYPT.pushAll(verify);
        }
    }

    // ---- keys ----

    static final class Keys<K> {
        final HashMap<K, Integer> map = new HashMap<>();
        final ArrayList<K> list = new ArrayList<>();

        int idx(K k) {
            Integer i = map.get(k);
            if (i != null) return i;
            int n = list.size();
            map.put(k, n);
            list.add(k);
            return n;
        }

        int size() {
            return list.size();
        }

        int find(K k) {
            Integer i = map.get(k);
            return i == null ? -1 : i;
        }
    }

    record LimOff(long lim, long off) {}

    record KeyPage(String key, long lim, long off) {}

    record ViewerPage(long v, long lim, long off) {}

    record Pair(long a, long b) {}

    private static byte[] texts(List<String> l) {
        Pg.Arr a = new Pg.Arr(Pg.TEXT);
        for (String x : l) a.text(x);
        return a.done();
    }

    private static byte[] longs(List<Long> l) {
        Pg.Arr a = new Pg.Arr(Pg.INT8);
        for (long x : l) a.i64(x);
        return a.done();
    }

    /** A page of article rows (row indices into one result), newest first. */
    static final class Page {
        Pg.Rows rows;
        int[] idx = new int[4];
        int n;

        void add(int i) {
            if (n == idx.length) idx = Arrays.copyOf(idx, n * 2);
            idx[n++] = i;
        }

        void sortByIdDesc() {
            // insertion sort: pages are short and come out nearly sorted
            for (int i = 1; i < n; i++) {
                int x = idx[i];
                long id = rows.i64(x, 1);
                int j = i - 1;
                while (j >= 0 && rows.i64(idx[j], 1) < id) {
                    idx[j + 1] = idx[j];
                    j--;
                }
                idx[j + 1] = x;
            }
        }
    }

    /** k-th list results: counts by count key, pages by page key. */
    private static final class ListRes {
        long[] counts;
        Page[] pages;
    }

    private static ListRes decodeList(Pg.Rows r, int ncount, int npage) {
        ListRes lr = new ListRes();
        lr.counts = new long[Math.max(1, ncount)];
        lr.pages = new Page[npage];
        for (int i = 0; i < npage; i++) {
            lr.pages[i] = new Page();
            lr.pages[i].rows = r;
        }
        if (r == null) return lr;
        for (int i = 0; i < r.nrows; i++) {
            long k = r.i64(i, 0);
            if (k <= 0) {
                int ci = k == 0 ? 0 : (int) (-k) - 1;
                if (ci < lr.counts.length) lr.counts[ci] = r.i64(i, 1);
            } else if (k <= npage) lr.pages[(int) k - 1].add(i);
        }
        for (Page p : lr.pages) p.sortByIdDesc();
        return lr;
    }

    /** The first row of each key (-1: none). */
    private static int[] firstRows(Pg.Rows r, int n) {
        int[] f = new int[n];
        Arrays.fill(f, -1);
        if (r == null) return f;
        for (int i = 0; i < r.nrows; i++) {
            long k = r.i64(i, 0);
            if (k >= 1 && k <= n && f[(int) k - 1] < 0) f[(int) k - 1] = i;
        }
        return f;
    }

    // ---- the batch ----

    private void batch(List<Job> jobs, List<Http.Resp> out, List<Job> verify) throws java.io.IOException {
        int nj = jobs.size();
        boolean wantTags = false, hasArticles = false;
        Keys<Long> uid = new Keys<>();
        Keys<String> uemail = new Keys<>(), prof = new Keys<>(), aslug = new Keys<>(), cmts = new Keys<>();
        Keys<Long> aid = new Keys<>();
        Keys<LimOff> global = new Keys<>();
        @SuppressWarnings("unchecked")
        Keys<String>[] listCount = new Keys[] {new Keys<String>(), new Keys<String>(), new Keys<String>()};
        @SuppressWarnings("unchecked")
        Keys<KeyPage>[] listPage = new Keys[] {new Keys<KeyPage>(), new Keys<KeyPage>(), new Keys<KeyPage>()};
        Keys<Long> feed = new Keys<>();
        Keys<ViewerPage> feedPage = new Keys<>();

        int[] ask = new int[nj], ask2 = new int[nj];
        for (int i = 0; i < nj; i++) {
            Job j = jobs.get(i);
            switch (j.kind) {
                case Job.TAGS -> wantTags = true;
                case Job.USER -> ask[i] = uid.idx(j.viewer);
                case Job.LOGIN -> ask[i] = uemail.idx(j.key);
                case Job.PROFILE -> ask[i] = prof.idx(j.key);
                case Job.ARTICLE -> {
                    ask[i] = aslug.idx(j.key);
                    hasArticles = true;
                }
                case Job.ARTICLE_ID -> {
                    ask[i] = aid.idx(j.id);
                    hasArticles = true;
                }
                case Job.COMMENTS -> ask[i] = cmts.idx(j.key);
                case Job.GLOBAL -> {
                    ask[i] = global.idx(new LimOff(j.lim, j.off));
                    hasArticles = true;
                }
                case Job.TAG, Job.AUTHOR, Job.FAVORITED -> {
                    int f = j.kind - Job.TAG;
                    ask[i] = listCount[f].idx(j.key);
                    ask2[i] = listPage[f].idx(new KeyPage(j.key, j.lim, j.off));
                    hasArticles = true;
                }
                case Job.FEED -> {
                    ask[i] = feed.idx(j.viewer);
                    ask2[i] = feedPage.idx(new ViewerPage(j.viewer, j.lim, j.off));
                    hasArticles = true;
                }
                default -> throw new IllegalStateException("not a read: " + j.kind);
            }
        }

        // ---- phase A ----
        Pg pg = this.pg;
        int slot = 0;
        int sTags = -1, sUid = -1, sUemail = -1, sProf = -1, sAslug = -1, sAid = -1, sCmts = -1, sGlobal = -1, sFeed = -1;
        int[] sList = {-1, -1, -1};
        String[] listStmt = {"tag", "author", "favlist"};
        if (wantTags || hasArticles) {
            pg.exec("tags");
            sTags = slot++;
        }
        if (uid.size() > 0) {
            pg.exec("uid", longs(uid.list));
            sUid = slot++;
        }
        if (uemail.size() > 0) {
            pg.exec("uemail", texts(uemail.list));
            sUemail = slot++;
        }
        if (prof.size() > 0) {
            pg.exec("prof", texts(prof.list));
            sProf = slot++;
        }
        if (aslug.size() > 0) {
            pg.exec("aslug", texts(aslug.list));
            sAslug = slot++;
        }
        if (aid.size() > 0) {
            pg.exec("aid", longs(aid.list));
            sAid = slot++;
        }
        if (cmts.size() > 0) {
            pg.exec("cmts", texts(cmts.list));
            sCmts = slot++;
        }
        if (global.size() > 0) {
            Pg.Arr l = new Pg.Arr(Pg.INT8), o = new Pg.Arr(Pg.INT8);
            for (LimOff x : global.list) {
                l.i64(x.lim);
                o.i64(x.off);
            }
            pg.exec("global", l.done(), o.done());
            sGlobal = slot++;
        }
        for (int f = 0; f < 3; f++) {
            if (listPage[f].size() == 0) continue;
            Pg.Arr k = new Pg.Arr(Pg.TEXT), l = new Pg.Arr(Pg.INT8), o = new Pg.Arr(Pg.INT8);
            for (KeyPage x : listPage[f].list) {
                k.text(x.key);
                l.i64(x.lim);
                o.i64(x.off);
            }
            pg.exec(listStmt[f], texts(listCount[f].list), k.done(), l.done(), o.done());
            sList[f] = slot++;
        }
        if (feed.size() > 0) {
            Pg.Arr v = new Pg.Arr(Pg.INT8), l = new Pg.Arr(Pg.INT8), o = new Pg.Arr(Pg.INT8);
            for (ViewerPage x : feedPage.list) {
                v.i64(x.v);
                l.i64(x.lim);
                o.i64(x.off);
            }
            pg.exec("feed", longs(feed.list), v.done(), l.done(), o.done());
            sFeed = slot++;
        }
        List<Pg.Rows> pa = slot > 0 ? pg.run() : List.of();
        for (Pg.Rows r : pa) if (r.failed()) throw new Pg.Error("phase A: " + r.sqlstate + " " + r.message);

        // ---- decode phase A ----
        Pg.Rows rUid = sUid >= 0 ? pa.get(sUid) : null, rUemail = sUemail >= 0 ? pa.get(sUemail) : null,
                rProf = sProf >= 0 ? pa.get(sProf) : null, rAslug = sAslug >= 0 ? pa.get(sAslug) : null,
                rAid = sAid >= 0 ? pa.get(sAid) : null, rCmts = sCmts >= 0 ? pa.get(sCmts) : null,
                rTags = sTags >= 0 ? pa.get(sTags) : null;
        int[] fUid = firstRows(rUid, uid.size()), fUemail = firstRows(rUemail, uemail.size()),
                fProf = firstRows(rProf, prof.size()), fAslug = firstRows(rAslug, aslug.size()), fAid = firstRows(rAid, aid.size());
        Page[] gCmts = new Page[cmts.size()];
        for (int i = 0; i < gCmts.length; i++) {
            gCmts[i] = new Page();
            gCmts[i].rows = rCmts;
        }
        if (rCmts != null) {
            for (int i = 0; i < rCmts.nrows; i++) {
                long k = rCmts.i64(i, 0);
                if (k >= 1 && k <= gCmts.length) gCmts[(int) k - 1].add(i);
            }
        }
        ListRes lGlobal = decodeList(sGlobal >= 0 ? pa.get(sGlobal) : null, 1, global.size());
        ListRes[] lList = new ListRes[3];
        for (int f = 0; f < 3; f++) lList[f] = decodeList(sList[f] >= 0 ? pa.get(sList[f]) : null, listCount[f].size(), listPage[f].size());
        ListRes lFeed = decodeList(sFeed >= 0 ? pa.get(sFeed) : null, feed.size(), feedPage.size());

        // ---- phase B keys ----
        Keys<Long> arts = new Keys<>();
        ArrayList<Long> artAuthor = new ArrayList<>();
        Keys<Pair> favd = new Keys<>(), foll = new Keys<>();
        for (int i = 0; i < nj; i++) {
            Job j = jobs.get(i);
            long v = j.viewer;
            switch (j.kind) {
                case Job.ARTICLE -> {
                    int r = fAslug[ask[i]];
                    if (r >= 0) addArt(rAslug, r, v, arts, artAuthor, favd, foll);
                }
                case Job.ARTICLE_ID -> {
                    int r = fAid[ask[i]];
                    if (r >= 0) addArt(rAid, r, v, arts, artAuthor, favd, foll);
                }
                case Job.GLOBAL -> addPage(lGlobal.pages[ask[i]], v, arts, artAuthor, favd, foll);
                case Job.TAG, Job.AUTHOR, Job.FAVORITED -> addPage(lList[j.kind - Job.TAG].pages[ask2[i]], v, arts, artAuthor, favd, foll);
                case Job.FEED -> addPage(lFeed.pages[ask2[i]], v, arts, artAuthor, favd, foll);
                case Job.COMMENTS -> {
                    if (v != 0) {
                        Page p = gCmts[ask[i]];
                        for (int x = 0; x < p.n; x++) if (!rCmts.isNull(p.idx[x], 2)) foll.idx(new Pair(v, rCmts.i64(p.idx[x], 6)));
                    }
                }
                case Job.PROFILE -> {
                    int r = fProf[ask[i]];
                    if (v != 0 && r >= 0) foll.idx(new Pair(v, rProf.i64(r, 1)));
                }
                default -> {
                }
            }
        }

        // ---- phase B ----
        Pg.Rows rArtx = null, rFlags = null;
        if (arts.size() > 0 || favd.size() + foll.size() > 0) {
            int nb = 0, bArtx = -1, bFlags = -1;
            if (arts.size() > 0) {
                pg.exec("artx", longs(arts.list), longs(artAuthor));
                bArtx = nb++;
            }
            if (favd.size() + foll.size() > 0) {
                Pg.Arr fv = new Pg.Arr(Pg.INT8), fa = new Pg.Arr(Pg.INT8), ov = new Pg.Arr(Pg.INT8), ou = new Pg.Arr(Pg.INT8);
                for (Pair p : favd.list) {
                    fv.i64(p.a);
                    fa.i64(p.b);
                }
                for (Pair p : foll.list) {
                    ov.i64(p.a);
                    ou.i64(p.b);
                }
                pg.exec("flags", fv.done(), fa.done(), ov.done(), ou.done());
                bFlags = nb++;
            }
            List<Pg.Rows> pb = pg.run();
            for (Pg.Rows r : pb) if (r.failed()) throw new Pg.Error("phase B: " + r.sqlstate + " " + r.message);
            if (bArtx >= 0) rArtx = pb.get(bArtx);
            if (bFlags >= 0) rFlags = pb.get(bFlags);
        }
        int[] artRow = new int[arts.size()];
        Arrays.fill(artRow, -1);
        if (rArtx != null) {
            for (int i = 0; i < rArtx.nrows; i++) {
                int k = arts.find(rArtx.i64(i, 0));
                if (k >= 0) artRow[k] = i;
            }
        }
        boolean[] isFav = new boolean[favd.size()], isFoll = new boolean[foll.size()];
        if (rFlags != null) {
            for (int i = 0; i < rFlags.nrows; i++) {
                long kind = rFlags.i64(i, 0);
                Pair p = new Pair(rFlags.i64(i, 1), rFlags.i64(i, 2));
                if (kind == 0) {
                    int k = favd.find(p);
                    if (k >= 0) isFav[k] = true;
                } else {
                    int k = foll.find(p);
                    if (k >= 0) isFoll[k] = true;
                }
            }
        }
        HashMap<Integer, Integer> tagRank = new HashMap<>();
        if (rTags != null) for (int i = 0; i < rTags.nrows; i++) tagRank.put((int) rTags.i64(i, 0), i);
        Ctx ctx = new Ctx(rArtx, arts, artRow, rTags, tagRank, favd, foll, isFav, isFoll);

        // ---- assemble ----
        for (int i = 0; i < nj; i++) {
            Job j = jobs.get(i);
            long v = j.viewer;
            switch (j.kind) {
                case Job.TAGS -> {
                    Buf b = new Buf(4096);
                    b.ascii("{\"tags\":[");
                    for (int r = 0; r < rTags.nrows; r++) {
                        if (r > 0) b.b(',');
                        rTags.json(b, r, 1);
                    }
                    b.ascii("]}");
                    out.add(new Http.Resp(j.conn, Http.json(200, b)));
                }
                case Job.USER -> {
                    int r = fUid[ask[i]];
                    if (r < 0) {
                        out.add(new Http.Resp(j.conn, E401));
                        break;
                    }
                    Buf b = new Buf(512);
                    b.ascii("{\"user\":{\"email\":");
                    rUid.json(b, r, 3);
                    b.ascii(",\"token\":").str(j.token).ascii(",\"username\":");
                    rUid.json(b, r, 2);
                    b.ascii(",\"bio\":");
                    rUid.json(b, r, 4);
                    b.ascii(",\"image\":");
                    rUid.json(b, r, 5);
                    b.ascii("}}");
                    out.add(new Http.Resp(j.conn, Http.json(200, b)));
                }
                case Job.LOGIN -> {
                    int r = fUemail[ask[i]];
                    if (r < 0) {
                        out.add(new Http.Resp(j.conn, E401_LOGIN));
                        break;
                    }
                    j.kind = Job.VERIFY;
                    j.id = rUemail.i64(r, 1);
                    j.uname = rUemail.bytes(r, 2);
                    j.email = rUemail.bytes(r, 3);
                    j.bio = rUemail.bytes(r, 4);
                    j.image = rUemail.bytes(r, 5);
                    j.hash = rUemail.str(r, 6);
                    verify.add(j);
                }
                case Job.PROFILE -> {
                    int r = fProf[ask[i]];
                    if (r < 0) {
                        out.add(new Http.Resp(j.conn, E404_PROFILE));
                        break;
                    }
                    Buf b = new Buf(256);
                    b.ascii("{\"profile\":{\"username\":");
                    rProf.json(b, r, 2);
                    b.ascii(",\"bio\":");
                    rProf.json(b, r, 3);
                    b.ascii(",\"image\":");
                    rProf.json(b, r, 4);
                    b.ascii(",\"following\":").bool(v != 0 && ctx.following(v, rProf.i64(r, 1))).ascii("}}");
                    out.add(new Http.Resp(j.conn, Http.json(200, b)));
                }
                case Job.ARTICLE, Job.ARTICLE_ID -> {
                    Pg.Rows rr = j.kind == Job.ARTICLE ? rAslug : rAid;
                    int r = (j.kind == Job.ARTICLE ? fAslug : fAid)[ask[i]];
                    Buf b = new Buf(2048);
                    b.ascii("{\"article\":");
                    if (r >= 0 && ctx.article(b, rr, r, true, v)) {
                        b.b('}');
                        out.add(new Http.Resp(j.conn, Http.json(j.status, b)));
                    } else out.add(new Http.Resp(j.conn, E404_ARTICLE));
                }
                case Job.COMMENTS -> {
                    Page p = gCmts[ask[i]];
                    if (p.n == 0) {
                        out.add(new Http.Resp(j.conn, E404_ARTICLE));
                        break;
                    }
                    // newest first: created_at DESC, id DESC
                    int[] idx = new int[p.n];
                    int m = 0;
                    for (int x = 0; x < p.n; x++) if (!rCmts.isNull(p.idx[x], 2) && !rCmts.isNull(p.idx[x], 7)) idx[m++] = p.idx[x];
                    sortComments(rCmts, idx, m);
                    Buf b = new Buf(64 + 400 * m);
                    b.ascii("{\"comments\":[");
                    for (int x = 0; x < m; x++) {
                        int r = idx[x];
                        if (x > 0) b.b(',');
                        b.ascii("{\"id\":").num(rCmts.i64(r, 2));
                        b.ascii(",\"createdAt\":").ts(rCmts.i64(r, 4));
                        b.ascii(",\"updatedAt\":").ts(rCmts.i64(r, 5));
                        b.ascii(",\"body\":");
                        rCmts.json(b, r, 3);
                        b.ascii(",\"author\":{\"username\":");
                        rCmts.json(b, r, 7);
                        b.ascii(",\"bio\":");
                        rCmts.json(b, r, 8);
                        b.ascii(",\"image\":");
                        rCmts.json(b, r, 9);
                        b.ascii(",\"following\":").bool(v != 0 && ctx.following(v, rCmts.i64(r, 6))).ascii("}}");
                    }
                    b.ascii("]}");
                    out.add(new Http.Resp(j.conn, Http.json(200, b)));
                }
                case Job.GLOBAL, Job.TAG, Job.AUTHOR, Job.FAVORITED, Job.FEED -> {
                    Page p;
                    long count;
                    if (j.kind == Job.GLOBAL) {
                        p = lGlobal.pages[ask[i]];
                        count = lGlobal.counts[0];
                    } else if (j.kind == Job.FEED) {
                        p = lFeed.pages[ask2[i]];
                        count = lFeed.counts[ask[i]];
                    } else {
                        ListRes lr = lList[j.kind - Job.TAG];
                        p = lr.pages[ask2[i]];
                        count = lr.counts[ask[i]];
                    }
                    Buf b = new Buf(256 + 700 * p.n);
                    b.ascii("{\"articles\":[");
                    boolean first = true;
                    for (int x = 0; x < p.n; x++) {
                        int mark = b.n;
                        if (!first) b.b(',');
                        if (ctx.article(b, p.rows, p.idx[x], false, v)) first = false;
                        else b.n = mark;
                    }
                    b.ascii("],\"articlesCount\":").num(count).b('}');
                    out.add(new Http.Resp(j.conn, Http.json(200, b)));
                }
                default -> out.add(new Http.Resp(j.conn, E500));
            }
        }
    }

    private static void sortComments(Pg.Rows r, int[] idx, int m) {
        for (int i = 1; i < m; i++) {
            int x = idx[i];
            long c = r.i64(x, 4), id = r.i64(x, 2);
            int j = i - 1;
            while (j >= 0) {
                long cj = r.i64(idx[j], 4), idj = r.i64(idx[j], 2);
                if (cj > c || (cj == c && idj > id)) break;
                idx[j + 1] = idx[j];
                j--;
            }
            idx[j + 1] = x;
        }
    }

    private static void addArt(Pg.Rows r, int row, long v, Keys<Long> arts, ArrayList<Long> artAuthor, Keys<Pair> favd, Keys<Pair> foll) {
        long id = r.i64(row, 1), author = r.i64(row, 2);
        int k = arts.idx(id);
        if (k == artAuthor.size()) artAuthor.add(author);
        if (v != 0) {
            favd.idx(new Pair(v, id));
            foll.idx(new Pair(v, author));
        }
    }

    private static void addPage(Page p, long v, Keys<Long> arts, ArrayList<Long> artAuthor, Keys<Pair> favd, Keys<Pair> foll) {
        for (int x = 0; x < p.n; x++) addArt(p.rows, p.idx[x], v, arts, artAuthor, favd, foll);
    }

    /** Phase B's results and the per-batch article JSON fragments. */
    private static final class Ctx {
        final Pg.Rows artx;
        final Keys<Long> arts;
        final int[] artRow;
        final Pg.Rows tags;
        final HashMap<Integer, Integer> tagRank;
        final Keys<Pair> favd, foll;
        final boolean[] isFav, isFoll;
        /** viewer-independent article JSON, built once per (article, with body): [start, favorited at, following at] */
        final Buf frag = new Buf(16 * 1024);
        final HashMap<Long, int[]> fragFull = new HashMap<>(), fragList = new HashMap<>();
        final long[] tagIds = new long[64];
        final int[] ranks = new int[64];

        Ctx(Pg.Rows artx, Keys<Long> arts, int[] artRow, Pg.Rows tags, HashMap<Integer, Integer> tagRank, Keys<Pair> favd,
            Keys<Pair> foll, boolean[] isFav, boolean[] isFoll) {
            this.artx = artx;
            this.arts = arts;
            this.artRow = artRow;
            this.tags = tags;
            this.tagRank = tagRank;
            this.favd = favd;
            this.foll = foll;
            this.isFav = isFav;
            this.isFoll = isFoll;
        }

        boolean following(long v, long u) {
            int k = foll.find(new Pair(v, u));
            return k >= 0 && isFoll[k];
        }

        boolean favorited(long v, long a) {
            int k = favd.find(new Pair(v, a));
            return k >= 0 && isFav[k];
        }

        private static final int[] NONE = new int[0];

        /** Builds the fragment of article row (r, row): [k, id, author_id, slug, title, description, created_at, updated_at, body]. */
        private int[] build(Pg.Rows r, int row, boolean full) {
            if (artx == null) return NONE;
            int k = arts.find(r.i64(row, 1));
            if (k < 0 || artRow[k] < 0) return NONE;
            int x = artRow[k];
            Buf b = frag;
            int start = b.n;
            b.ascii("{\"slug\":");
            r.json(b, row, 3);
            b.ascii(",\"title\":");
            r.json(b, row, 4);
            b.ascii(",\"description\":");
            r.json(b, row, 5);
            if (full) {
                b.ascii(",\"body\":");
                r.json(b, row, 8);
            }
            b.ascii(",\"tagList\":[");
            if (!artx.isNull(x, 1)) {
                int n = Pg.arrayInts(artx.buf, artx.off(x, 1), artx.len(x, 1), tagIds);
                int m = 0;
                for (int i = 0; i < n; i++) {
                    Integer rank = tagRank.get((int) tagIds[i]);
                    if (rank != null) ranks[m++] = rank;
                }
                Arrays.sort(ranks, 0, m);
                for (int i = 0; i < m; i++) {
                    if (i > 0) b.b(',');
                    tags.json(b, ranks[i], 1);
                }
            }
            b.ascii("],\"createdAt\":").ts(r.i64(row, 6));
            b.ascii(",\"updatedAt\":").ts(r.i64(row, 7));
            b.ascii(",\"favorited\":");
            int fav = b.n;
            b.ascii(",\"favoritesCount\":").num(artx.i64(x, 2));
            b.ascii(",\"author\":{\"username\":");
            artx.json(b, x, 3);
            b.ascii(",\"bio\":");
            artx.json(b, x, 4);
            b.ascii(",\"image\":");
            artx.json(b, x, 5);
            b.ascii(",\"following\":");
            return new int[] {start, fav, b.n};
        }

        /** Writes one Article object for viewer v; false (nothing written) if its phase-B row is missing. */
        boolean article(Buf b, Pg.Rows r, int row, boolean full, long v) {
            long id = r.i64(row, 1);
            HashMap<Long, int[]> cache = full ? fragFull : fragList;
            int[] f = cache.get(id);
            if (f == null) {
                f = build(r, row, full);
                cache.put(id, f);
            }
            if (f.length == 0) return false;
            b.raw(frag.a, f[0], f[1] - f[0]);
            b.bool(v != 0 && favorited(v, id));
            b.raw(frag.a, f[1], f[2] - f[1]);
            b.bool(v != 0 && following(v, r.i64(row, 2)));
            b.ascii("}}");
            return true;
        }
    }
}
