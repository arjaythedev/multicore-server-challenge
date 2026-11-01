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

    private static final byte[] E500 = Http.error(500, "internal error");
    private static final byte[] E401 = Http.error(401, "unauthorized");
    private static final byte[] E401_LOGIN = Http.error(401, "invalid email or password");
    private static final byte[] E404_ARTICLE = Http.error(404, "article not found");
    private static final byte[] E404_PROFILE = Http.error(404, "profile not found");

    private final Lanes.Settings s;
    private Pg pg;
    /** The second connection: the feed statement, the costliest one, runs on its own backend next to the rest of phase A. */
    private Pg feedPg;
    /** Response bodies are built here and copied once, at their exact size, behind their headers. */
    private final Buf body = new Buf(64 * 1024);

    ReadLane(Lanes.Settings s) {
        this.s = s;
    }

    private Buf body() {
        body.n = 0;
        return body;
    }

    @Override
    public void run() {
        List<Job> jobs = new ArrayList<>(s.readMax());
        while (true) {
            jobs.clear();
            TURN.lock();
            try {
                Lanes.READS.take(s.readMin(), s.readWindowNanos(), s.readMax(), jobs);
            } catch (InterruptedException e) {
                return;
            } finally {
                TURN.unlock();
            }
            // under overload, clients give up (10 s) and close: their queued reads are dropped unrun
            jobs.removeIf(j -> j.conn.closed);
            int n = jobs.size();
            if (n == 0) continue;
            List<Http.Resp> out = new ArrayList<>(n);
            try {
                if (pg == null) pg = Lanes.connect(Sql.reads());
                if (s.feedConn() && feedPg == null) feedPg = Lanes.connect(Sql.feed());
                batch(jobs, out);
            } catch (Throwable e) {
                System.err.println("read batch failed: " + e);
                if (pg != null) pg.close();
                if (feedPg != null) feedPg.close();
                pg = null;
                feedPg = null;
                out.clear();
                for (Job j : jobs) if (!j.done) out.add(new Http.Resp(j.conn, E500));
            }
            Http.deliver(out);
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

    private static byte[] texts(List<String> l) {
        Pg.Arr a = new Pg.Arr(Pg.TEXT);
        for (String x : l) a.text(x);
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

    private void batch(List<Job> jobs, List<Http.Resp> out) throws java.io.IOException {
        int nj = jobs.size();
        boolean wantTags = false, hasArticles = false;
        LongKeys uid = new LongKeys();
        Keys<String> uemail = new Keys<>(), prof = new Keys<>(), aslug = new Keys<>(), cmts = new Keys<>();
        LongKeys aid = new LongKeys();
        Keys<LimOff> global = new Keys<>();
        @SuppressWarnings("unchecked")
        Keys<String>[] listCount = new Keys[] {new Keys<String>(), new Keys<String>(), new Keys<String>()};
        @SuppressWarnings("unchecked")
        Keys<KeyPage>[] listPage = new Keys[] {new Keys<KeyPage>(), new Keys<KeyPage>(), new Keys<KeyPage>()};
        LongKeys feed = new LongKeys();
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
        // Two segments in one flush: the tag list, current users and login lookups (a quarter of all traffic) come back
        // first and are answered, or handed to bcrypt, while Postgres works through the rest.
        Pg pg = this.pg;
        int slot1 = 0;
        int sTags = -1, sUid = -1, sUemail = -1;
        if (wantTags || hasArticles) {
            pg.exec("tags");
            sTags = slot1++;
        }
        if (uid.n > 0) {
            pg.exec("uid", uid.array());
            sUid = slot1++;
        }
        if (uemail.size() > 0) {
            pg.exec("uemail", texts(uemail.list));
            sUemail = slot1++;
        }
        int cut1 = slot1 > 0 ? pg.cut() : 0;

        // the feed statement goes out first, on its own backend
        Pg fp = s.feedConn() ? feedPg : pg;
        int sFeed = -1, feedCut = 0;
        int slot2 = 0;
        if (feed.n > 0) {
            Pg.Arr v = new Pg.Arr(Pg.INT8), l = new Pg.Arr(Pg.INT8), o = new Pg.Arr(Pg.INT8);
            for (ViewerPage x : feedPage.list) {
                v.i64(x.v);
                l.i64(x.lim);
                o.i64(x.off);
            }
            fp.exec("feed", feed.array(), v.done(), l.done(), o.done());
            if (fp != pg) {
                feedCut = fp.cut();
                fp.flush();
            } else sFeed = slot2++;
        }

        int sProf = -1, sAslug = -1, sAid = -1, sCmts = -1, sGlobal = -1;
        int[] sList = {-1, -1, -1};
        String[] listStmt = {"tag", "author", "favlist"};
        if (prof.size() > 0) {
            pg.exec("prof", texts(prof.list));
            sProf = slot2++;
        }
        if (aslug.size() > 0) {
            pg.exec("aslug", texts(aslug.list));
            sAslug = slot2++;
        }
        if (aid.n > 0) {
            pg.exec("aid", aid.array());
            sAid = slot2++;
        }
        if (cmts.size() > 0) {
            pg.exec("cmts", texts(cmts.list));
            sCmts = slot2++;
        }
        if (global.size() > 0) {
            Pg.Arr l = new Pg.Arr(Pg.INT8), o = new Pg.Arr(Pg.INT8);
            for (LimOff x : global.list) {
                l.i64(x.lim);
                o.i64(x.off);
            }
            pg.exec("global", l.done(), o.done());
            sGlobal = slot2++;
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
            sList[f] = slot2++;
        }
        int cut2 = slot2 > 0 ? pg.cut() : 0;
        pg.flush();

        // ---- the first segment: answered now ----
        Pg.Rows rUid = null, rUemail = null, rTags = null;
        if (slot1 > 0) {
            List<Pg.Rows> p1 = checked(pg.receive(cut1), "phase A");
            rTags = sTags >= 0 ? p1.get(sTags) : null;
            rUid = sUid >= 0 ? p1.get(sUid) : null;
            rUemail = sUemail >= 0 ? p1.get(sUemail) : null;
            early(jobs, ask, rTags, rUid, uid.n, rUemail, uemail.size(), out);
            Http.deliver(out);
            out.clear();
        }

        // ---- the rest of phase A ----
        List<Pg.Rows> pa = slot2 > 0 ? checked(pg.receive(cut2), "phase A") : List.of();
        Pg.Rows rFeed = feed.n == 0 ? null : fp != pg ? checked(fp.receive(feedCut), "feed").get(0) : pa.get(sFeed);
        Pg.Rows rProf = sProf >= 0 ? pa.get(sProf) : null, rAslug = sAslug >= 0 ? pa.get(sAslug) : null,
                rAid = sAid >= 0 ? pa.get(sAid) : null, rCmts = sCmts >= 0 ? pa.get(sCmts) : null;
        int[] fProf = firstRows(rProf, prof.size()), fAslug = firstRows(rAslug, aslug.size()), fAid = firstRows(rAid, aid.n);
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
        ListRes lFeed = decodeList(rFeed, feed.n, feedPage.size());

        // ---- phase B keys ----
        ArtSet as = new ArtSet();
        LongKeys authors = new LongKeys();
        PairKeys favd = new PairKeys(), foll = new PairKeys();
        for (int i = 0; i < nj; i++) {
            Job j = jobs.get(i);
            if (j.done) continue;
            long v = j.viewer;
            switch (j.kind) {
                case Job.ARTICLE -> {
                    int r = fAslug[ask[i]];
                    if (r >= 0) as.add(rAslug, r, v, favd, foll);
                }
                case Job.ARTICLE_ID -> {
                    int r = fAid[ask[i]];
                    if (r >= 0) as.add(rAid, r, v, favd, foll);
                }
                case Job.GLOBAL -> as.addPage(lGlobal.pages[ask[i]], v, favd, foll);
                case Job.TAG, Job.AUTHOR, Job.FAVORITED -> as.addPage(lList[j.kind - Job.TAG].pages[ask2[i]], v, favd, foll);
                // a feed's articles are by followed authors: no follow probe
                case Job.FEED -> as.addPage(lFeed.pages[ask2[i]], v, favd, null);
                case Job.COMMENTS -> {
                    Page p = gCmts[ask[i]];
                    for (int x = 0; x < p.n; x++) {
                        if (rCmts.isNull(p.idx[x], 2)) continue;
                        long author = rCmts.i64(p.idx[x], 6);
                        authors.idx(author);
                        if (v != 0) foll.idx(v, author);
                    }
                }
                case Job.PROFILE -> {
                    int r = fProf[ask[i]];
                    if (v != 0 && r >= 0) foll.idx(v, rProf.i64(r, 1));
                }
                default -> {
                }
            }
        }

        // ---- phase B ----
        Pg.Rows rArtrow = null, rAuser = null, rArtx = null, rFlags = null;
        LongKeys bare = as.bare();
        if (as.ids.n > 0 || authors.n > 0 || favd.n + foll.n > 0) {
            int nb = 0, bArtrow = -1, bAuser = -1, bArtx = -1, bFlags = -1;
            if (bare.n > 0) {
                pg.exec("artrow", bare.array());
                bArtrow = nb++;
            }
            if (authors.n > 0) {
                pg.exec("auser", authors.array());
                bAuser = nb++;
            }
            if (as.ids.n > 0) {
                Pg.Arr au = new Pg.Arr(Pg.INT8);
                for (int i = 0; i < as.ids.n; i++) au.i64(as.author[i]);
                pg.exec("artx", as.ids.array(), au.done());
                bArtx = nb++;
            }
            if (favd.n + foll.n > 0) {
                Pg.Arr fv = new Pg.Arr(Pg.INT8), fa = new Pg.Arr(Pg.INT8), ov = new Pg.Arr(Pg.INT8), ou = new Pg.Arr(Pg.INT8);
                for (int i = 0; i < favd.n; i++) {
                    fv.i64(favd.a[i]);
                    fa.i64(favd.b[i]);
                }
                for (int i = 0; i < foll.n; i++) {
                    ov.i64(foll.a[i]);
                    ou.i64(foll.b[i]);
                }
                pg.exec("flags", fv.done(), fa.done(), ov.done(), ou.done());
                bFlags = nb++;
            }
            List<Pg.Rows> pb = checked(pg.run(), "phase B");
            if (bArtrow >= 0) rArtrow = pb.get(bArtrow);
            if (bAuser >= 0) rAuser = pb.get(bAuser);
            if (bArtx >= 0) rArtx = pb.get(bArtx);
            if (bFlags >= 0) rFlags = pb.get(bFlags);
        }
        if (rArtrow != null) for (int i = 0; i < rArtrow.nrows; i++) as.source(rArtrow.i64(i, 1), rArtrow, i);
        int[] authorRow = new int[authors.n];
        Arrays.fill(authorRow, -1);
        if (rAuser != null) {
            for (int i = 0; i < rAuser.nrows; i++) {
                int k = authors.find(rAuser.i64(i, 0));
                if (k >= 0) authorRow[k] = i;
            }
        }
        int[] artRow = new int[as.ids.n];
        Arrays.fill(artRow, -1);
        if (rArtx != null) {
            for (int i = 0; i < rArtx.nrows; i++) {
                int k = as.ids.find(rArtx.i64(i, 0));
                if (k >= 0) artRow[k] = i;
            }
        }
        boolean[] isFav = new boolean[favd.n], isFoll = new boolean[foll.n];
        if (rFlags != null) {
            for (int i = 0; i < rFlags.nrows; i++) {
                long kind = rFlags.i64(i, 0);
                long a = rFlags.i64(i, 1), b = rFlags.i64(i, 2);
                int k = kind == 0 ? favd.find(a, b) : foll.find(a, b);
                if (k >= 0) {
                    if (kind == 0) isFav[k] = true;
                    else isFoll[k] = true;
                }
            }
        }
        Ctx ctx = new Ctx(rArtx, as, artRow, rTags, favd, foll, isFav, isFoll);

        // ---- assemble ----
        for (int i = 0; i < nj; i++) {
            Job j = jobs.get(i);
            if (j.done) continue;
            long v = j.viewer;
            switch (j.kind) {
                case Job.PROFILE -> {
                    int r = fProf[ask[i]];
                    if (r < 0) {
                        out.add(new Http.Resp(j.conn, E404_PROFILE));
                        break;
                    }
                    Buf b = body();
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
                    Buf b = body();
                    b.ascii("{\"article\":");
                    if (r >= 0 && ctx.article(b, rr, r, true, v, false)) {
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
                    for (int x = 0; x < p.n; x++) {
                        if (rCmts.isNull(p.idx[x], 2)) continue;
                        int k = authors.find(rCmts.i64(p.idx[x], 6));
                        if (k >= 0 && authorRow[k] >= 0) idx[m++] = p.idx[x];
                    }
                    sortComments(rCmts, idx, m);
                    Buf b = body();
                    b.ascii("{\"comments\":[");
                    for (int x = 0; x < m; x++) {
                        int r = idx[x];
                        long author = rCmts.i64(r, 6);
                        int ar = authorRow[authors.find(author)];
                        if (x > 0) b.b(',');
                        b.ascii("{\"id\":").num(rCmts.i64(r, 2));
                        b.ascii(",\"createdAt\":").ts(rCmts.i64(r, 4));
                        b.ascii(",\"updatedAt\":").ts(rCmts.i64(r, 5));
                        b.ascii(",\"body\":");
                        rCmts.json(b, r, 3);
                        b.ascii(",\"author\":{\"username\":");
                        rAuser.json(b, ar, 1);
                        b.ascii(",\"bio\":");
                        rAuser.json(b, ar, 2);
                        b.ascii(",\"image\":");
                        rAuser.json(b, ar, 3);
                        b.ascii(",\"following\":").bool(v != 0 && ctx.following(v, author)).ascii("}}");
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
                    Buf b = body();
                    b.ascii("{\"articles\":[");
                    boolean first = true;
                    boolean feedPageOf = j.kind == Job.FEED;
                    for (int x = 0; x < p.n; x++) {
                        int mark = b.n;
                        if (!first) b.b(',');
                        if (ctx.article(b, p.rows, p.idx[x], false, v, feedPageOf)) first = false;
                        else b.n = mark;
                    }
                    b.ascii("],\"articlesCount\":").num(count).b('}');
                    out.add(new Http.Resp(j.conn, Http.json(200, b)));
                }
                default -> out.add(new Http.Resp(j.conn, E500));
            }
        }
    }

    private static List<Pg.Rows> checked(List<Pg.Rows> rs, String what) throws Pg.Error {
        for (Pg.Rows r : rs) if (r.failed()) throw new Pg.Error(what + ": " + r.sqlstate + " " + r.message);
        return rs;
    }

    /** Answers the requests of the first segment: tag lists (one body per batch), current users; logins go to bcrypt. */
    private void early(List<Job> jobs, int[] ask, Pg.Rows rTags, Pg.Rows rUid, int nUid, Pg.Rows rUemail, int nEmail, List<Http.Resp> out) {
        int[] fUid = firstRows(rUid, nUid), fUemail = firstRows(rUemail, nEmail);
        byte[] tagsResp = null;
        List<Job> verify = null;
        for (int i = 0, n = jobs.size(); i < n; i++) {
            Job j = jobs.get(i);
            switch (j.kind) {
                case Job.TAGS -> {
                    if (tagsResp == null) {
                        Buf b = body();
                        b.ascii("{\"tags\":[");
                        for (int r = 0; r < rTags.nrows; r++) {
                            if (r > 0) b.b(',');
                            rTags.json(b, r, 1);
                        }
                        b.ascii("]}");
                        tagsResp = Http.json(200, b);
                    }
                    out.add(new Http.Resp(j.conn, tagsResp));
                    j.done = true;
                }
                case Job.USER -> {
                    int r = fUid[ask[i]];
                    if (r < 0) out.add(new Http.Resp(j.conn, E401));
                    else {
                        Buf b = body();
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
                    j.done = true;
                }
                case Job.LOGIN -> {
                    int r = fUemail[ask[i]];
                    if (r < 0) out.add(new Http.Resp(j.conn, E401_LOGIN));
                    else {
                        j.kind = Job.VERIFY;
                        j.id = rUemail.i64(r, 1);
                        j.uname = rUemail.bytes(r, 2);
                        j.email = rUemail.bytes(r, 3);
                        j.bio = rUemail.bytes(r, 4);
                        j.image = rUemail.bytes(r, 5);
                        j.hash = rUemail.str(r, 6);
                        if (verify == null) verify = new ArrayList<>();
                        verify.add(j);
                    }
                    j.done = true;
                }
                default -> {
                }
            }
        }
        if (verify != null) Lanes.BCRYPT.pushAll(verify);
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

    /** Every distinct article of a batch: its id and author, and a phase-A row with its columns, if one has them. */
    private static final class ArtSet {
        final LongKeys ids = new LongKeys();
        long[] author = new long[64];
        Pg.Rows[] src = new Pg.Rows[64];
        int[] srcRow = new int[64];

        void add(Pg.Rows r, int row, long v, PairKeys favd, PairKeys foll) {
            long id = r.i64(row, 1), au = r.i64(row, 2);
            int k = ids.idx(id);
            if (k >= author.length) {
                author = Arrays.copyOf(author, k * 2);
                src = Arrays.copyOf(src, k * 2);
                srcRow = Arrays.copyOf(srcRow, k * 2);
            }
            author[k] = au;
            if (src[k] == null && r.ncols > 3) {
                src[k] = r;
                srcRow[k] = row;
            }
            if (v != 0) {
                favd.idx(v, id);
                if (foll != null) foll.idx(v, au);
            }
        }

        void addPage(Page p, long v, PairKeys favd, PairKeys foll) {
            for (int x = 0; x < p.n; x++) add(p.rows, p.idx[x], v, favd, foll);
        }

        /** The articles no phase-A statement returned columns for. */
        LongKeys bare() {
            LongKeys b = new LongKeys();
            for (int k = 0; k < ids.n; k++) if (src[k] == null) b.idx(ids.list[k]);
            return b;
        }

        void source(long id, Pg.Rows r, int row) {
            int k = ids.find(id);
            if (k >= 0 && src[k] == null) {
                src[k] = r;
                srcRow[k] = row;
            }
        }
    }

    /** Phase B's results and the per-batch article JSON fragments. */
    private static final class Ctx {
        final Pg.Rows artx;
        final ArtSet as;
        final int[] artRow;
        final Pg.Rows tags;
        final PairKeys favd, foll;
        final boolean[] isFav, isFoll;
        /** tag id -> position in the database's name order (-1: none) */
        final int[] tagRank;
        /** viewer-independent article JSON, built once per (article, with body): [start, favorited at, following at] */
        final Buf frag = new Buf(16 * 1024);
        final int[][] fragFull, fragList;
        final long[] tagIds = new long[64];
        final int[] ranks = new int[64];

        Ctx(Pg.Rows artx, ArtSet as, int[] artRow, Pg.Rows tags, PairKeys favd, PairKeys foll, boolean[] isFav, boolean[] isFoll) {
            this.artx = artx;
            this.as = as;
            this.artRow = artRow;
            this.tags = tags;
            this.favd = favd;
            this.foll = foll;
            this.isFav = isFav;
            this.isFoll = isFoll;
            this.fragFull = new int[as.ids.n][];
            this.fragList = new int[as.ids.n][];
            int max = -1;
            if (tags != null) for (int i = 0; i < tags.nrows; i++) max = Math.max(max, (int) tags.i64(i, 0));
            tagRank = new int[max + 1];
            Arrays.fill(tagRank, -1);
            if (tags != null) for (int i = 0; i < tags.nrows; i++) tagRank[(int) tags.i64(i, 0)] = i;
        }

        boolean following(long v, long u) {
            int k = foll.find(v, u);
            return k >= 0 && isFoll[k];
        }

        boolean favorited(long v, long a) {
            int k = favd.find(v, a);
            return k >= 0 && isFav[k];
        }

        private static final int[] NONE = new int[0];

        /** Builds the fragment of article k. Columns: [k, id, author_id, slug, title, description, created_at, updated_at, body]. */
        private int[] build(int k, Pg.Rows full, int fullRow) {
            if (artx == null || artRow[k] < 0) return NONE;
            int x = artRow[k];
            Pg.Rows r = full != null ? full : as.src[k];
            int row = full != null ? fullRow : as.srcRow[k];
            if (r == null) return NONE; // deleted between the phases
            Buf b = frag;
            int start = b.n;
            b.ascii("{\"slug\":");
            r.json(b, row, 3);
            b.ascii(",\"title\":");
            r.json(b, row, 4);
            b.ascii(",\"description\":");
            r.json(b, row, 5);
            if (full != null) {
                b.ascii(",\"body\":");
                r.json(b, row, 8);
            }
            b.ascii(",\"tagList\":[");
            if (!artx.isNull(x, 1)) {
                int n = Pg.arrayInts(artx.buf, artx.off(x, 1), artx.len(x, 1), tagIds);
                int m = 0;
                for (int i = 0; i < n; i++) {
                    int id = (int) tagIds[i];
                    if (id >= 0 && id < tagRank.length && tagRank[id] >= 0) ranks[m++] = tagRank[id];
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

        /**
         * Writes one Article object for viewer v; false (nothing written) if its phase-B row is missing. followed: the
         * viewer is known to follow the author (a feed page), so there is no flag to look up.
         */
        boolean article(Buf b, Pg.Rows r, int row, boolean full, long v, boolean followed) {
            long id = r.i64(row, 1);
            int k = as.ids.find(id);
            if (k < 0) return false;
            int[][] cache = full ? fragFull : fragList;
            int[] f = cache[k];
            if (f == null) {
                f = build(k, full ? r : null, row);
                cache[k] = f;
            }
            if (f.length == 0) return false;
            b.raw(frag.a, f[0], f[1] - f[0]);
            b.bool(v != 0 && favorited(v, id));
            b.raw(frag.a, f[1], f[2] - f[1]);
            b.bool(followed || (v != 0 && following(v, r.i64(row, 2))));
            b.ascii("}}");
            return true;
        }
    }
}
