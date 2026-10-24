//! The batch planner.
//!
//! Read lanes each own one Postgres connection. A lane takes every read request waiting in the shared queue, of every
//! endpoint, and answers the whole batch in two pipelined round trips:
//!
//! - phase A resolves what each request is about: identical keys collapse to one row of a parameter array (one
//!   global page per (limit, offset), one lookup per slug, one count per tag, ...);
//! - phase B enriches the union of every article and user phase A referenced, once each (tags, favorite counts,
//!   author rows), plus the per-viewer `favorited` / `following` flags as primary-key probes.
//!
//! Every value in a response was read from Postgres during that request's batch; nothing outlives the batch.
//! Writes go through one write lane with group commit; responses are released after COMMIT returns.

use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hash, Hasher};
use std::time::Duration;

use crate::json;
use crate::pg::{self, ArrayBuf, Col, Conn, Param, Pipeline, INT8, TEXT};
use crate::queue::Queue;
use crate::reply::{self, ReplyTo, Response};

// ------------------------------------------------------------------------------------------------------------------
// jobs

pub enum Read {
    Tags,
    CurrentUser { id: i64, token: String },
    Login { email: String, password: Vec<u8> },
    Profile { username: String },
    Article { slug: String },
    ArticleId { id: i64, status: u16 },
    Comments { slug: String },
    Global { lim: i64, off: i64 },
    Tag { tag: String, lim: i64, off: i64 },
    Author { username: String, lim: i64, off: i64 },
    Favorited { username: String, lim: i64, off: i64 },
    Feed { lim: i64, off: i64 },
}

pub struct ReadJob {
    pub kind: Read,
    pub viewer: i64,
    pub to: ReplyTo,
}

pub enum Write {
    Register { username: String, email: String, hash: String },
    UpdateUser { token: String, email: Option<String>, username: Option<String>, hash: Option<String>, bio: Option<String>, image: Option<String> },
    Follow { username: String, on: bool },
    Favorite { slug: String, on: bool },
    CreateArticle { title: String, description: String, body: String, tags: Vec<String> },
    UpdateArticle { slug: String, title: Option<String>, description: Option<String>, body: Option<String> },
    DeleteArticle { slug: String },
    CreateComment { slug: String, body: String },
    DeleteComment { slug: String, id: i64 },
}

pub struct WriteJob {
    pub kind: Write,
    pub viewer: i64,
    pub to: ReplyTo,
}

pub enum BcryptJob {
    /// Verify a login; on success answer 200 with the user and a fresh token.
    Verify { password: Vec<u8>, hash: Vec<u8>, user: UserOut, to: ReplyTo },
    /// Hash a new password, store it in the write job, then queue the write.
    Hash { password: Vec<u8>, write: WriteJob },
}

pub struct UserOut {
    pub id: i64,
    pub username: Vec<u8>,
    pub email: Vec<u8>,
    pub bio: Option<Vec<u8>>,
    pub image: Option<Vec<u8>>,
}

pub static READS: Queue<ReadJob> = Queue::new();
/// Held by the read lane that is currently forming a batch.
static GATHER: std::sync::Mutex<()> = std::sync::Mutex::new(());
pub static WRITES: Queue<WriteJob> = Queue::new();
pub static BCRYPT: Queue<BcryptJob> = Queue::new();

pub struct Settings {
    pub cfg: pg::Config,
    pub keys: &'static crate::jwt::Keys,
    pub read_batch: usize,
    pub read_min: usize,
    pub read_window: Duration,
    pub write_batch: usize,
    pub bcrypt_lanes: usize,
    pub bcrypt_window: Duration,
}

// ------------------------------------------------------------------------------------------------------------------
// small helpers

#[derive(Default)]
pub struct Fx(u64);
impl Hasher for Fx {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ b as u64).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
        }
    }
    fn write_u64(&mut self, v: u64) {
        self.0 = (self.0.rotate_left(5) ^ v).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
    }
    fn write_i64(&mut self, v: i64) {
        self.write_u64(v as u64)
    }
}
type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;

/// Distinct keys of one statement in one batch; a key's position + 1 is its `k` in SQL.
struct Keys<K: Hash + Eq + Clone> {
    map: FxMap<K, u32>,
    list: Vec<K>,
}

impl<K: Hash + Eq + Clone> Keys<K> {
    fn new() -> Self {
        Keys { map: FxMap::default(), list: Vec::new() }
    }
    fn idx(&mut self, key: K) -> u32 {
        if let Some(&i) = self.map.get(&key) {
            return i;
        }
        let i = self.list.len() as u32;
        self.map.insert(key.clone(), i);
        self.list.push(key);
        i
    }
    fn len(&self) -> usize {
        self.list.len()
    }
}

/// Rows of a statement result grouped by their `k` (column 0), as row indices.
fn group(p: &Pipeline, res: usize, n: usize) -> Vec<Vec<usize>> {
    let mut g = vec![Vec::new(); n];
    for (i, row) in p.results[res].rows.iter().enumerate() {
        let k = p.i64(row[0]);
        if k >= 1 && (k as usize) <= n {
            g[k as usize - 1].push(i);
        }
    }
    g
}

fn text_array<'a>(items: impl Iterator<Item = &'a [u8]>) -> Vec<u8> {
    let mut a = ArrayBuf::new(TEXT);
    for s in items {
        a.text(s);
    }
    a.finish();
    a.buf
}

fn int_array(items: impl Iterator<Item = i64>) -> Vec<u8> {
    let mut a = ArrayBuf::new(INT8);
    for v in items {
        a.i64(v);
    }
    a.finish();
    a.buf
}

fn owned(p: &Pipeline, c: Col) -> Option<Vec<u8>> {
    p.bytes(c).map(|b| b.to_vec())
}

// ------------------------------------------------------------------------------------------------------------------
// JSON fragments

pub fn user_json(out: &mut Vec<u8>, email: &[u8], token: &[u8], username: &[u8], bio: Option<&[u8]>, image: Option<&[u8]>) {
    out.extend_from_slice(b"{\"user\":{\"email\":");
    json::str(out, email);
    out.extend_from_slice(b",\"token\":");
    json::str(out, token);
    out.extend_from_slice(b",\"username\":");
    json::str(out, username);
    out.extend_from_slice(b",\"bio\":");
    json::opt_str(out, bio);
    out.extend_from_slice(b",\"image\":");
    json::opt_str(out, image);
    out.extend_from_slice(b"}}");
}

fn profile_obj(out: &mut Vec<u8>, username: &[u8], bio: Option<&[u8]>, image: Option<&[u8]>, following: bool) {
    out.extend_from_slice(b"{\"username\":");
    json::str(out, username);
    out.extend_from_slice(b",\"bio\":");
    json::opt_str(out, bio);
    out.extend_from_slice(b",\"image\":");
    json::opt_str(out, image);
    out.extend_from_slice(b",\"following\":");
    json::bool(out, following);
    out.push(b'}');
}

// ------------------------------------------------------------------------------------------------------------------
// the read lane

/// What one job asked phase A for (indices into that statement's distinct keys).
#[derive(Clone, Copy)]
enum Ask {
    Tags,
    User(u32),
    Login(u32),
    Profile(u32),
    Slug(u32),
    Id(u32),
    Comments(u32),
    Global(u32),
    /// filter (0 = tag, 1 = author, 2 = favorited), count key, page key
    List(usize, u32, u32),
    /// viewer key (count), (viewer, limit, offset) key (page)
    Feed(u32, u32),
}

/// Distinct keys of one filtered list kind.
struct ListKeys {
    count: Keys<String>,
    page: Keys<(String, i64, i64)>,
}

impl ListKeys {
    fn new() -> Self {
        ListKeys { count: Keys::new(), page: Keys::new() }
    }
}

/// A phase-A article row: (article id, author id, the row's columns).
type ArtRef<'p> = (i64, i64, &'p [Col]);
/// A list page, newest first.
type PageRows<'p> = Vec<ArtRef<'p>>;

pub struct ReadLane {
    conn: Option<Conn>,
    s: &'static Settings,
}

const LIST_STMTS: [&str; 3] = ["tag", "author", "favlist"];

impl ReadLane {
    pub fn new(s: &'static Settings) -> ReadLane {
        ReadLane { conn: None, s }
    }

    fn conn(&mut self) -> pg::Result<&mut Conn> {
        if self.conn.is_none() {
            let mut c = Conn::connect(&self.s.cfg)?;
            let stmts = crate::sql::read_statements();
            let list: Vec<(&str, &str, &[u32])> = stmts.iter().map(|s| (s.name, s.sql.as_str(), s.types)).collect();
            c.prepare_all(&list)?;
            self.conn = Some(c);
        }
        Ok(self.conn.as_mut().unwrap())
    }

    pub fn run(mut self) {
        let mut jobs = Vec::with_capacity(self.s.read_batch);
        loop {
            jobs.clear();
            {
                // Lanes take turns forming batches: one lane collects (up to the window, or until the batch is big
                // enough) while the others execute theirs. Batches stay large at any load instead of being whatever
                // trickled in since the last lane freed up.
                let _turn = GATHER.lock().unwrap();
                READS.take_window(self.s.read_min, self.s.read_window, self.s.read_batch, &mut jobs);
            }
            let batch = std::mem::take(&mut jobs);
            let tos: Vec<ReplyTo> = batch.iter().map(|j| j.to).collect();
            if let Err(e) = self.batch(batch) {
                eprintln!("read batch failed: {e}");
                self.conn = None;
                reply::send_all(tos.into_iter().map(|t| reply::error(t, 500, "internal error")).collect());
            }
        }
    }

    fn batch(&mut self, jobs: Vec<ReadJob>) -> pg::Result<()> {
        // ---- distinct keys ----
        let mut want_tags = false;
        let mut uid: Keys<i64> = Keys::new();
        let mut uemail: Keys<String> = Keys::new();
        let mut prof: Keys<String> = Keys::new();
        let mut aslug: Keys<String> = Keys::new();
        let mut aid: Keys<i64> = Keys::new();
        let mut cmts: Keys<String> = Keys::new();
        let mut global: Keys<(i64, i64)> = Keys::new();
        let mut lists = [ListKeys::new(), ListKeys::new(), ListKeys::new()];
        let mut feed: Keys<i64> = Keys::new();
        let mut feedpage: Keys<(i64, i64, i64)> = Keys::new();

        let asks: Vec<Ask> = jobs
            .iter()
            .map(|j| match &j.kind {
                Read::Tags => {
                    want_tags = true;
                    Ask::Tags
                }
                Read::CurrentUser { id, .. } => Ask::User(uid.idx(*id)),
                Read::Login { email, .. } => Ask::Login(uemail.idx(email.clone())),
                Read::Profile { username } => Ask::Profile(prof.idx(username.clone())),
                Read::Article { slug } => Ask::Slug(aslug.idx(slug.clone())),
                Read::ArticleId { id, .. } => Ask::Id(aid.idx(*id)),
                Read::Comments { slug } => Ask::Comments(cmts.idx(slug.clone())),
                Read::Global { lim, off } => Ask::Global(global.idx((*lim, *off))),
                Read::Tag { tag: key, lim, off } | Read::Author { username: key, lim, off } | Read::Favorited { username: key, lim, off } => {
                    let f = match &j.kind {
                        Read::Tag { .. } => 0,
                        Read::Author { .. } => 1,
                        _ => 2,
                    };
                    let l = &mut lists[f];
                    Ask::List(f, l.count.idx(key.clone()), l.page.idx((key.clone(), *lim, *off)))
                }
                Read::Feed { lim, off } => Ask::Feed(feed.idx(j.viewer), feedpage.idx((j.viewer, *lim, *off))),
            })
            .collect();

        // ---- phase A ----
        let conn = self.conn()?;
        let mut n = 0usize;
        let mut slot = |cond: bool| -> Option<usize> {
            if cond {
                n += 1;
                Some(n - 1)
            } else {
                None
            }
        };
        let s_tags = slot(want_tags);
        let s_uid = slot(uid.len() > 0);
        let s_uemail = slot(uemail.len() > 0);
        let s_prof = slot(prof.len() > 0);
        let s_aslug = slot(aslug.len() > 0);
        let s_aid = slot(aid.len() > 0);
        let s_cmts = slot(cmts.len() > 0);
        let s_global = slot(global.len() > 0);
        let s_lists: [Option<usize>; 3] = std::array::from_fn(|f| slot(lists[f].page.len() > 0));
        let s_feed = slot(feed.len() > 0);

        let o = &mut conn.out;
        let texts = |k: &Keys<String>| text_array(k.list.iter().map(|s| s.as_bytes()));
        if s_tags.is_some() {
            o.bind_exec("tags", &[]);
        }
        if s_uid.is_some() {
            o.bind_exec("uid", &[Param::Raw(&int_array(uid.list.iter().copied()))]);
        }
        if s_uemail.is_some() {
            o.bind_exec("uemail", &[Param::Raw(&texts(&uemail))]);
        }
        if s_prof.is_some() {
            o.bind_exec("prof", &[Param::Raw(&texts(&prof))]);
        }
        if s_aslug.is_some() {
            o.bind_exec("aslug", &[Param::Raw(&texts(&aslug))]);
        }
        if s_aid.is_some() {
            o.bind_exec("aid", &[Param::Raw(&int_array(aid.list.iter().copied()))]);
        }
        if s_cmts.is_some() {
            o.bind_exec("cmts", &[Param::Raw(&texts(&cmts))]);
        }
        if s_global.is_some() {
            o.bind_exec(
                "global",
                &[Param::Raw(&int_array(global.list.iter().map(|k| k.0))), Param::Raw(&int_array(global.list.iter().map(|k| k.1)))],
            );
        }
        for f in 0..3 {
            if s_lists[f].is_some() {
                let l = &lists[f];
                o.bind_exec(
                    LIST_STMTS[f],
                    &[
                        Param::Raw(&texts(&l.count)),
                        Param::Raw(&text_array(l.page.list.iter().map(|k| k.0.as_bytes()))),
                        Param::Raw(&int_array(l.page.list.iter().map(|k| k.1))),
                        Param::Raw(&int_array(l.page.list.iter().map(|k| k.2))),
                    ],
                );
            }
        }
        if s_feed.is_some() {
            o.bind_exec(
                "feed",
                &[
                    Param::Raw(&int_array(feed.list.iter().copied())),
                    Param::Raw(&int_array(feedpage.list.iter().map(|k| k.0))),
                    Param::Raw(&int_array(feedpage.list.iter().map(|k| k.1))),
                    Param::Raw(&int_array(feedpage.list.iter().map(|k| k.2))),
                ],
            );
        }
        o.sync();
        conn.flush()?;
        let pa = conn.read_pipeline(n)?;
        if let Some(r) = pa.results.iter().find(|r| r.error.is_some()) {
            return Err(pg::Error::Protocol(format!("phase A: {}", r.error.as_ref().unwrap())));
        }

        // ---- decode phase A ----
        let g = |slot: Option<usize>, n: usize| slot.map(|s| group(&pa, s, n)).unwrap_or_default();
        let g_uid = g(s_uid, uid.len());
        let g_uemail = g(s_uemail, uemail.len());
        let g_prof = g(s_prof, prof.len());
        let g_cmts = g(s_cmts, cmts.len());
        let first_row = |slot: Option<usize>, n: usize| -> Vec<Option<ArtRef>> {
            let mut v = vec![None; n];
            if let Some(s) = slot {
                for r in &pa.results[s].rows {
                    let k = pa.i64(r[0]);
                    if k >= 1 && (k as usize) <= n {
                        v[k as usize - 1] = Some((pa.i64(r[1]), pa.i64(r[2]), &r[..]));
                    }
                }
            }
            v
        };
        let by_slug = first_row(s_aslug, aslug.len());
        let by_id = first_row(s_aid, aid.len());

        // list statements: k < 0 -> count of count key -k (k = 0 -> the single global count), k > 0 -> page row
        let decode_list = |slot: Option<usize>, ncount: usize, npage: usize| -> (Vec<i64>, Vec<PageRows>) {
            let mut counts = vec![0i64; ncount.max(1)];
            let mut pages: Vec<PageRows> = vec![Vec::new(); npage];
            if let Some(s) = slot {
                for r in &pa.results[s].rows {
                    let k = pa.i64(r[0]);
                    if k <= 0 {
                        let i = (-k) as usize;
                        let i = if i == 0 { 0 } else { i - 1 };
                        if i < counts.len() {
                            counts[i] = pa.i64(r[1]);
                        }
                    } else if (k as usize) <= npage {
                        pages[k as usize - 1].push((pa.i64(r[1]), pa.i64(r[2]), &r[..]));
                    }
                }
                for p in &mut pages {
                    p.sort_unstable_by(|a, b| b.0.cmp(&a.0));
                }
            }
            (counts, pages)
        };
        let (gcount, gpages) = decode_list(s_global, 1, global.len());
        let decoded: Vec<(Vec<i64>, Vec<PageRows>)> =
            (0..3).map(|f| decode_list(s_lists[f], lists[f].count.len(), lists[f].page.len())).collect();

        let (fcount, fpages) = decode_list(s_feed, feed.len(), feedpage.len());

        // ---- phase B keys ----
        let mut arts: Keys<i64> = Keys::new();
        let mut art_author: Vec<i64> = Vec::new();
        let mut favd: Keys<(i64, i64)> = Keys::new();
        let mut foll: Keys<(i64, i64)> = Keys::new();
        let mut add_art = |id: i64, author: i64, v: i64, arts: &mut Keys<i64>, favd: &mut Keys<(i64, i64)>, foll: &mut Keys<(i64, i64)>| {
            let i = arts.idx(id) as usize;
            if art_author.len() <= i {
                art_author.push(author);
            }
            if v != 0 {
                favd.idx((v, id));
                foll.idx((v, author));
            }
        };
        for (j, a) in jobs.iter().zip(asks.iter()) {
            let v = j.viewer;
            match *a {
                Ask::Slug(k) | Ask::Id(k) => {
                    let p = if let Ask::Slug(_) = a { by_slug[k as usize] } else { by_id[k as usize] };
                    if let Some((id, author, _)) = p {
                        add_art(id, author, v, &mut arts, &mut favd, &mut foll);
                    }
                }
                Ask::Global(p) => {
                    for &(id, author, _) in &gpages[p as usize] {
                        add_art(id, author, v, &mut arts, &mut favd, &mut foll);
                    }
                }
                Ask::List(f, _, p) => {
                    for &(id, author, _) in &decoded[f].1[p as usize] {
                        add_art(id, author, v, &mut arts, &mut favd, &mut foll);
                    }
                }
                Ask::Feed(_, p) => {
                    for &(id, author, _) in &fpages[p as usize] {
                        add_art(id, author, v, &mut arts, &mut favd, &mut foll);
                    }
                }
                Ask::Comments(k) => {
                    if v != 0 {
                        if let Some(s) = s_cmts {
                            for &i in &g_cmts[k as usize] {
                                let r = &pa.results[s].rows[i];
                                if r[2].len >= 0 {
                                    foll.idx((v, pa.i64(r[6])));
                                }
                            }
                        }
                    }
                }
                Ask::Profile(k) => {
                    if v != 0 {
                        if let (Some(s), Some(&i)) = (s_prof, g_prof[k as usize].first()) {
                            foll.idx((v, pa.i64(pa.results[s].rows[i][1])));
                        }
                    }
                }
                Ask::Tags | Ask::User(_) | Ask::Login(_) => {}
            }
        }

        // ---- phase B ----
        let mut nb = 0usize;
        let mut slotb = |cond: bool| -> Option<usize> {
            if cond {
                nb += 1;
                Some(nb - 1)
            } else {
                None
            }
        };
        let b_artx = slotb(arts.len() > 0);
        let b_tagn = slotb(arts.len() > 0);
        let b_flags = slotb(favd.len() + foll.len() > 0);
        let pb = if nb > 0 {
            let ids = int_array(arts.list.iter().copied());
            let o = &mut conn.out;
            if b_artx.is_some() {
                o.bind_exec("artx", &[Param::Raw(&ids), Param::Raw(&int_array(art_author.iter().copied()))]);
                o.bind_exec("tagnames", &[Param::Raw(&ids)]);
            }
            if b_flags.is_some() {
                o.bind_exec(
                    "flags",
                    &[
                        Param::Raw(&int_array(favd.list.iter().map(|p| p.0))),
                        Param::Raw(&int_array(favd.list.iter().map(|p| p.1))),
                        Param::Raw(&int_array(foll.list.iter().map(|p| p.0))),
                        Param::Raw(&int_array(foll.list.iter().map(|p| p.1))),
                    ],
                );
            }
            o.sync();
            conn.flush()?;
            let pb = conn.read_pipeline(nb)?;
            if let Some(r) = pb.results.iter().find(|r| r.error.is_some()) {
                return Err(pg::Error::Protocol(format!("phase B: {}", r.error.as_ref().unwrap())));
            }
            Some(pb)
        } else {
            None
        };

        let mut art_row: Vec<Option<usize>> = vec![None; arts.len()];
        let mut tag_rank: FxMap<i32, (u32, Col)> = FxMap::default();
        let mut is_fav = vec![false; favd.len()];
        let mut is_foll = vec![false; foll.len()];
        if let Some(pb) = &pb {
            if let Some(s) = b_artx {
                for (i, r) in pb.results[s].rows.iter().enumerate() {
                    if let Some(&k) = arts.map.get(&pb.i64(r[0])) {
                        art_row[k as usize] = Some(i);
                    }
                }
            }
            if let Some(s) = b_tagn {
                for (i, r) in pb.results[s].rows.iter().enumerate() {
                    tag_rank.insert(pb.i64(r[0]) as i32, (i as u32, r[1]));
                }
            }
            if let Some(s) = b_flags {
                for r in &pb.results[s].rows {
                    let (kind, v, x) = (pb.i64(r[0]), pb.i64(r[1]), pb.i64(r[2]));
                    let (keys, target) = if kind == 0 { (&favd, &mut is_fav) } else { (&foll, &mut is_foll) };
                    if let Some(&k) = keys.map.get(&(v, x)) {
                        target[k as usize] = true;
                    }
                }
            }
        }
        let ctx = Ctx { pb: pb.as_ref(), b_artx, arts: &arts, art_row: &art_row, tag_rank: &tag_rank, favd: &favd, foll: &foll, is_fav: &is_fav, is_foll: &is_foll };

        // ---- assemble ----
        let mut out: Vec<Response> = Vec::with_capacity(jobs.len());
        for (j, ask) in jobs.into_iter().zip(asks.into_iter()) {
            let v = j.viewer;
            let to = j.to;
            match ask {
                Ask::Tags => {
                    let s = s_tags.unwrap();
                    let mut b = Vec::with_capacity(4096);
                    b.extend_from_slice(b"{\"tags\":[");
                    if let Some(arr) = pa.results[s].rows.first().and_then(|r| pa.bytes(r[0])) {
                        for (i, t) in pg::array_elems(arr).enumerate() {
                            if i > 0 {
                                b.push(b',');
                            }
                            json::str(&mut b, t);
                        }
                    }
                    b.extend_from_slice(b"]}");
                    out.push(Response { to, status: 200, body: b });
                }
                Ask::User(k) => {
                    let Read::CurrentUser { token, .. } = j.kind else { unreachable!() };
                    match g_uid[k as usize].first() {
                        Some(&i) => {
                            let r = &pa.results[s_uid.unwrap()].rows[i];
                            let mut b = Vec::with_capacity(512);
                            user_json(&mut b, pa.bytes(r[3]).unwrap_or(b""), token.as_bytes(), pa.bytes(r[2]).unwrap_or(b""), pa.bytes(r[4]), pa.bytes(r[5]));
                            out.push(Response { to, status: 200, body: b });
                        }
                        None => out.push(reply::error(to, 401, "unauthorized")),
                    }
                }
                Ask::Login(k) => {
                    let Read::Login { password, .. } = j.kind else { unreachable!() };
                    match g_uemail[k as usize].first() {
                        Some(&i) => {
                            let r = &pa.results[s_uemail.unwrap()].rows[i];
                            let user = UserOut {
                                id: pa.i64(r[1]),
                                username: owned(&pa, r[2]).unwrap_or_default(),
                                email: owned(&pa, r[3]).unwrap_or_default(),
                                bio: owned(&pa, r[4]),
                                image: owned(&pa, r[5]),
                            };
                            let hash = owned(&pa, r[6]).unwrap_or_default();
                            BCRYPT.push_all(BcryptJob::Verify { password, hash, user, to });
                        }
                        None => out.push(reply::error(to, 401, "invalid email or password")),
                    }
                }
                Ask::Profile(k) => match g_prof[k as usize].first() {
                    Some(&i) => {
                        let r = &pa.results[s_prof.unwrap()].rows[i];
                        let following = v != 0 && ctx.following(v, pa.i64(r[1]));
                        let mut b = Vec::with_capacity(256);
                        b.extend_from_slice(b"{\"profile\":");
                        profile_obj(&mut b, pa.bytes(r[2]).unwrap_or(b""), pa.bytes(r[3]), pa.bytes(r[4]), following);
                        b.push(b'}');
                        out.push(Response { to, status: 200, body: b });
                    }
                    None => out.push(reply::error(to, 404, "profile not found")),
                },
                Ask::Slug(k) | Ask::Id(k) => {
                    let p = if let Ask::Slug(_) = ask { by_slug[k as usize] } else { by_id[k as usize] };
                    let status = match j.kind {
                        Read::ArticleId { status, .. } => status,
                        _ => 200,
                    };
                    let mut b = Vec::with_capacity(2048);
                    b.extend_from_slice(b"{\"article\":");
                    if p.is_some_and(|a| ctx.article(&mut b, &pa, a, true, v)) {
                        b.push(b'}');
                        out.push(Response { to, status, body: b });
                    } else {
                        out.push(reply::error(to, 404, "article not found"));
                    }
                }
                Ask::Comments(k) => {
                    let rows = &g_cmts[k as usize];
                    if rows.is_empty() {
                        out.push(reply::error(to, 404, "article not found"));
                        continue;
                    }
                    let s = s_cmts.unwrap();
                    let mut list: Vec<&Vec<Col>> = rows.iter().map(|&i| &pa.results[s].rows[i]).filter(|r| r[2].len >= 0 && r[7].len >= 0).collect();
                    list.sort_unstable_by(|x, y| (pa.i64(y[4]), pa.i64(y[2])).cmp(&(pa.i64(x[4]), pa.i64(x[2]))));
                    let mut b = Vec::with_capacity(64 + 400 * list.len());
                    b.extend_from_slice(b"{\"comments\":[");
                    for (n, r) in list.into_iter().enumerate() {
                        if n > 0 {
                            b.push(b',');
                        }
                        b.extend_from_slice(b"{\"id\":");
                        json::int(&mut b, pa.i64(r[2]));
                        b.extend_from_slice(b",\"createdAt\":");
                        json::ts(&mut b, pa.i64(r[4]));
                        b.extend_from_slice(b",\"updatedAt\":");
                        json::ts(&mut b, pa.i64(r[5]));
                        b.extend_from_slice(b",\"body\":");
                        json::str(&mut b, pa.bytes(r[3]).unwrap_or(b""));
                        b.extend_from_slice(b",\"author\":");
                        let following = v != 0 && ctx.following(v, pa.i64(r[6]));
                        profile_obj(&mut b, pa.bytes(r[7]).unwrap_or(b""), pa.bytes(r[8]), pa.bytes(r[9]), following);
                        b.push(b'}');
                    }
                    b.extend_from_slice(b"]}");
                    out.push(Response { to, status: 200, body: b });
                }
                Ask::Global(_) | Ask::List(..) | Ask::Feed(..) => {
                    let (rows, count): (&PageRows, i64) = match ask {
                        Ask::Global(p) => (&gpages[p as usize], gcount[0]),
                        Ask::List(f, c, p) => (&decoded[f].1[p as usize], decoded[f].0[c as usize]),
                        Ask::Feed(c, p) => (&fpages[p as usize], fcount[c as usize]),
                        _ => unreachable!(),
                    };
                    let mut b = Vec::with_capacity(512 + 700 * rows.len());
                    b.extend_from_slice(b"{\"articles\":[");
                    let mut first = true;
                    for &a in rows {
                        let mark = b.len();
                        if !first {
                            b.push(b',');
                        }
                        if ctx.article(&mut b, &pa, a, false, v) {
                            first = false;
                        } else {
                            b.truncate(mark);
                        }
                    }
                    b.extend_from_slice(b"],\"articlesCount\":");
                    json::int(&mut b, count);
                    b.push(b'}');
                    out.push(Response { to, status: 200, body: b });
                }
            }
        }
        reply::send_all(out);
        Ok(())
    }
}

struct Ctx<'a> {
    pb: Option<&'a Pipeline>,
    b_artx: Option<usize>,
    arts: &'a Keys<i64>,
    art_row: &'a [Option<usize>],
    tag_rank: &'a FxMap<i32, (u32, Col)>,
    favd: &'a Keys<(i64, i64)>,
    foll: &'a Keys<(i64, i64)>,
    is_fav: &'a [bool],
    is_foll: &'a [bool],
}

impl Ctx<'_> {
    fn following(&self, v: i64, u: i64) -> bool {
        self.foll.map.get(&(v, u)).map(|&k| self.is_foll[k as usize]).unwrap_or(false)
    }
    fn favorited(&self, v: i64, a: i64) -> bool {
        self.favd.map.get(&(v, a)).map(|&k| self.is_fav[k as usize]).unwrap_or(false)
    }

    /// Writes one Article object. `a` is its phase-A row [k, id, author_id, slug, title, description, created_at,
    /// updated_at (, body)]; the phase-B artx row is [id, tag_ids, favorites, username, bio, image]. Returns false
    /// (writing nothing) if the author vanished between the two phases.
    fn article(&self, b: &mut Vec<u8>, pa: &Pipeline, a: ArtRef, full: bool, v: i64) -> bool {
        let (id, author, ar) = a;
        let Some(pb) = self.pb else { return false };
        let Some(ri) = self.arts.map.get(&id).and_then(|&k| self.art_row[k as usize]) else { return false };
        let r = &pb.results[self.b_artx.unwrap()].rows[ri];
        b.extend_from_slice(b"{\"slug\":");
        json::str(b, pa.bytes(ar[3]).unwrap_or(b""));
        b.extend_from_slice(b",\"title\":");
        json::str(b, pa.bytes(ar[4]).unwrap_or(b""));
        b.extend_from_slice(b",\"description\":");
        json::str(b, pa.bytes(ar[5]).unwrap_or(b""));
        if full {
            b.extend_from_slice(b",\"body\":");
            json::str(b, pa.bytes(ar[8]).unwrap_or(b""));
        }
        b.extend_from_slice(b",\"tagList\":[");
        if let Some(arr) = pb.bytes(r[1]) {
            let mut tags: Vec<(u32, Col)> = pg::array_elems(arr)
                .filter_map(|e| e.try_into().ok().map(i32::from_be_bytes))
                .filter_map(|t| self.tag_rank.get(&t).copied())
                .collect();
            tags.sort_unstable_by_key(|t| t.0);
            for (i, (_, name)) in tags.into_iter().enumerate() {
                if i > 0 {
                    b.push(b',');
                }
                json::str(b, pb.bytes(name).unwrap_or(b""));
            }
        }
        b.extend_from_slice(b"],\"createdAt\":");
        json::ts(b, pa.i64(ar[6]));
        b.extend_from_slice(b",\"updatedAt\":");
        json::ts(b, pa.i64(ar[7]));
        b.extend_from_slice(b",\"favorited\":");
        json::bool(b, v != 0 && self.favorited(v, id));
        b.extend_from_slice(b",\"favoritesCount\":");
        json::int(b, pb.i64(r[2]));
        b.extend_from_slice(b",\"author\":");
        profile_obj(b, pb.bytes(r[3]).unwrap_or(b""), pb.bytes(r[4]), pb.bytes(r[5]), v != 0 && self.following(v, author));
        b.push(b'}');
        true
    }
}

// ------------------------------------------------------------------------------------------------------------------
// the write lane: group commit

pub struct WriteLane {
    conn: Option<Conn>,
    s: &'static Settings,
}

/// How many Execute messages a write uses, and the statement names.
fn write_plan(w: &WriteJob) -> Vec<&'static str> {
    match &w.kind {
        Write::Register { .. } => vec!["register"],
        Write::UpdateUser { .. } => vec!["upduser"],
        Write::Follow { on: true, .. } => vec!["follow"],
        Write::Follow { on: false, .. } => vec!["unfollow"],
        Write::Favorite { on: true, .. } => vec!["fav"],
        Write::Favorite { on: false, .. } => vec!["unfav"],
        Write::CreateArticle { tags, .. } if tags.is_empty() => vec!["newart"],
        Write::CreateArticle { .. } => vec!["newart", "newtags", "arttags"],
        Write::UpdateArticle { .. } => vec!["updart"],
        Write::DeleteArticle { .. } => vec!["delart"],
        Write::CreateComment { .. } => vec!["newcmt"],
        Write::DeleteComment { .. } => vec!["delcmt"],
    }
}

fn opt_text(s: &Option<String>) -> Param<'_> {
    match s {
        Some(s) => Param::Text(s.as_bytes()),
        None => Param::Null,
    }
}

fn bind_write(o: &mut pg::Out, w: &WriteJob) {
    let v = w.viewer;
    match &w.kind {
        Write::Register { username, email, hash } => {
            o.bind_exec("register", &[Param::Text(username.as_bytes()), Param::Text(email.as_bytes()), Param::Text(hash.as_bytes())])
        }
        Write::UpdateUser { email, username, hash, bio, image, .. } => o.bind_exec(
            "upduser",
            &[Param::I64(v), opt_text(email), opt_text(username), opt_text(hash), opt_text(bio), opt_text(image)],
        ),
        Write::Follow { username, on } => {
            o.bind_exec(if *on { "follow" } else { "unfollow" }, &[Param::I64(v), Param::Text(username.as_bytes())])
        }
        Write::Favorite { slug, on } => o.bind_exec(if *on { "fav" } else { "unfav" }, &[Param::I64(v), Param::Text(slug.as_bytes())]),
        Write::CreateArticle { title, description, body, tags } => {
            o.bind_exec(
                "newart",
                &[Param::I64(v), Param::Text(title.as_bytes()), Param::Text(description.as_bytes()), Param::Text(body.as_bytes())],
            );
            if !tags.is_empty() {
                let arr = text_array(tags.iter().map(|t| t.as_bytes()));
                o.bind_exec("newtags", &[Param::Raw(&arr)]);
                o.bind_exec("arttags", &[Param::Raw(&arr)]);
            }
        }
        Write::UpdateArticle { slug, title, description, body } => o.bind_exec(
            "updart",
            &[Param::Text(slug.as_bytes()), opt_text(title), opt_text(description), opt_text(body), Param::I64(v)],
        ),
        Write::DeleteArticle { slug } => o.bind_exec("delart", &[Param::Text(slug.as_bytes()), Param::I64(v)]),
        Write::CreateComment { slug, body } => {
            o.bind_exec("newcmt", &[Param::Text(slug.as_bytes()), Param::I64(v), Param::Text(body.as_bytes())])
        }
        Write::DeleteComment { slug, id } => {
            o.bind_exec("delcmt", &[Param::I64(*id), Param::Text(slug.as_bytes()), Param::I64(v)])
        }
    }
}

impl WriteLane {
    pub fn new(s: &'static Settings) -> WriteLane {
        WriteLane { conn: None, s }
    }

    fn conn(&mut self) -> pg::Result<&mut Conn> {
        if self.conn.is_none() {
            let mut c = Conn::connect(&self.s.cfg)?;
            let stmts = crate::sql::write_statements();
            let list: Vec<(&str, &str, &[u32])> = stmts.iter().map(|s| (s.name, s.sql.as_str(), s.types)).collect();
            c.prepare_all(&list)?;
            self.conn = Some(c);
        }
        Ok(self.conn.as_mut().unwrap())
    }

    pub fn run(mut self) {
        let mut jobs = Vec::with_capacity(self.s.write_batch);
        loop {
            jobs.clear();
            WRITES.take(self.s.write_batch, &mut jobs);
            let batch = std::mem::take(&mut jobs);
            if let Err((e, left)) = self.group(batch) {
                eprintln!("write batch failed: {e}");
                self.conn = None;
                // Never retry a write whose commit outcome is unknown.
                reply::send_all(left.into_iter().map(|t| reply::error(t, 500, "internal error")).collect());
            }
        }
    }

    /// One transaction for the whole group. If any statement fails, the group rolls back and each write is retried
    /// on its own.
    fn group(&mut self, jobs: Vec<WriteJob>) -> Result<(), (pg::Error, Vec<ReplyTo>)> {
        let tos: Vec<ReplyTo> = jobs.iter().map(|j| j.to).collect();
        let conn = match self.conn() {
            Ok(c) => c,
            Err(e) => return Err((e, tos)),
        };
        let single = jobs.len() == 1 && write_plan(&jobs[0]).len() == 1;
        let mut n = 0;
        if !single {
            conn.out.bind_exec("begin", &[]);
            n += 1;
        }
        let mut spans = Vec::with_capacity(jobs.len());
        for j in &jobs {
            let k = write_plan(j).len();
            spans.push((n, k));
            bind_write(&mut conn.out, j);
            n += k;
        }
        if !single {
            conn.out.bind_exec("commit", &[]);
            n += 1;
        }
        conn.out.sync();
        let p = match conn.flush().and_then(|_| conn.read_pipeline(n)) {
            Ok(p) => p,
            Err(e) => return Err((e, tos)),
        };
        let failed = p.results.iter().any(|r| r.error.is_some());
        if failed && !single {
            // rolled back: retry each on its own
            for j in jobs {
                let to = j.to;
                if let Err(e) = self.one(j) {
                    return Err((e, vec![to]));
                }
            }
            return Ok(());
        }
        let mut out = Vec::new();
        for (j, (start, k)) in jobs.into_iter().zip(spans) {
            finish_write(j, &p, start, k, self.s, &mut out);
        }
        reply::send_all(out);
        Ok(())
    }

    fn one(&mut self, j: WriteJob) -> pg::Result<()> {
        let conn = self.conn()?;
        let k = write_plan(&j).len();
        let mut n = 0;
        if k > 1 {
            conn.out.bind_exec("begin", &[]);
            n += 1;
        }
        let start = n;
        bind_write(&mut conn.out, &j);
        n += k;
        if k > 1 {
            conn.out.bind_exec("commit", &[]);
            n += 1;
        }
        conn.out.sync();
        conn.flush()?;
        let p = conn.read_pipeline(n)?;
        let mut out = Vec::new();
        finish_write(j, &p, start, k, self.s, &mut out);
        reply::send_all(out);
        Ok(())
    }
}

fn finish_write(j: WriteJob, p: &Pipeline, start: usize, k: usize, s: &Settings, out: &mut Vec<Response>) {
    let to = j.to;
    let v = j.viewer;
    let results = &p.results[start..start + k];
    if let Some(e) = results.iter().find_map(|r| r.error.as_ref()) {
        if e.code == "23505" {
            out.push(reply::error(to, 422, "username or email is already taken"));
        } else {
            eprintln!("write failed: {e}");
            out.push(reply::error(to, 500, "internal error"));
        }
        return;
    }
    let first = results[0].rows.first();
    match j.kind {
        Write::Register { .. } => match first {
            Some(r) => {
                let token = s.keys.issue(p.i64(r[0]));
                let mut b = Vec::with_capacity(512);
                user_json(&mut b, p.bytes(r[2]).unwrap_or(b""), token.as_bytes(), p.bytes(r[1]).unwrap_or(b""), p.bytes(r[3]), p.bytes(r[4]));
                out.push(Response { to, status: 201, body: b });
            }
            None => out.push(reply::error(to, 422, "username or email is already taken")),
        },
        Write::UpdateUser { token, .. } => match first {
            Some(r) => {
                let mut b = Vec::with_capacity(512);
                user_json(&mut b, p.bytes(r[2]).unwrap_or(b""), token.as_bytes(), p.bytes(r[1]).unwrap_or(b""), p.bytes(r[3]), p.bytes(r[4]));
                out.push(Response { to, status: 200, body: b });
            }
            None => out.push(reply::error(to, 401, "unauthorized")),
        },
        Write::Follow { on, .. } => match first {
            Some(r) => {
                let mut b = Vec::with_capacity(256);
                b.extend_from_slice(b"{\"profile\":");
                profile_obj(&mut b, p.bytes(r[0]).unwrap_or(b""), p.bytes(r[1]), p.bytes(r[2]), on);
                b.push(b'}');
                out.push(Response { to, status: 200, body: b });
            }
            None => out.push(reply::error(to, 404, "profile not found")),
        },
        Write::Favorite { .. } => match first {
            Some(r) => READS.push(ReadJob { kind: Read::ArticleId { id: p.i64(r[0]), status: 200 }, viewer: v, to }),
            None => out.push(reply::error(to, 404, "article not found")),
        },
        Write::CreateArticle { .. } => match first {
            Some(r) => READS.push(ReadJob { kind: Read::ArticleId { id: p.i64(r[0]), status: 201 }, viewer: v, to }),
            None => out.push(reply::error(to, 500, "internal error")),
        },
        Write::UpdateArticle { .. } => match first {
            Some(r) if p.i64(r[1]) != v => out.push(reply::error(to, 403, "not the author")),
            Some(r) => READS.push(ReadJob { kind: Read::ArticleId { id: p.i64(r[0]), status: 200 }, viewer: v, to }),
            None => out.push(reply::error(to, 404, "article not found")),
        },
        Write::DeleteArticle { .. } => match first {
            Some(r) if p.i64(r[0]) != v => out.push(reply::error(to, 403, "not the author")),
            Some(_) => out.push(Response { to, status: 204, body: Vec::new() }),
            None => out.push(reply::error(to, 404, "article not found")),
        },
        Write::CreateComment { .. } => match first {
            Some(r) => {
                let mut b = Vec::with_capacity(512);
                b.extend_from_slice(b"{\"comment\":{\"id\":");
                json::int(&mut b, p.i64(r[0]));
                b.extend_from_slice(b",\"createdAt\":");
                json::ts(&mut b, p.i64(r[2]));
                b.extend_from_slice(b",\"updatedAt\":");
                json::ts(&mut b, p.i64(r[3]));
                b.extend_from_slice(b",\"body\":");
                json::str(&mut b, p.bytes(r[1]).unwrap_or(b""));
                b.extend_from_slice(b",\"author\":");
                profile_obj(&mut b, p.bytes(r[4]).unwrap_or(b""), p.bytes(r[5]), p.bytes(r[6]), false);
                b.extend_from_slice(b"}}");
                out.push(Response { to, status: 201, body: b });
            }
            None => out.push(reply::error(to, 404, "article not found")),
        },
        Write::DeleteComment { .. } => match first {
            Some(r) if p.i64(r[0]) != v => out.push(reply::error(to, 403, "not the author")),
            Some(_) => out.push(Response { to, status: 204, body: Vec::new() }),
            None => out.push(reply::error(to, 404, "comment not found")),
        },
    }
}

// ------------------------------------------------------------------------------------------------------------------
// bcrypt workers

/// Worker 0 waits up to the window to fill its lanes, then runs what it has. Other workers only take full sets of
/// lanes, so they add capacity under a backlog without splitting the trickle of logins into half-empty runs.
pub fn bcrypt_worker(s: &'static Settings, index: usize) {
    let mut jobs: Vec<BcryptJob> = Vec::new();
    loop {
        jobs.clear();
        if index == 0 {
            BCRYPT.take_gather(s.bcrypt_lanes, s.bcrypt_window, &mut jobs);
        } else {
            BCRYPT.take_full(s.bcrypt_lanes, &mut jobs);
        }
        let mut batch = std::mem::take(&mut jobs);
        // Hashes of another cost (not produced by this server) run on their own.
        let mut odd: Vec<BcryptJob> = Vec::new();
        let mut i = 0;
        while i < batch.len() {
            let c = match &batch[i] {
                BcryptJob::Verify { hash, .. } => crate::bcrypt::parse(hash).map(|p| p.cost),
                BcryptJob::Hash { .. } => Some(10),
            };
            if c != Some(10) {
                odd.push(batch.swap_remove(i));
            } else {
                i += 1;
            }
        }
        run_bcrypt(batch, s, 10);
        for j in odd {
            let cost = match &j {
                BcryptJob::Verify { hash, .. } => crate::bcrypt::parse(hash).map(|p| p.cost),
                _ => Some(10),
            };
            match cost {
                Some(c) => run_bcrypt(vec![j], s, c),
                None => {
                    if let BcryptJob::Verify { to, .. } = j {
                        reply::send(to, 401, reply::error_body("invalid email or password"));
                    }
                }
            }
        }
    }
}

fn run_bcrypt(jobs: Vec<BcryptJob>, s: &Settings, cost: u32) {
    if jobs.is_empty() {
        return;
    }
    let mut salts: Vec<[u8; 16]> = Vec::with_capacity(jobs.len());
    let mut expect: Vec<Option<[u8; 23]>> = Vec::with_capacity(jobs.len());
    for j in &jobs {
        match j {
            BcryptJob::Verify { hash, .. } => {
                let p = crate::bcrypt::parse(hash).expect("checked");
                salts.push(p.salt);
                expect.push(Some(p.digest));
            }
            BcryptJob::Hash { .. } => {
                let mut salt = [0u8; 16];
                getrandom::fill(&mut salt).expect("getrandom");
                salts.push(salt);
                expect.push(None);
            }
        }
    }
    let pw: Vec<&[u8]> = jobs
        .iter()
        .map(|j| match j {
            BcryptJob::Verify { password, .. } | BcryptJob::Hash { password, .. } => password.as_slice(),
        })
        .collect();
    let digests: Vec<[u8; 23]> = run_lanes(&pw, &salts, cost);
    for (((j, d), salt), exp) in jobs.into_iter().zip(digests).zip(salts).zip(expect) {
        match j {
            BcryptJob::Verify { user, to, .. } => {
                if crate::bcrypt::digest_eq(&d, &exp.unwrap()) {
                    let token = s.keys.issue(user.id);
                    let mut b = Vec::with_capacity(512);
                    user_json(&mut b, &user.email, token.as_bytes(), &user.username, user.bio.as_deref(), user.image.as_deref());
                    reply::send(to, 200, b);
                } else {
                    reply::send(to, 401, reply::error_body("invalid email or password"));
                }
            }
            BcryptJob::Hash { mut write, .. } => {
                let h = crate::bcrypt::format(cost, &salt, &d);
                match &mut write.kind {
                    Write::Register { hash, .. } => *hash = h,
                    Write::UpdateUser { hash, .. } => *hash = Some(h),
                    _ => {}
                }
                WRITES.push(write);
            }
        }
    }
}

fn run_lanes(pw: &[&[u8]], salts: &[[u8; 16]], cost: u32) -> Vec<[u8; 23]> {
    use crate::bcrypt::{raw_n, Job};
    let mut out = Vec::with_capacity(pw.len());
    let mut i = 0;
    while i < pw.len() {
        let left = pw.len() - i;
        macro_rules! go {
            ($n:literal) => {{
                let jobs: [Job; $n] = std::array::from_fn(|k| Job { password: pw[i + k], salt: salts[i + k] });
                out.extend_from_slice(&raw_n::<$n>(&jobs, cost));
                i += $n;
            }};
        }
        match left {
            1 => go!(1),
            2 => go!(2),
            3 => go!(3),
            4 => go!(4),
            5 => go!(5),
            _ => go!(6),
        }
    }
    out
}
