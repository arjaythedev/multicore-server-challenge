//! Database lanes. Reads are batched across request kinds: each read lane takes every job that queued up during its
//! gather window and answers them all with two pipelines (phase A: what the requests name; phase B: counts not
//! settled by the page, enrichment, viewer flags), one statement per kind over distinct keys. Writes go through one
//! lane, a group per transaction (group commit). bcrypt runs on its own threads, several hashes in lockstep.
//!
//! Every job carries a `Reply`; a job dropped on any error path answers 500 by itself.

use std::collections::{HashMap, HashSet};
use std::hash::Hash as StdHash;
use std::sync::OnceLock;
use std::time::Duration;

use crate::pg::{self, Array, Col, Conn, Param, Pipeline};
use crate::queue::Queue;
use crate::render::{self, Comment};
use crate::reply::{Batch, Reply};
use crate::{bcrypt, json, sql};

pub enum Read {
    Tags,
    CurrentUser { token: String },
    Login { email: String, password: Vec<u8> },
    Profile { username: String },
    Global { lim: i64, off: i64 },
    Tag { tag: String, lim: i64, off: i64 },
    Author { username: String, lim: i64, off: i64 },
    Favorited { username: String, lim: i64, off: i64 },
    Feed { lim: i64, off: i64 },
    Article { slug: String },
    /// The article a write just changed, answered with `status`.
    ArticleId { id: i64, status: u16 },
    Comments { slug: String },
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

/// A write that needs a new password hashed first.
pub struct Hash {
    pub password: Vec<u8>,
    pub kind: Write,
    pub viewer: i64,
}

struct ReadJob {
    kind: Read,
    viewer: i64,
    reply: Reply,
}

struct WriteJob {
    kind: Write,
    viewer: i64,
    reply: Reply,
}

/// A login's user row, waiting for its bcrypt verify.
struct LoginUser {
    id: i64,
    email: Vec<u8>,
    username: Vec<u8>,
    bio: Option<Vec<u8>>,
    image: Option<Vec<u8>>,
    hash: Vec<u8>,
}

enum BcryptJob {
    Verify { password: Vec<u8>, user: LoginUser, reply: Reply },
    Hash { password: Vec<u8>, write: WriteJob },
}

static READS: Queue<ReadJob> = Queue::new(false);
static WRITES: Queue<WriteJob> = Queue::new(false);
static BCRYPT: Queue<BcryptJob> = Queue::new(true);

pub struct Settings {
    pub cfg: pg::Config,
    pub keys: &'static crate::jwt::Keys,
    pub read_window: Duration,
    pub read_max: usize,
    pub write_max: usize,
    pub bcrypt_window: Duration,
}

static SETTINGS: OnceLock<Settings> = OnceLock::new();

pub fn init(s: Settings) {
    if SETTINGS.set(s).is_err() {
        panic!("db::init twice");
    }
}

fn settings() -> &'static Settings {
    SETTINGS.get().expect("db::init")
}

pub fn read(kind: Read, viewer: i64, reply: Reply) {
    READS.push(ReadJob { kind, viewer, reply });
}

pub fn write(kind: Write, viewer: i64, reply: Reply) {
    WRITES.push(WriteJob { kind, viewer, reply });
}

pub fn hash(h: Hash, reply: Reply) {
    BCRYPT.push(BcryptJob::Hash { password: h.password, write: WriteJob { kind: h.kind, viewer: h.viewer, reply } });
}

/// Connects and prepares `stmts`, failing fast (used at startup too).
pub fn connect(stmts: &[sql::Stmt]) -> pg::Result<Conn> {
    let mut c = Conn::connect(&settings().cfg)?;
    let list: Vec<(&str, &str, &[u32])> = stmts.iter().map(|(n, s, t)| (*n, s.as_str(), *t)).collect();
    c.prepare(&list)?;
    Ok(c)
}

// ------------------------------------------------------------------------------------------------------------------
// helpers

/// Distinct keys in first-seen order; a key's SQL ordinal `k` is its index + 1.
struct Keys<K> {
    map: HashMap<K, u32>,
    list: Vec<K>,
}

impl<K: StdHash + Eq + Clone> Keys<K> {
    fn new() -> Self {
        Keys { map: HashMap::new(), list: Vec::new() }
    }
    fn idx(&mut self, k: K) -> u32 {
        let n = self.list.len() as u32;
        *self.map.entry(k.clone()).or_insert_with(|| {
            self.list.push(k);
            n
        })
    }
}

/// Row indices of result `res` grouped by the key ordinal in column 0.
fn by_key(p: &Pipeline, res: usize, n: usize) -> Vec<Vec<usize>> {
    let mut g = vec![Vec::new(); n];
    for (i, row) in p.res[res].rows().enumerate() {
        let k = p.i64(row[0]);
        if k >= 1 && (k as usize) <= n {
            g[k as usize - 1].push(i);
        }
    }
    g
}

fn texts<'a>(v: impl IntoIterator<Item = &'a [u8]>) -> Vec<u8> {
    Array::texts(v)
}

/// Queues statements and remembers where each one's result lands.
struct Plan {
    n: usize,
}

impl Plan {
    fn exec(&mut self, c: &mut Conn, stmt: &str, params: &[Param]) -> usize {
        c.out.exec(stmt, params);
        self.n += 1;
        self.n - 1
    }
}

fn check(p: &Pipeline) -> Result<(), String> {
    match p.res.iter().find_map(|r| r.error.as_ref()) {
        Some(e) => Err(format!("{}: {}", e.code, e.message)),
        None => Ok(()),
    }
}

fn opt_bytes(s: &Option<String>) -> Param<'_> {
    Param::opt(s.as_deref().map(str::as_bytes))
}

// ------------------------------------------------------------------------------------------------------------------
// read lanes

pub fn read_lane() {
    let s = settings();
    let mut conn: Option<Conn> = None;
    let mut jobs = Vec::new();
    loop {
        READS.take(usize::MAX, s.read_max, s.read_window, &mut jobs);
        let batch = std::mem::take(&mut jobs);
        if conn.is_none() {
            match connect(&[sql::phase_a(), sql::phase_b()].concat()) {
                Ok(c) => conn = Some(c),
                Err(e) => {
                    eprintln!("read lane: connect: {e}");
                    std::thread::sleep(Duration::from_millis(100));
                    continue; // the batch's replies answer 500 as they drop
                }
            }
        }
        if let Err(e) = read_batch(conn.as_mut().unwrap(), batch) {
            eprintln!("read batch failed: {e}");
            conn = None;
        }
    }
}

/// An article row of phase A: [k, id, author_id, slug, title, description, created_at, updated_at (, body)].
type ArtRow<'a> = &'a [Col];

#[derive(Default)]
struct Flags {
    fav: HashSet<(i64, i64)>,
    fol: HashSet<(i64, i64)>,
}

fn read_batch(c: &mut Conn, jobs: Vec<ReadJob>) -> Result<(), String> {
    let mut kinds = Vec::with_capacity(jobs.len());
    let mut replies = Vec::with_capacity(jobs.len());
    for j in jobs {
        kinds.push((j.kind, j.viewer));
        replies.push(j.reply);
    }

    // ---- phase A ----
    let mut tags = false;
    let mut uid = Keys::<i64>::new();
    let mut uemail = Keys::<&[u8]>::new();
    let mut prof = Keys::<&[u8]>::new();
    let mut aslug = Keys::<&[u8]>::new();
    let mut aid = Keys::<i64>::new();
    let mut cmts = Keys::<&[u8]>::new();
    let mut pglobal = Keys::<(i64, i64)>::new();
    let mut ptag = Keys::<(&[u8], i64, i64)>::new();
    let mut pauthor = Keys::<(&[u8], i64, i64)>::new();
    let mut pfav = Keys::<(&[u8], i64, i64)>::new();
    let mut pfeed = Keys::<(i64, i64, i64)>::new();
    let key: Vec<u32> = kinds
        .iter()
        .map(|(k, v)| match k {
            Read::Tags => {
                tags = true;
                0
            }
            Read::CurrentUser { .. } => uid.idx(*v),
            Read::Login { email, .. } => uemail.idx(email.as_bytes()),
            Read::Profile { username } => prof.idx(username.as_bytes()),
            Read::Article { slug } => aslug.idx(slug.as_bytes()),
            Read::ArticleId { id, .. } => aid.idx(*id),
            Read::Comments { slug } => cmts.idx(slug.as_bytes()),
            Read::Global { lim, off } => pglobal.idx((*lim, *off)),
            Read::Tag { tag, lim, off } => ptag.idx((tag.as_bytes(), *lim, *off)),
            Read::Author { username, lim, off } => pauthor.idx((username.as_bytes(), *lim, *off)),
            Read::Favorited { username, lim, off } => pfav.idx((username.as_bytes(), *lim, *off)),
            Read::Feed { lim, off } => pfeed.idx((*v, *lim, *off)),
        })
        .collect();

    let mut plan = Plan { n: 0 };
    let r_tags = tags.then(|| plan.exec(c, "tags", &[]));
    let ids = |c: &mut Conn, plan: &mut Plan, stmt: &str, k: &Keys<i64>| {
        (!k.list.is_empty()).then(|| plan.exec(c, stmt, &[Param::Raw(&Array::i64s(k.list.iter().copied()))]))
    };
    let r_uid = ids(c, &mut plan, "uid", &uid);
    let r_aid = ids(c, &mut plan, "aid", &aid);
    let one_text = |c: &mut Conn, plan: &mut Plan, stmt: &str, k: &Keys<&[u8]>| {
        (!k.list.is_empty()).then(|| plan.exec(c, stmt, &[Param::Raw(&texts(k.list.iter().copied()))]))
    };
    let r_uemail = one_text(c, &mut plan, "uemail", &uemail);
    let r_prof = one_text(c, &mut plan, "prof", &prof);
    let r_aslug = one_text(c, &mut plan, "aslug", &aslug);
    let r_cmts = one_text(c, &mut plan, "cmts", &cmts);
    let r_pglobal = (!pglobal.list.is_empty()).then(|| {
        let lim = Array::i64s(pglobal.list.iter().map(|k| k.0));
        let off = Array::i64s(pglobal.list.iter().map(|k| k.1));
        plan.exec(c, "pglobal", &[Param::Raw(&lim), Param::Raw(&off)])
    });
    let named_page = |c: &mut Conn, plan: &mut Plan, stmt: &str, k: &Keys<(&[u8], i64, i64)>| {
        (!k.list.is_empty()).then(|| {
            let names = texts(k.list.iter().map(|k| k.0));
            let lim = Array::i64s(k.list.iter().map(|k| k.1));
            let off = Array::i64s(k.list.iter().map(|k| k.2));
            plan.exec(c, stmt, &[Param::Raw(&names), Param::Raw(&lim), Param::Raw(&off)])
        })
    };
    let r_ptag = named_page(c, &mut plan, "ptag", &ptag);
    let r_pauthor = named_page(c, &mut plan, "pauthor", &pauthor);
    let r_pfav = named_page(c, &mut plan, "pfav", &pfav);
    let r_pfeed = (!pfeed.list.is_empty()).then(|| {
        let v = Array::i64s(pfeed.list.iter().map(|k| k.0));
        let lim = Array::i64s(pfeed.list.iter().map(|k| k.1));
        let off = Array::i64s(pfeed.list.iter().map(|k| k.2));
        plan.exec(c, "pfeed", &[Param::Raw(&v), Param::Raw(&lim), Param::Raw(&off)])
    });
    let pa = if plan.n > 0 { c.run(plan.n).map_err(|e| e.to_string())? } else { Pipeline { data: Vec::new(), res: Vec::new() } };
    check(&pa)?;

    let group = |r: Option<usize>, n: usize| r.map(|r| by_key(&pa, r, n)).unwrap_or_default();
    let g_uid = group(r_uid, uid.list.len());
    let g_uemail = group(r_uemail, uemail.list.len());
    let g_prof = group(r_prof, prof.list.len());
    let g_aslug = group(r_aslug, aslug.list.len());
    let g_aid = group(r_aid, aid.list.len());
    let mut g_cmts = group(r_cmts, cmts.list.len());
    let mut g_pglobal = group(r_pglobal, pglobal.list.len());
    let mut g_ptag = group(r_ptag, ptag.list.len());
    let mut g_pauthor = group(r_pauthor, pauthor.list.len());
    let mut g_pfav = group(r_pfav, pfav.list.len());
    let mut g_pfeed = group(r_pfeed, pfeed.list.len());
    // newest first by id within each page; comments by (created_at, id) descending
    for (g, r) in [(&mut g_pglobal, r_pglobal), (&mut g_ptag, r_ptag), (&mut g_pauthor, r_pauthor), (&mut g_pfav, r_pfav), (&mut g_pfeed, r_pfeed)] {
        if let Some(r) = r {
            for rows in g.iter_mut() {
                rows.sort_unstable_by_key(|&i| std::cmp::Reverse(pa.i64(pa.res[r].row(i)[1])));
            }
        }
    }
    if let Some(r) = r_cmts {
        for rows in g_cmts.iter_mut() {
            rows.sort_unstable_by_key(|&i| {
                let row = pa.res[r].row(i);
                std::cmp::Reverse((pa.i64(row[3]), pa.i64(row[1])))
            });
        }
    }

    // ---- what phase B must settle ----
    let mut cglobal = false;
    let mut ctag = Keys::<&[u8]>::new();
    let mut cauthor = Keys::<&[u8]>::new();
    let mut cfav = Keys::<&[u8]>::new();
    let mut cfeed = Keys::<i64>::new();
    let mut arts = Keys::<i64>::new();
    let mut art_author: Vec<i64> = Vec::new();
    let mut want_fav: HashSet<(i64, i64)> = HashSet::new();
    let mut want_fol: HashSet<(i64, i64)> = HashSet::new();
    let mut add_art = |row: ArtRow, v: i64, arts: &mut Keys<i64>, want_fav: &mut HashSet<(i64, i64)>, want_fol: &mut HashSet<(i64, i64)>| {
        let (id, author) = (pa.i64(row[1]), pa.i64(row[2]));
        if arts.idx(id) as usize == art_author.len() {
            art_author.push(author);
        }
        if v != 0 {
            want_fav.insert((v, id));
            want_fol.insert((v, author));
        }
    };
    // the count of a page that ended short is known: it is offset + rows (when the page reached any row)
    let short = |rows: &[usize], lim: i64, off: i64| -> Option<i64> {
        ((rows.len() as i64) < lim && (!rows.is_empty() || off == 0)).then(|| (off + rows.len() as i64).min(1000))
    };
    let mut known: Vec<Option<i64>> = vec![None; kinds.len()];
    for (i, (kind, v)) in kinds.iter().enumerate() {
        let k = key[i] as usize;
        let v = *v;
        fn page(g: &[Vec<usize>], r: Option<usize>, k: usize) -> (usize, &[usize]) {
            (r.unwrap_or(0), g.get(k).map(Vec::as_slice).unwrap_or(&[]))
        }
        let ((r, rows), lim, off) = match kind {
            Read::Global { lim, off } => (page(&g_pglobal, r_pglobal, k), *lim, *off),
            Read::Tag { lim, off, .. } => (page(&g_ptag, r_ptag, k), *lim, *off),
            Read::Author { lim, off, .. } => (page(&g_pauthor, r_pauthor, k), *lim, *off),
            Read::Favorited { lim, off, .. } => (page(&g_pfav, r_pfav, k), *lim, *off),
            Read::Feed { lim, off } => (page(&g_pfeed, r_pfeed, k), *lim, *off),
            Read::Article { .. } => {
                if let Some(&row) = g_aslug.get(k).and_then(|g| g.first()) {
                    add_art(pa.res[r_aslug.unwrap()].row(row), v, &mut arts, &mut want_fav, &mut want_fol);
                }
                continue;
            }
            Read::ArticleId { .. } => {
                if let Some(&row) = g_aid.get(k).and_then(|g| g.first()) {
                    add_art(pa.res[r_aid.unwrap()].row(row), v, &mut arts, &mut want_fav, &mut want_fol);
                }
                continue;
            }
            Read::Profile { .. } => {
                if let (true, Some(&row)) = (v != 0, g_prof.get(k).and_then(|g| g.first())) {
                    want_fol.insert((v, pa.i64(pa.res[r_prof.unwrap()].row(row)[1])));
                }
                continue;
            }
            Read::Comments { .. } => {
                if v != 0 {
                    for &row in g_cmts.get(k).map(Vec::as_slice).unwrap_or(&[]) {
                        let row = pa.res[r_cmts.unwrap()].row(row);
                        if !pa.null(row[1]) {
                            want_fol.insert((v, pa.i64(row[5])));
                        }
                    }
                }
                continue;
            }
            _ => continue,
        };
        for &row in rows {
            add_art(pa.res[r].row(row), v, &mut arts, &mut want_fav, &mut want_fol);
        }
        known[i] = short(rows, lim, off);
        if known[i].is_none() {
            match kind {
                Read::Global { .. } => cglobal = true,
                Read::Tag { tag, .. } => {
                    ctag.idx(tag.as_bytes());
                }
                Read::Author { username, .. } => {
                    cauthor.idx(username.as_bytes());
                }
                Read::Favorited { username, .. } => {
                    cfav.idx(username.as_bytes());
                }
                Read::Feed { .. } => {
                    cfeed.idx(v);
                }
                _ => {}
            }
        }
    }

    // ---- phase B ----
    let mut plan = Plan { n: 0 };
    let r_cglobal = cglobal.then(|| plan.exec(c, "cglobal", &[]));
    let r_ctag = one_text(c, &mut plan, "ctag", &ctag);
    let r_cauthor = one_text(c, &mut plan, "cauthor", &cauthor);
    let r_cfav = one_text(c, &mut plan, "cfav", &cfav);
    let r_cfeed = ids(c, &mut plan, "cfeed", &cfeed);
    let r_artx = (!arts.list.is_empty()).then(|| {
        let a = Array::i64s(arts.list.iter().copied());
        let u = Array::i64s(art_author.iter().copied());
        let r = plan.exec(c, "artx", &[Param::Raw(&a), Param::Raw(&u)]);
        plan.exec(c, "tagnames", &[Param::Raw(&a)]);
        r
    });
    let r_flags = (!want_fav.is_empty() || !want_fol.is_empty()).then(|| {
        let fv = Array::i64s(want_fav.iter().map(|p| p.0));
        let fa = Array::i64s(want_fav.iter().map(|p| p.1));
        let ov = Array::i64s(want_fol.iter().map(|p| p.0));
        let ou = Array::i64s(want_fol.iter().map(|p| p.1));
        plan.exec(c, "flags", &[Param::Raw(&fv), Param::Raw(&fa), Param::Raw(&ov), Param::Raw(&ou)])
    });
    let pb = if plan.n > 0 { c.run(plan.n).map_err(|e| e.to_string())? } else { Pipeline { data: Vec::new(), res: Vec::new() } };
    check(&pb)?;

    let count_of = |r: Option<usize>, n: usize| -> Vec<i64> {
        let mut out = vec![0; n];
        if let Some(r) = r {
            for row in pb.res[r].rows() {
                let k = pb.i64(row[0]);
                if k >= 1 && (k as usize) <= n {
                    out[k as usize - 1] = pb.i64(row[1]);
                }
            }
        }
        out
    };
    let n_global = r_cglobal.map(|r| pb.i64(pb.res[r].row(0)[0])).unwrap_or(0);
    let n_tag = count_of(r_ctag, ctag.list.len());
    let n_author = count_of(r_cauthor, cauthor.list.len());
    let n_fav = count_of(r_cfav, cfav.list.len());
    let n_feed = count_of(r_cfeed, cfeed.list.len());

    let mut ex = Enrich { pa: &pa, pb: &pb, artx: HashMap::new(), artx_res: 0, tag_rank: HashMap::new(), tagnames_res: 0, flags: Flags::default() };
    if let Some(r) = r_artx {
        ex.artx_res = r;
        ex.tagnames_res = r + 1;
        for (i, row) in pb.res[r].rows().enumerate() {
            ex.artx.insert(pb.i64(row[0]), i);
        }
        for (rank, row) in pb.res[r + 1].rows().enumerate() {
            ex.tag_rank.insert(pb.i64(row[0]), rank);
        }
    }
    if let Some(r) = r_flags {
        for row in pb.res[r].rows() {
            let pair = (pb.i64(row[1]), pb.i64(row[2]));
            if pb.i64(row[0]) == 0 { ex.flags.fav.insert(pair) } else { ex.flags.fol.insert(pair) };
        }
    }

    // ---- answers ----
    let mut out = Batch::default();
    for (i, ((kind, v), reply)) in kinds.iter().zip(replies).enumerate() {
        let k = key[i] as usize;
        let v = *v;
        let mut b = Vec::with_capacity(1024);
        match kind {
            Read::Tags => {
                let r = r_tags.unwrap();
                b.extend_from_slice(b"{\"tags\":[");
                for (n, t) in pg::array_elems(pa.bytes(pa.res[r].row(0)[0])).enumerate() {
                    if n > 0 {
                        b.push(b',');
                    }
                    json::string(&mut b, t);
                }
                b.extend_from_slice(b"]}");
                out.send(reply, 200, b);
            }
            Read::CurrentUser { token } => match g_uid[k].first() {
                Some(&row) => {
                    let row = pa.res[r_uid.unwrap()].row(row);
                    render::user(&mut b, pa.bytes(row[3]), token.as_bytes(), pa.bytes(row[2]), pa.get(row[4]), pa.get(row[5]));
                    out.send(reply, 200, b);
                }
                None => out.error(reply, 401, "user not found"),
            },
            Read::Login { password, .. } => match g_uemail[k].first() {
                Some(&row) => {
                    let row = pa.res[r_uemail.unwrap()].row(row);
                    let user = LoginUser {
                        id: pa.i64(row[1]),
                        username: pa.bytes(row[2]).to_vec(),
                        email: pa.bytes(row[3]).to_vec(),
                        bio: pa.get(row[4]).map(<[u8]>::to_vec),
                        image: pa.get(row[5]).map(<[u8]>::to_vec),
                        hash: pa.bytes(row[6]).to_vec(),
                    };
                    BCRYPT.push(BcryptJob::Verify { password: password.clone(), user, reply });
                }
                None => out.error(reply, 401, "invalid email or password"),
            },
            Read::Profile { .. } => match g_prof[k].first() {
                Some(&row) => {
                    let row = pa.res[r_prof.unwrap()].row(row);
                    b.extend_from_slice(b"{\"profile\":");
                    let following = ex.flags.fol.contains(&(v, pa.i64(row[1])));
                    render::profile(&mut b, pa.bytes(row[2]), pa.get(row[3]), pa.get(row[4]), following);
                    b.push(b'}');
                    out.send(reply, 200, b);
                }
                None => out.error(reply, 404, "profile not found"),
            },
            Read::Article { .. } | Read::ArticleId { .. } => {
                let (g, r, status) = match kind {
                    Read::ArticleId { status, .. } => (&g_aid, r_aid, *status),
                    _ => (&g_aslug, r_aslug, 200),
                };
                match g[k].first() {
                    Some(&row) => {
                        b.extend_from_slice(b"{\"article\":");
                        ex.article(&mut b, pa.res[r.unwrap()].row(row), v);
                        b.push(b'}');
                        out.send(reply, status, b);
                    }
                    None => out.error(reply, 404, "article not found"),
                }
            }
            Read::Comments { .. } => {
                let rows = &g_cmts[k];
                if rows.is_empty() {
                    out.error(reply, 404, "article not found");
                    continue;
                }
                let r = r_cmts.unwrap();
                b.extend_from_slice(b"{\"comments\":[");
                let mut first = true;
                for &row in rows {
                    let row = pa.res[r].row(row);
                    if pa.null(row[1]) {
                        continue;
                    }
                    if !first {
                        b.push(b',');
                    }
                    first = false;
                    render::comment(
                        &mut b,
                        &Comment {
                            id: pa.i64(row[1]),
                            body: pa.bytes(row[2]),
                            created: pa.i64(row[3]),
                            updated: pa.i64(row[4]),
                            username: pa.bytes(row[6]),
                            bio: pa.get(row[7]),
                            image: pa.get(row[8]),
                            following: ex.flags.fol.contains(&(v, pa.i64(row[5]))),
                        },
                    );
                }
                b.extend_from_slice(b"]}");
                out.send(reply, 200, b);
            }
            Read::Global { .. } | Read::Tag { .. } | Read::Author { .. } | Read::Favorited { .. } | Read::Feed { .. } => {
                let (g, r, count) = match kind {
                    Read::Global { .. } => (&g_pglobal, r_pglobal, n_global),
                    Read::Tag { tag, .. } => (&g_ptag, r_ptag, ctag.map.get(tag.as_bytes()).map_or(0, |&x| n_tag[x as usize])),
                    Read::Author { username, .. } => {
                        (&g_pauthor, r_pauthor, cauthor.map.get(username.as_bytes()).map_or(0, |&x| n_author[x as usize]))
                    }
                    Read::Favorited { username, .. } => {
                        (&g_pfav, r_pfav, cfav.map.get(username.as_bytes()).map_or(0, |&x| n_fav[x as usize]))
                    }
                    _ => (&g_pfeed, r_pfeed, cfeed.map.get(&v).map_or(0, |&x| n_feed[x as usize])),
                };
                b.extend_from_slice(b"{\"articles\":[");
                if let Some(r) = r {
                    for (n, &row) in g[k].iter().enumerate() {
                        if n > 0 {
                            b.push(b',');
                        }
                        ex.article(&mut b, pa.res[r].row(row), v);
                    }
                }
                b.extend_from_slice(b"],\"articlesCount\":");
                json::int(&mut b, known[i].unwrap_or(count));
                b.push(b'}');
                out.send(reply, 200, b);
            }
        }
    }
    Ok(())
}

struct Enrich<'a> {
    pa: &'a Pipeline,
    pb: &'a Pipeline,
    artx: HashMap<i64, usize>,
    artx_res: usize,
    tag_rank: HashMap<i64, usize>,
    tagnames_res: usize,
    flags: Flags,
}

impl Enrich<'_> {
    /// An Article object from a phase-A article row (with `body` when the row has it).
    fn article(&self, b: &mut Vec<u8>, row: ArtRow, v: i64) {
        let (pa, pb) = (self.pa, self.pb);
        let (id, author) = (pa.i64(row[1]), pa.i64(row[2]));
        let x = self.artx.get(&id).map(|&i| pb.res[self.artx_res].row(i));
        b.extend_from_slice(b"{\"slug\":");
        json::string(b, pa.bytes(row[3]));
        b.extend_from_slice(b",\"title\":");
        json::string(b, pa.bytes(row[4]));
        b.extend_from_slice(b",\"description\":");
        json::string(b, pa.bytes(row[5]));
        if row.len() > 8 {
            b.extend_from_slice(b",\"body\":");
            json::string(b, pa.bytes(row[8]));
        }
        b.extend_from_slice(b",\"tagList\":[");
        if let Some(x) = x {
            let mut tags: Vec<(usize, i64)> = pg::array_elems(pb.bytes(x[1]))
                .filter_map(|e| {
                    let t = match e.len() {
                        4 => i32::from_be_bytes(e.try_into().ok()?) as i64,
                        8 => i64::from_be_bytes(e.try_into().ok()?),
                        _ => return None,
                    };
                    Some((*self.tag_rank.get(&t)?, t))
                })
                .collect();
            tags.sort_unstable();
            for (n, (rank, _)) in tags.iter().enumerate() {
                if n > 0 {
                    b.push(b',');
                }
                json::string(b, pb.bytes(pb.res[self.tagnames_res].row(*rank)[1]));
            }
        }
        b.extend_from_slice(b"],\"createdAt\":");
        json::ts(b, pa.i64(row[6]));
        b.extend_from_slice(b",\"updatedAt\":");
        json::ts(b, pa.i64(row[7]));
        b.extend_from_slice(b",\"favorited\":");
        json::bool(b, self.flags.fav.contains(&(v, id)));
        b.extend_from_slice(b",\"favoritesCount\":");
        json::int(b, x.map_or(0, |x| pb.i64(x[2])));
        b.extend_from_slice(b",\"author\":");
        match x {
            Some(x) => render::profile(b, pb.bytes(x[3]), pb.get(x[4]), pb.get(x[5]), self.flags.fol.contains(&(v, author))),
            None => render::profile(b, b"", None, None, false),
        }
        b.push(b'}');
    }
}

// ------------------------------------------------------------------------------------------------------------------
// the write lane: one transaction per group

fn bind_write(c: &mut Conn, w: &WriteJob) {
    let v = Param::I64(w.viewer);
    fn t(s: &str) -> Param<'_> {
        Param::Text(s.as_bytes())
    }
    match &w.kind {
        Write::Register { username, email, hash } => c.out.exec("register", &[t(username), t(email), t(hash)]),
        Write::UpdateUser { email, username, hash, bio, image, .. } => c.out.exec(
            "upduser",
            &[v, opt_bytes(email), opt_bytes(username), opt_bytes(hash), opt_bytes(bio), opt_bytes(image)],
        ),
        Write::Follow { username, on } => c.out.exec(if *on { "follow" } else { "unfollow" }, &[v, t(username)]),
        Write::Favorite { slug, on } => c.out.exec(if *on { "fav" } else { "unfav" }, &[v, t(slug)]),
        Write::CreateArticle { title, description, body, tags } => {
            let arr = texts(tags.iter().map(|s| s.as_bytes()));
            c.out.exec("newart", &[v, t(title), t(description), t(body), Param::Raw(&arr)])
        }
        Write::UpdateArticle { slug, title, description, body } => {
            c.out.exec("updart", &[t(slug), opt_bytes(title), opt_bytes(description), opt_bytes(body), v])
        }
        Write::DeleteArticle { slug } => c.out.exec("delart", &[t(slug), v]),
        Write::CreateComment { slug, body } => c.out.exec("newcmt", &[t(slug), v, t(body)]),
        Write::DeleteComment { slug, id } => c.out.exec("delcmt", &[Param::I64(*id), t(slug), v]),
    }
}

pub fn write_lane() {
    let s = settings();
    let mut conn: Option<Conn> = None;
    let mut jobs = Vec::new();
    loop {
        WRITES.take(1, s.write_max, Duration::ZERO, &mut jobs);
        let batch = std::mem::take(&mut jobs);
        if conn.is_none() {
            match connect(&sql::writes()) {
                Ok(c) => conn = Some(c),
                Err(e) => {
                    eprintln!("write lane: connect: {e}");
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
            }
        }
        if let Err(e) = write_group(conn.as_mut().unwrap(), batch) {
            // The replies of writes whose commit outcome is unknown answer 500; they are never retried.
            eprintln!("write group failed: {e}");
            conn = None;
        }
    }
}

/// The group in one transaction. If any statement fails the transaction is rolled back and each write is retried on
/// its own, so one write's unique violation can't fail the others.
fn write_group(c: &mut Conn, jobs: Vec<WriteJob>) -> pg::Result<()> {
    let single = jobs.len() == 1;
    let mut n = 0;
    if !single {
        c.out.exec("begin", &[]);
        n += 1;
    }
    let first = n;
    for j in &jobs {
        bind_write(c, j);
    }
    n += jobs.len();
    if !single {
        c.out.exec("commit", &[]);
        n += 1;
    }
    let p = c.run(n)?;
    if !single && p.res.iter().any(|r| r.error.is_some()) {
        c.out.exec("rollback", &[]);
        c.run(1)?;
        for j in jobs {
            write_group(c, vec![j])?;
        }
        return Ok(());
    }
    let mut out = Batch::default();
    for (i, j) in jobs.into_iter().enumerate() {
        finish_write(j, &p, first + i, &mut out);
    }
    Ok(())
}

fn finish_write(j: WriteJob, p: &Pipeline, r: usize, out: &mut Batch) {
    let WriteJob { kind, viewer: v, reply } = j;
    let res = &p.res[r];
    if let Some(e) = &res.error {
        if e.code == "23505" {
            return out.error(reply, 422, "username or email is already taken");
        }
        eprintln!("write failed: {} {}", e.code, e.message);
        return out.error(reply, 500, "internal error");
    }
    let row = (res.len() > 0).then(|| res.row(0));
    let keys = settings().keys;
    let mut b = Vec::with_capacity(512);
    match kind {
        Write::Register { .. } => match row {
            Some(r) => {
                let token = keys.issue(p.i64(r[0]));
                render::user(&mut b, p.bytes(r[2]), token.as_bytes(), p.bytes(r[1]), p.get(r[3]), p.get(r[4]));
                out.send(reply, 201, b)
            }
            None => out.error(reply, 422, "username or email is already taken"),
        },
        Write::UpdateUser { token, .. } => match row {
            Some(r) => {
                render::user(&mut b, p.bytes(r[2]), token.as_bytes(), p.bytes(r[1]), p.get(r[3]), p.get(r[4]));
                out.send(reply, 200, b)
            }
            None => out.error(reply, 401, "user not found"),
        },
        Write::Follow { on, .. } => match row {
            Some(r) => {
                b.extend_from_slice(b"{\"profile\":");
                render::profile(&mut b, p.bytes(r[0]), p.get(r[1]), p.get(r[2]), on);
                b.push(b'}');
                out.send(reply, 200, b)
            }
            None => out.error(reply, 404, "profile not found"),
        },
        Write::Favorite { .. } => match row {
            Some(r) => read(Read::ArticleId { id: p.i64(r[0]), status: 200 }, v, reply),
            None => out.error(reply, 404, "article not found"),
        },
        Write::CreateArticle { .. } => match row {
            Some(r) => read(Read::ArticleId { id: p.i64(r[0]), status: 201 }, v, reply),
            None => out.error(reply, 500, "internal error"),
        },
        Write::UpdateArticle { .. } => match row {
            Some(r) if p.i64(r[1]) != v => out.error(reply, 403, "not the author"),
            Some(r) => read(Read::ArticleId { id: p.i64(r[0]), status: 200 }, v, reply),
            None => out.error(reply, 404, "article not found"),
        },
        Write::DeleteArticle { .. } | Write::DeleteComment { .. } => {
            let what = if matches!(kind, Write::DeleteArticle { .. }) { "article not found" } else { "comment not found" };
            match row {
                Some(r) if p.i64(r[0]) != v => out.error(reply, 403, "not the author"),
                Some(_) => out.send(reply, 204, Vec::new()),
                None => out.error(reply, 404, what),
            }
        }
        Write::CreateComment { .. } => match row {
            Some(r) => {
                b.extend_from_slice(b"{\"comment\":");
                render::comment(
                    &mut b,
                    &Comment {
                        id: p.i64(r[0]),
                        body: p.bytes(r[1]),
                        created: p.i64(r[2]),
                        updated: p.i64(r[3]),
                        username: p.bytes(r[4]),
                        bio: p.get(r[5]),
                        image: p.get(r[6]),
                        following: false,
                    },
                );
                b.push(b'}');
                out.send(reply, 201, b)
            }
            None => out.error(reply, 404, "article not found"),
        },
    }
}

// ------------------------------------------------------------------------------------------------------------------
// bcrypt workers

/// Worker 0 waits up to the window to fill its lanes, then runs what it has; the others take only full sets, adding
/// capacity under a backlog without splitting a trickle of logins into half-empty runs (as rust-epoll-WorriedArrow).
pub fn bcrypt_worker(index: usize) {
    let s = settings();
    let mut jobs = Vec::new();
    loop {
        if index == 0 {
            BCRYPT.take(bcrypt::LANES, bcrypt::LANES, s.bcrypt_window, &mut jobs);
        } else {
            BCRYPT.take_full(bcrypt::LANES, &mut jobs);
        }
        let mut batch = std::mem::take(&mut jobs);
        // Lanes must share a cost: stored hashes of another cost (never written by this server) run alone.
        let mut odd = Vec::new();
        let mut i = 0;
        while i < batch.len() {
            if cost_of(&batch[i]) != Some(10) {
                odd.push(batch.swap_remove(i));
            } else {
                i += 1;
            }
        }
        run_bcrypt(batch);
        for j in odd {
            run_bcrypt(vec![j]);
        }
    }
}

fn cost_of(j: &BcryptJob) -> Option<u32> {
    match j {
        BcryptJob::Verify { user, .. } => bcrypt::parse(&user.hash).map(|p| p.cost),
        BcryptJob::Hash { .. } => Some(10),
    }
}

fn run_bcrypt(jobs: Vec<BcryptJob>) {
    if jobs.is_empty() {
        return;
    }
    let mut out = Batch::default();
    let mut lanes = Vec::with_capacity(jobs.len());
    let mut ok = Vec::with_capacity(jobs.len());
    for j in jobs {
        let p = match &j {
            BcryptJob::Verify { user, .. } => bcrypt::parse(&user.hash),
            BcryptJob::Hash { .. } => {
                let (salt, salt_text) = bcrypt::new_salt();
                Some(bcrypt::Parsed { variant: b'b', cost: 10, salt, salt_text })
            }
        };
        match (p, j) {
            (Some(p), j) => {
                lanes.push(p);
                ok.push(j);
            }
            (None, BcryptJob::Verify { reply, .. }) => out.error(reply, 401, "invalid email or password"),
            (None, BcryptJob::Hash { .. }) => unreachable!("fresh salts always parse"),
        }
    }
    if ok.is_empty() {
        return;
    }
    let hashes = {
        let jobs: Vec<bcrypt::Job> = ok
            .iter()
            .zip(&lanes)
            .map(|(j, p)| bcrypt::Job {
                password: match j {
                    BcryptJob::Verify { password, .. } | BcryptJob::Hash { password, .. } => password,
                },
                variant: p.variant,
                cost: p.cost,
                salt: p.salt,
                salt_text: p.salt_text,
            })
            .collect();
        jobs.chunks(bcrypt::LANES).flat_map(bcrypt::hash_lanes).collect::<Vec<_>>()
    };
    let keys = settings().keys;
    for (j, h) in ok.into_iter().zip(hashes) {
        match j {
            BcryptJob::Verify { user, reply, .. } => {
                if bcrypt::ct_eq(&h, &user.hash) {
                    let token = keys.issue(user.id);
                    let mut b = Vec::with_capacity(512);
                    render::user(&mut b, &user.email, token.as_bytes(), &user.username, user.bio.as_deref(), user.image.as_deref());
                    out.send(reply, 200, b);
                } else {
                    out.error(reply, 401, "invalid email or password");
                }
            }
            BcryptJob::Hash { mut write, .. } => {
                let h = String::from_utf8(h).expect("bcrypt output is ASCII");
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
