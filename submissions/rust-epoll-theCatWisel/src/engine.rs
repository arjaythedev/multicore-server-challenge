use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hash, Hasher};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::auth::{self, BcryptInput, TokenSigner};
use crate::codec;
use crate::queries;
use crate::reactor::{self, OutgoingReply, ReplyAddr, ReplyBody};
use crate::router::WorkQueue;
use crate::wire::{
    self, ArrayEncoder, BindParam, Cell, DbEndpoint, PgConn, PgError, PgResult, PipelineBuf, OID_INT8, OID_TEXT,
};

pub enum ReadOp {
    Tags,
    CurrentUser { id: i64, token: String },
    Login { email: String, password: Vec<u8> },
    Profile { username: String },
    ArticleBySlug { slug: String },
    ArticleById { id: i64, known_fav: Option<bool> },
    Comments { slug: String },
    Global { lim: i64, off: i64 },
    ByTag { tag: String, lim: i64, off: i64 },
    ByAuthor { username: String, lim: i64, off: i64 },
    ByFavorited { username: String, lim: i64, off: i64 },
    Feed { lim: i64, off: i64 },
}

pub struct ReadTask {
    pub op: ReadOp,
    pub viewer: i64,
    pub addr: ReplyAddr,
}

pub enum WriteOp {
    Register {
        username: String,
        email: String,
        hash: String,
    },
    UpdateUser {
        token: String,
        email: Option<String>,
        username: Option<String>,
        hash: Option<String>,
        bio: Option<String>,
        image: Option<String>,
    },
    Follow {
        username: String,
        on: bool,
    },
    Favorite {
        slug: String,
        on: bool,
    },
    CreateArticle {
        title: String,
        description: String,
        body: String,
        tags: Vec<String>,
    },
    UpdateArticle {
        slug: String,
        title: Option<String>,
        description: Option<String>,
        body: Option<String>,
    },
    DeleteArticle {
        slug: String,
    },
    CreateComment {
        slug: String,
        body: String,
    },
    DeleteComment {
        slug: String,
        id: i64,
    },
}

pub struct WriteTask {
    pub op: WriteOp,
    pub viewer: i64,
    pub addr: ReplyAddr,
}

pub enum CryptoTask {
    VerifyLogin {
        password: Vec<u8>,
        hash: Vec<u8>,
        user: UserRecord,
        addr: ReplyAddr,
    },
    HashPassword {
        password: Vec<u8>,
        write: WriteTask,
    },
}

pub struct UserRecord {
    pub id: i64,
    pub username: Vec<u8>,
    pub email: Vec<u8>,
    pub bio: Option<Vec<u8>>,
    pub image: Option<Vec<u8>>,
}

pub static READ_QUEUE: WorkQueue<ReadTask> = WorkQueue::new();
static BATCH_LOCK: Mutex<()> = Mutex::new(());
static BUSY_READ_WORKERS: AtomicUsize = AtomicUsize::new(0);
static EWMA_BATCH_US: AtomicUsize = AtomicUsize::new(0);
static EWMA_BATCH_LEN: AtomicUsize = AtomicUsize::new(0);
static CRYPTO_LOCK: Mutex<()> = Mutex::new(());
static BUSY_CRYPTO_WORKERS: AtomicUsize = AtomicUsize::new(0);
static EWMA_BCRYPT_US: AtomicUsize = AtomicUsize::new(0);
static EWMA_CRYPTO_LEN: AtomicUsize = AtomicUsize::new(0);
pub static WRITE_QUEUE: WorkQueue<WriteTask> = WorkQueue::new();
pub static CRYPTO_QUEUE: WorkQueue<CryptoTask> = WorkQueue::new();

pub struct RuntimeConfig {
    pub db: DbEndpoint,
    pub signer: &'static TokenSigner,
    pub read_workers: usize,
    pub bcrypt_lanes: usize,
}

pub fn seed_hardware_ewma(batch_us: usize, bcrypt_us: usize) {
    EWMA_BATCH_US.store(batch_us, Ordering::Relaxed);
    EWMA_BCRYPT_US.store(bcrypt_us, Ordering::Relaxed);
}

#[derive(Default)]
pub struct FastHasher(u64);

impl Hasher for FastHasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        let mut h = self.0;
        let mut i = 0;
        while i + 8 <= bytes.len() {
            let w = u64::from_le_bytes(bytes[i..i + 8].try_into().unwrap());
            h = (h.rotate_left(5) ^ w).wrapping_mul(0x517c_c1b7_2722_0a95);
            i += 8;
        }
        if i < bytes.len() {
            let mut tail = 0u64;
            for (shift, &b) in bytes[i..].iter().enumerate() {
                tail |= (b as u64) << (shift * 8);
            }
            h = (h.rotate_left(5) ^ tail).wrapping_mul(0x517c_c1b7_2722_0a95);
        }
        self.0 = h;
    }
    #[inline]
    fn write_u64(&mut self, v: u64) {
        self.0 = (self.0.rotate_left(5) ^ v).wrapping_mul(0x517c_c1b7_2722_0a95);
    }
    #[inline]
    fn write_i64(&mut self, v: i64) {
        self.write_u64(v as u64);
    }
}

type FastMap<K, V> = HashMap<K, V, BuildHasherDefault<FastHasher>>;

struct KeySet<K: Hash + Eq + Clone> {
    index: FastMap<K, u32>,
    items: Vec<K>,
}

impl<K: Hash + Eq + Clone> KeySet<K> {
    fn new() -> Self {
        KeySet {
            index: FastMap::default(),
            items: Vec::new(),
        }
    }

    #[inline]
    fn clear(&mut self) {
        self.index.clear();
        self.items.clear();
    }

    #[inline]
    fn intern(&mut self, key: K) -> u32 {
        if let Some(&idx) = self.index.get(&key) {
            return idx;
        }
        let idx = self.items.len() as u32;
        self.index.insert(key.clone(), idx);
        self.items.push(key);
        idx
    }

    #[inline]
    fn len(&self) -> usize {
        self.items.len()
    }
}

fn group_rows_by_ordinal_into(pipe: &PipelineBuf, res_idx: usize, key_count: usize, grouped: &mut Vec<Vec<usize>>) {
    for g in grouped.iter_mut() {
        g.clear();
    }
    if grouped.len() < key_count {
        grouped.resize_with(key_count, Vec::new);
    } else {
        grouped.truncate(key_count);
    }
    for (row_idx, &span) in pipe.result_rows(res_idx).iter().enumerate() {
        let cols = pipe.row(span);
        let ord = pipe.i64(cols[0]);
        if ord >= 1 && (ord as usize) <= key_count {
            grouped[ord as usize - 1].push(row_idx);
        }
    }
}

fn map_rows_by_i64_into(
    pipe: &PipelineBuf,
    res_idx: Option<usize>,
    keys: &KeySet<i64>,
    col: usize,
    out: &mut Vec<Option<wire::RowSpan>>,
) {
    out.clear();
    out.resize(keys.len(), None);
    if let Some(idx) = res_idx {
        for &span in pipe.result_rows(idx) {
            let r = pipe.row(span);
            if let Some(&ord) = keys.index.get(&pipe.i64(r[col])) {
                out[ord as usize] = Some(span);
            }
        }
    }
}

fn map_rows_by_str_into(
    pipe: &PipelineBuf,
    res_idx: Option<usize>,
    keys: &KeySet<String>,
    col: usize,
    out: &mut Vec<Option<wire::RowSpan>>,
) {
    out.clear();
    out.resize(keys.len(), None);
    if let Some(idx) = res_idx {
        for &span in pipe.result_rows(idx) {
            let r = pipe.row(span);
            if let Some(raw) = pipe.bytes(r[col]) {
                if let Ok(s) = std::str::from_utf8(raw) {
                    if let Some(&ord) = keys.index.get(s) {
                        out[ord as usize] = Some(span);
                    }
                }
            }
        }
    }
}

#[inline]
fn clone_cell_bytes(pipe: &PipelineBuf, cell: Cell) -> Option<Vec<u8>> {
    pipe.bytes(cell).map(|b| b.to_vec())
}

pub fn write_user_envelope(
    dst: &mut Vec<u8>,
    email: &[u8],
    token: &[u8],
    username: &[u8],
    bio: Option<&[u8]>,
    image: Option<&[u8]>,
) {
    dst.extend_from_slice(b"{\"user\":{\"email\":");
    codec::write_str(dst, email);
    dst.extend_from_slice(b",\"token\":");
    codec::write_str(dst, token);
    dst.extend_from_slice(b",\"username\":");
    codec::write_str(dst, username);
    dst.extend_from_slice(b",\"bio\":");
    codec::write_nullable_str(dst, bio);
    dst.extend_from_slice(b",\"image\":");
    codec::write_nullable_str(dst, image);
    dst.extend_from_slice(b"}}");
}

pub fn write_profile_json(
    dst: &mut Vec<u8>,
    username: &[u8],
    bio: Option<&[u8]>,
    image: Option<&[u8]>,
    following: bool,
) {
    dst.extend_from_slice(b"{\"username\":");
    codec::write_str(dst, username);
    dst.extend_from_slice(b",\"bio\":");
    codec::write_nullable_str(dst, bio);
    dst.extend_from_slice(b",\"image\":");
    codec::write_nullable_str(dst, image);
    dst.extend_from_slice(b",\"following\":");
    codec::write_bool(dst, following);
    dst.push(b'}');
}

#[allow(clippy::too_many_arguments)]
fn write_full_article_envelope(
    dst: &mut Vec<u8>,
    slug: &[u8],
    title: &[u8],
    description: &[u8],
    body: &[u8],
    sorted_tags: &[&[u8]],
    created_at: i64,
    updated_at: i64,
    favorited: bool,
    favorites_count: i64,
    author_username: &[u8],
    author_bio: Option<&[u8]>,
    author_image: Option<&[u8]>,
    following: bool,
) {
    dst.extend_from_slice(b"{\"article\":{\"slug\":");
    codec::write_str(dst, slug);
    dst.extend_from_slice(b",\"title\":");
    codec::write_str(dst, title);
    dst.extend_from_slice(b",\"description\":");
    codec::write_str(dst, description);
    dst.extend_from_slice(b",\"body\":");
    codec::write_str(dst, body);
    dst.extend_from_slice(b",\"tagList\":[");
    for (idx, &t) in sorted_tags.iter().enumerate() {
        if idx > 0 {
            dst.push(b',');
        }
        codec::write_str(dst, t);
    }
    dst.extend_from_slice(b"],\"createdAt\":");
    codec::write_timestamp(dst, created_at);
    dst.extend_from_slice(b",\"updatedAt\":");
    codec::write_timestamp(dst, updated_at);
    dst.extend_from_slice(b",\"favorited\":");
    codec::write_bool(dst, favorited);
    dst.extend_from_slice(b",\"favoritesCount\":");
    codec::write_i64(dst, favorites_count);
    dst.extend_from_slice(b",\"author\":");
    write_profile_json(dst, author_username, author_bio, author_image, following);
    dst.extend_from_slice(b"}}");
}

#[derive(Clone, Copy)]
enum PlanSlot {
    Tags,
    User(u32),
    Login(u32),
    Profile(u32),
    BySlug(u32),
    ById(u32, Option<bool>),
    Comments(u32),
    Global(u32),
    Filtered(usize, u32, u32),
    Feed(u32, u32),
}

struct ReadRenderScratch {
    slug_rows: Vec<Option<ArticleRef>>,
    aid_rows: Vec<Option<ArticleRef>>,
    prof_rows: Vec<Option<wire::RowSpan>>,
    uid_rows: Vec<Option<wire::RowSpan>>,
    uemail_rows: Vec<Option<wire::RowSpan>>,
    grp_cmts: Vec<Vec<usize>>,
    cmt_sort_buf: Vec<(i64, i64, wire::RowSpan)>,
    cached_cmts: Vec<Option<Vec<CachedCommentSlice>>>,
    rendered_profiles: Vec<Option<Arc<[u8]>>>,
    rendered_cmts: Vec<Option<Arc<[u8]>>>,
    rendered_slugs: Vec<Option<Arc<[u8]>>>,
    rendered_global: Vec<Option<Arc<[u8]>>>,
    rendered_filters: [Vec<Option<Arc<[u8]>>>; 3],
    global_counts: Vec<i64>,
    global_pages: Vec<ArticlePage>,
    filter_counts: [Vec<i64>; 3],
    filter_pages: [Vec<ArticlePage>; 3],
    feed_counts: Vec<i64>,
    feed_pages: Vec<ArticlePage>,
    raw_pages: Vec<Vec<(i64, i64, wire::RowSpan)>>,
}

impl ReadRenderScratch {
    fn new() -> Self {
        ReadRenderScratch {
            slug_rows: Vec::with_capacity(64),
            aid_rows: Vec::with_capacity(64),
            prof_rows: Vec::with_capacity(64),
            uid_rows: Vec::with_capacity(32),
            uemail_rows: Vec::with_capacity(32),
            grp_cmts: Vec::with_capacity(64),
            cmt_sort_buf: Vec::with_capacity(128),
            cached_cmts: Vec::with_capacity(64),
            rendered_profiles: Vec::with_capacity(64),
            rendered_cmts: Vec::with_capacity(64),
            rendered_slugs: Vec::with_capacity(64),
            rendered_global: Vec::with_capacity(16),
            rendered_filters: [Vec::with_capacity(32), Vec::with_capacity(32), Vec::with_capacity(32)],
            global_counts: Vec::with_capacity(4),
            global_pages: Vec::with_capacity(16),
            filter_counts: [Vec::with_capacity(32), Vec::with_capacity(32), Vec::with_capacity(32)],
            filter_pages: [Vec::with_capacity(32), Vec::with_capacity(32), Vec::with_capacity(32)],
            feed_counts: Vec::with_capacity(64),
            feed_pages: Vec::with_capacity(64),
            raw_pages: Vec::with_capacity(64),
        }
    }
}

struct FilterDedup {
    counts: KeySet<String>,
    pages: KeySet<(u32, i64, i64)>,
}

impl FilterDedup {
    fn new() -> Self {
        FilterDedup {
            counts: KeySet::new(),
            pages: KeySet::new(),
        }
    }

    #[inline]
    fn clear(&mut self) {
        self.counts.clear();
        self.pages.clear();
    }
}

#[derive(Clone, Copy)]
struct ArticleRef {
    aid: i64,
    author: i64,
    art_ord: u32,
    row: wire::RowSpan,
}

type ArticlePage = Vec<ArticleRef>;

fn build_flag_runs(
    pairs: &mut Vec<(i64, i64)>,
    viewers: &mut Vec<i64>,
    targets: &mut Vec<i64>,
    starts: &mut Vec<i32>,
    ends: &mut Vec<i32>,
) {
    pairs.sort_unstable();
    pairs.dedup();
    viewers.clear();
    targets.clear();
    starts.clear();
    ends.clear();
    if pairs.is_empty() {
        return;
    }
    targets.reserve(pairs.len());
    let mut cur_v = pairs[0].0;
    let mut run_start = 1i32;
    for (idx, &(v, t)) in pairs.iter().enumerate() {
        if v != cur_v {
            viewers.push(cur_v);
            starts.push(run_start);
            ends.push(idx as i32);
            cur_v = v;
            run_start = idx as i32 + 1;
        }
        targets.push(t);
    }
    viewers.push(cur_v);
    starts.push(run_start);
    ends.push(pairs.len() as i32);
}

#[derive(Clone, Copy, Default)]
enum MetaSource {
    #[default]
    None,
    PhaseA(wire::RowSpan),
    PhaseB(wire::RowSpan),
}

#[derive(Clone, Copy, Default)]
struct CachedArticleSlices {
    ready: bool,
    head_start: u32,
    head_end: u32,
    mid_end: u32,
    tail_end: u32,
}

#[derive(Clone, Copy)]
struct CachedCommentSlice {
    author_id: i64,
    start: u32,
    end: u32,
}

pub struct ReadWorker {
    conn: Option<PgConn>,
    cfg: &'static RuntimeConfig,
    pa: PipelineBuf,
    pb: PipelineBuf,
    arena: Vec<u8>,
    tag_lut: Vec<Cell>,
    k_uid: KeySet<i64>,
    k_uemail: KeySet<String>,
    k_prof: KeySet<String>,
    k_slug: KeySet<String>,
    k_aid: KeySet<i64>,
    k_cmts: KeySet<String>,
    k_global: KeySet<(i64, i64)>,
    k_filters: [FilterDedup; 3],
    k_feed_cnt: KeySet<i64>,
    k_feed_page: KeySet<(u32, i64, i64)>,
    plan: Vec<PlanSlot>,
    distinct_arts: KeySet<i64>,
    distinct_authors: KeySet<i64>,
    art_author_ords: Vec<u32>,
    art_meta: Vec<MetaSource>,
    meta_req_ids: Vec<i64>,
    art_fav_counts: Vec<i64>,
    art_tag_head: Vec<u32>,
    art_tag_nodes: Vec<(u32, u32)>,
    author_spans: Vec<Option<wire::RowSpan>>,
    fav_pairs: Vec<(i64, i64)>,
    foll_pairs: Vec<(i64, i64)>,
    fav_viewers: Vec<i64>,
    fav_targets: Vec<i64>,
    fav_starts: Vec<i32>,
    fav_ends: Vec<i32>,
    foll_viewers: Vec<i64>,
    foll_targets: Vec<i64>,
    foll_starts: Vec<i32>,
    foll_ends: Vec<i32>,
    fav_hits: Vec<(i64, i64)>,
    foll_hits: Vec<(i64, i64)>,
    cached_arts: Vec<CachedArticleSlices>,
    feed_depths: Vec<i64>,
    enc_a: ArrayEncoder,
    enc_b: ArrayEncoder,
    enc_c: ArrayEncoder,
    rr: ReadRenderScratch,
}

const FILTER_STMT_NAMES: [&str; 3] = ["tag", "author", "favlist"];

impl ReadWorker {
    pub fn new(cfg: &'static RuntimeConfig) -> Self {
        ReadWorker {
            conn: None,
            cfg,
            pa: PipelineBuf::with_capacity(),
            pb: PipelineBuf::with_capacity(),
            arena: Vec::with_capacity(128 * 1024),
            tag_lut: Vec::with_capacity(256),
            k_uid: KeySet::new(),
            k_uemail: KeySet::new(),
            k_prof: KeySet::new(),
            k_slug: KeySet::new(),
            k_aid: KeySet::new(),
            k_cmts: KeySet::new(),
            k_global: KeySet::new(),
            k_filters: [FilterDedup::new(), FilterDedup::new(), FilterDedup::new()],
            k_feed_cnt: KeySet::new(),
            k_feed_page: KeySet::new(),
            plan: Vec::with_capacity(256),
            distinct_arts: KeySet::new(),
            distinct_authors: KeySet::new(),
            art_author_ords: Vec::with_capacity(256),
            art_meta: Vec::with_capacity(256),
            meta_req_ids: Vec::with_capacity(256),
            art_fav_counts: Vec::with_capacity(256),
            art_tag_head: Vec::with_capacity(256),
            art_tag_nodes: Vec::with_capacity(512),
            author_spans: Vec::with_capacity(128),
            fav_pairs: Vec::with_capacity(512),
            foll_pairs: Vec::with_capacity(512),
            fav_viewers: Vec::with_capacity(64),
            fav_targets: Vec::with_capacity(512),
            fav_starts: Vec::with_capacity(64),
            fav_ends: Vec::with_capacity(64),
            foll_viewers: Vec::with_capacity(64),
            foll_targets: Vec::with_capacity(512),
            foll_starts: Vec::with_capacity(64),
            foll_ends: Vec::with_capacity(64),
            fav_hits: Vec::with_capacity(128),
            foll_hits: Vec::with_capacity(128),
            cached_arts: Vec::with_capacity(256),
            feed_depths: Vec::with_capacity(128),
            enc_a: ArrayEncoder::with_capacity(OID_INT8, 256),
            enc_b: ArrayEncoder::with_capacity(OID_INT8, 256),
            enc_c: ArrayEncoder::with_capacity(OID_INT8, 256),
            rr: ReadRenderScratch::new(),
        }
    }

    fn ensure_conn<'a>(conn_slot: &'a mut Option<PgConn>, cfg: &RuntimeConfig) -> PgResult<&'a mut PgConn> {
        if conn_slot.is_none() {
            let mut c = PgConn::connect(&cfg.db)?;
            let defs = queries::read_catalog();
            let refs: Vec<(&str, &str, &[u32])> = defs.iter().map(|d| (d.name, d.sql.as_str(), d.oids)).collect();
            c.prepare_batch(&refs)?;
            *conn_slot = Some(c);
        }
        Ok(conn_slot.as_mut().unwrap())
    }

    pub fn run_loop(mut self) {
        let mut tasks = Vec::new();
        let mut err_addrs = Vec::new();
        let rw = self.cfg.read_workers.max(2);
        let lanes = self.cfg.bcrypt_lanes.max(2);
        let num_families = queries::read_catalog().len();
        let base_batch = num_families * rw * 2;
        let max_batch = base_batch * rw * 2;
        loop {
            tasks.clear();
            {
                let _guard = BATCH_LOCK.lock().unwrap();
                let busy = BUSY_READ_WORKERS.load(Ordering::Relaxed).min(rw);
                let ewma_len = EWMA_BATCH_LEN.load(Ordering::Relaxed);
                let tau_us = EWMA_BATCH_US.load(Ordering::Relaxed);
                let bcrypt_us = EWMA_BCRYPT_US.load(Ordering::Relaxed);
                let (want, max_age) = if busy == 0 && ewma_len <= 2 {
                    (rw, Duration::from_micros((tau_us / rw).max(1) as u64))
                } else {
                    let target = (ewma_len + (ewma_len >> 1)).max(base_batch).min(max_batch);
                    (target, Duration::from_micros((bcrypt_us / lanes).max(1) as u64))
                };
                READ_QUEUE.take_aged(want, max_age, max_batch, &mut tasks);
            }
            tasks.retain(|t| reactor::is_addr_alive(t.addr));
            if tasks.is_empty() {
                continue;
            }
            let batch_n = tasks.len();
            BUSY_READ_WORKERS.fetch_add(1, Ordering::Relaxed);
            let t0 = Instant::now();
            let res = self.execute_batch(&mut tasks, &mut err_addrs);
            let elapsed_us = t0.elapsed().as_micros() as usize;
            BUSY_READ_WORKERS.fetch_sub(1, Ordering::Relaxed);

            let prev_us = EWMA_BATCH_US.load(Ordering::Relaxed);
            let next_us = if prev_us == 0 {
                elapsed_us
            } else {
                (prev_us * 3 + elapsed_us) / 4
            }
            .clamp(200, 100_000);
            EWMA_BATCH_US.store(next_us, Ordering::Relaxed);

            let prev_n = EWMA_BATCH_LEN.load(Ordering::Relaxed);
            let next_n = if prev_n == 0 {
                batch_n
            } else {
                (prev_n * 3 + batch_n) / 4
            };
            EWMA_BATCH_LEN.store(next_n, Ordering::Relaxed);

            if let Err(err) = res {
                eprintln!("read batch error: {err}");
                self.conn = None;
                reactor::complete_batch(
                    err_addrs
                        .drain(..)
                        .map(|a| reactor::error_reply(a, 500, "internal server error"))
                        .collect(),
                );
            }
        }
    }

    fn execute_batch(&mut self, tasks: &mut Vec<ReadTask>, err_addrs: &mut Vec<ReplyAddr>) -> PgResult<()> {
        err_addrs.clear();
        err_addrs.extend(tasks.iter().map(|t| t.addr));

        let mut need_tags_endpoint = false;
        self.k_uid.clear();
        self.k_uemail.clear();
        self.k_prof.clear();
        self.k_slug.clear();
        self.k_aid.clear();
        self.k_cmts.clear();
        self.k_global.clear();
        for fd in &mut self.k_filters {
            fd.clear();
        }
        self.k_feed_cnt.clear();
        self.k_feed_page.clear();
        self.plan.clear();

        for t in tasks.iter() {
            let slot = match &t.op {
                ReadOp::Tags => {
                    need_tags_endpoint = true;
                    PlanSlot::Tags
                }
                ReadOp::CurrentUser { id, .. } => PlanSlot::User(self.k_uid.intern(*id)),
                ReadOp::Login { email, .. } => PlanSlot::Login(self.k_uemail.intern(email.clone())),
                ReadOp::Profile { username } => PlanSlot::Profile(self.k_prof.intern(username.clone())),
                ReadOp::ArticleBySlug { slug } => PlanSlot::BySlug(self.k_slug.intern(slug.clone())),
                ReadOp::ArticleById { id, known_fav } => PlanSlot::ById(self.k_aid.intern(*id), *known_fav),
                ReadOp::Comments { slug } => PlanSlot::Comments(self.k_cmts.intern(slug.clone())),
                ReadOp::Global { lim, off } => PlanSlot::Global(self.k_global.intern((*lim, *off))),
                ReadOp::ByTag { tag: key, lim, off }
                | ReadOp::ByAuthor {
                    username: key,
                    lim,
                    off,
                }
                | ReadOp::ByFavorited {
                    username: key,
                    lim,
                    off,
                } => {
                    let kind = match &t.op {
                        ReadOp::ByTag { .. } => 0,
                        ReadOp::ByAuthor { .. } => 1,
                        _ => 2,
                    };
                    let fd = &mut self.k_filters[kind];
                    let c_ord = fd.counts.intern(key.clone());
                    let p_ord = fd.pages.intern((c_ord, *lim, *off));
                    PlanSlot::Filtered(kind, c_ord, p_ord)
                }
                ReadOp::Feed { lim, off } => {
                    let c_ord = self.k_feed_cnt.intern(t.viewer);
                    let p_ord = self.k_feed_page.intern((c_ord, *lim, *off));
                    PlanSlot::Feed(c_ord, p_ord)
                }
            };
            self.plan.push(slot);
        }

        let touches_articles = self.k_slug.len()
            + self.k_aid.len()
            + self.k_global.len()
            + self.k_filters[0].pages.len()
            + self.k_filters[1].pages.len()
            + self.k_filters[2].pages.len()
            + self.k_feed_cnt.len()
            > 0;

        let conn = Self::ensure_conn(&mut self.conn, self.cfg)?;
        let mut n_phase_a = 0usize;
        let mut alloc_slot = |active: bool| -> Option<usize> {
            if active {
                let s = n_phase_a;
                n_phase_a += 1;
                Some(s)
            } else {
                None
            }
        };

        let st_tags = alloc_slot(need_tags_endpoint || touches_articles);
        let st_uid = alloc_slot(self.k_uid.len() > 0);
        let st_uemail = alloc_slot(self.k_uemail.len() > 0);
        let st_prof = alloc_slot(self.k_prof.len() > 0);
        let st_slug = alloc_slot(self.k_slug.len() > 0);
        let st_aid = alloc_slot(self.k_aid.len() > 0);
        let st_cmts = alloc_slot(self.k_cmts.len() > 0);
        let st_global = alloc_slot(self.k_global.len() > 0);
        let st_filters: [Option<usize>; 3] = std::array::from_fn(|i| alloc_slot(self.k_filters[i].pages.len() > 0));
        let st_feed = alloc_slot(self.k_feed_cnt.len() > 0);
        let n_phase_a1 = usize::from(st_tags.is_some())
            + usize::from(st_uid.is_some())
            + usize::from(st_uemail.is_some());
        let n_phase_a2 = n_phase_a - n_phase_a1;

        let tx = &mut conn.tx;
        if n_phase_a1 > 0 {
            if st_tags.is_some() {
                tx.bind_and_exec("tags", &[]);
            }
            if st_uid.is_some() {
                tx.bind_and_exec("uid", &[BindParam::I64Slice(&self.k_uid.items)]);
            }
            if st_uemail.is_some() {
                tx.bind_and_exec("uemail", &[BindParam::TextSlice(&self.k_uemail.items)]);
            }
            tx.write_sync();
        }

        let mut global_win_max: i64 = 0;
        let mut use_global_win = self.k_global.len() > 0;
        for &(l, o) in &self.k_global.items {
            let end = l.saturating_add(o);
            if end > 200 {
                use_global_win = false;
                break;
            }
            if end > global_win_max {
                global_win_max = end;
            }
        }
        if n_phase_a2 > 0 {
            if st_prof.is_some() {
                tx.bind_and_exec("prof", &[BindParam::TextSlice(&self.k_prof.items)]);
            }
            if st_slug.is_some() {
                tx.bind_and_exec("aslug", &[BindParam::TextSlice(&self.k_slug.items)]);
            }
            if st_aid.is_some() {
                tx.bind_and_exec("aid", &[BindParam::I64Slice(&self.k_aid.items)]);
            }
            if st_cmts.is_some() {
                tx.bind_and_exec("cmts", &[BindParam::TextSlice(&self.k_cmts.items)]);
            }
            if st_global.is_some() {
                if use_global_win {
                    tx.bind_and_exec("global_win", &[BindParam::I64(global_win_max.max(1))]);
                } else {
                    self.enc_b.reset(OID_INT8, self.k_global.items.len());
                    self.enc_c.reset(OID_INT8, self.k_global.items.len());
                    for &(l, o) in &self.k_global.items {
                        self.enc_b.push_i64(l);
                        self.enc_c.push_i64(o);
                    }
                    tx.bind_and_exec(
                        "global",
                        &[
                            BindParam::Raw(self.enc_b.finish()),
                            BindParam::Raw(self.enc_c.finish()),
                        ],
                    );
                }
            }
            for i in 0..3 {
                if st_filters[i].is_some() {
                    let fd = &self.k_filters[i];
                    self.enc_a.reset(OID_INT8, fd.pages.items.len());
                    self.enc_b.reset(OID_INT8, fd.pages.items.len());
                    self.enc_c.reset(OID_INT8, fd.pages.items.len());
                    for &(c_ord, l, o) in &fd.pages.items {
                        self.enc_a.push_i64(c_ord as i64 + 1);
                        self.enc_b.push_i64(l);
                        self.enc_c.push_i64(o);
                    }
                    tx.bind_and_exec(
                        FILTER_STMT_NAMES[i],
                        &[
                            BindParam::TextSlice(&fd.counts.items),
                            BindParam::Raw(self.enc_a.finish()),
                            BindParam::Raw(self.enc_b.finish()),
                            BindParam::Raw(self.enc_c.finish()),
                        ],
                    );
                }
            }
            if st_feed.is_some() {
                self.feed_depths.clear();
                self.feed_depths.resize(self.k_feed_cnt.items.len(), 1);
                self.enc_a.reset(OID_INT8, self.k_feed_page.items.len());
                self.enc_b.reset(OID_INT8, self.k_feed_page.items.len());
                self.enc_c.reset(OID_INT8, self.k_feed_page.items.len());
                for &(c_ord, l, o) in &self.k_feed_page.items {
                    let d = l.saturating_add(o).max(1);
                    if d > self.feed_depths[c_ord as usize] {
                        self.feed_depths[c_ord as usize] = d;
                    }
                    self.enc_a.push_i64(c_ord as i64 + 1);
                    self.enc_b.push_i64(l);
                    self.enc_c.push_i64(o);
                }
                tx.bind_and_exec(
                    "feed",
                    &[
                        BindParam::I64Slice(&self.k_feed_cnt.items),
                        BindParam::I64Slice(&self.feed_depths),
                        BindParam::Raw(self.enc_a.finish()),
                        BindParam::Raw(self.enc_b.finish()),
                        BindParam::Raw(self.enc_c.finish()),
                    ],
                );
            }
            tx.write_sync();
        }
        conn.flush()?;
        self.pa.clear();
        self.tag_lut.clear();

        if n_phase_a1 > 0 {
            conn.read_pipeline_append(n_phase_a1, &mut self.pa)?;
            if let Some(failed) = self.pa.results.iter().find(|r| r.error.is_some()) {
                return Err(PgError::Wire(format!("phase A1 error: {}", failed.error.as_ref().unwrap())));
            }
            if need_tags_endpoint {
                if let Some(s) = st_tags {
                    let r = &self.pa.results[s];
                    let (start, end) = (r.row_start as usize, (r.row_start + r.row_count) as usize);
                    let data = &self.pa.data;
                    let cols = &self.pa.cols;
                    self.pa.rows[start..end].sort_unstable_by(|&a, &b| {
                        let ca = cols[a.start as usize + 1];
                        let cb = cols[b.start as usize + 1];
                        let sa = &data[ca.offset as usize..ca.offset as usize + ca.len.max(0) as usize];
                        let sb = &data[cb.offset as usize..cb.offset as usize + cb.len.max(0) as usize];
                        sa.cmp(sb)
                    });
                }
            }
            let pa = &self.pa;
            if touches_articles {
                if let Some(s) = st_tags {
                    let rows = pa.result_rows(s);
                    self.tag_lut.resize(rows.len() + 64, Cell { offset: 0, len: -1 });
                    for &span in rows {
                        let r = pa.row(span);
                        let tid = pa.i64(r[0]) as usize;
                        if tid >= self.tag_lut.len() {
                            self.tag_lut.resize(tid + 16, Cell { offset: 0, len: -1 });
                        }
                        self.tag_lut[tid] = r[1];
                    }
                }
            }
            map_rows_by_i64_into(pa, st_uid, &self.k_uid, 0, &mut self.rr.uid_rows);
            map_rows_by_str_into(pa, st_uemail, &self.k_uemail, 2, &mut self.rr.uemail_rows);
            let uid_rows = &self.rr.uid_rows;
            let uemail_rows = &self.rr.uemail_rows;
            let mut early_replies: Vec<OutgoingReply> = Vec::new();
            let mut login_tasks: Vec<CryptoTask> = Vec::new();
            let mut rendered_tags: Option<Arc<[u8]>> = None;

            if need_tags_endpoint || st_uid.is_some() || st_uemail.is_some() {
                for (task, &slot) in tasks.iter_mut().zip(self.plan.iter()) {
                    match slot {
                        PlanSlot::Tags => {
                            let shared = if let Some(cached) = &rendered_tags {
                                cached.clone()
                            } else {
                                let s = st_tags.unwrap();
                                let mut buf = Vec::with_capacity(4096);
                                buf.extend_from_slice(b"{\"tags\":[");
                                for (i, &span) in pa.result_rows(s).iter().enumerate() {
                                    if i > 0 {
                                        buf.push(b',');
                                    }
                                    codec::write_str(&mut buf, pa.bytes(pa.row(span)[1]).unwrap_or(b""));
                                }
                                buf.extend_from_slice(b"]}");
                                let arc: Arc<[u8]> = buf.into();
                                rendered_tags = Some(arc.clone());
                                arc
                            };
                            early_replies.push(OutgoingReply {
                                addr: task.addr,
                                status: 200,
                                body: ReplyBody::Shared(shared),
                            });
                        }
                        PlanSlot::User(k) => {
                            let ReadOp::CurrentUser { token, .. } = &task.op else {
                                unreachable!()
                            };
                            match uid_rows.get(k as usize).copied().flatten() {
                                Some(span) => {
                                    let r = pa.row(span);
                                    let mut body = Vec::with_capacity(512);
                                    write_user_envelope(
                                        &mut body,
                                        pa.bytes(r[2]).unwrap_or(b""),
                                        token.as_bytes(),
                                        pa.bytes(r[1]).unwrap_or(b""),
                                        pa.bytes(r[3]),
                                        pa.bytes(r[4]),
                                    );
                                    early_replies.push(OutgoingReply {
                                        addr: task.addr,
                                        status: 200,
                                        body: ReplyBody::Owned(body),
                                    });
                                }
                                None => early_replies.push(reactor::error_reply(task.addr, 401, "unauthorized")),
                            }
                        }
                        PlanSlot::Login(k) => {
                            let ReadOp::Login { password, .. } = &mut task.op else {
                                unreachable!()
                            };
                            let pw = std::mem::take(password);
                            match uemail_rows.get(k as usize).copied().flatten() {
                                Some(span) => {
                                    let r = pa.row(span);
                                    let user = UserRecord {
                                        id: pa.i64(r[0]),
                                        username: clone_cell_bytes(pa, r[1]).unwrap_or_default(),
                                        email: clone_cell_bytes(pa, r[2]).unwrap_or_default(),
                                        bio: clone_cell_bytes(pa, r[3]),
                                        image: clone_cell_bytes(pa, r[4]),
                                    };
                                    let hash = clone_cell_bytes(pa, r[5]).unwrap_or_default();
                                    login_tasks.push(CryptoTask::VerifyLogin {
                                        password: pw,
                                        hash,
                                        user,
                                        addr: task.addr,
                                    });
                                }
                                None => early_replies.push(reactor::error_reply(task.addr, 401, "invalid email or password")),
                            }
                        }
                        _ => {}
                    }
                }
            }
            if !login_tasks.is_empty() {
                CRYPTO_QUEUE.push_batch(&mut login_tasks);
            }
            if !early_replies.is_empty() {
                reactor::complete_batch(early_replies);
            }
            err_addrs.clear();
            for (t, &slot) in tasks.iter().zip(self.plan.iter()) {
                if !matches!(slot, PlanSlot::Tags | PlanSlot::User(_) | PlanSlot::Login(_)) {
                    err_addrs.push(t.addr);
                }
            }
            if n_phase_a2 == 0 {
                tasks.clear();
                return Ok(());
            }
        }

        conn.read_pipeline_append(n_phase_a2, &mut self.pa)?;
        if let Some(failed) = self.pa.results[n_phase_a1..].iter().find(|r| r.error.is_some()) {
            return Err(PgError::Wire(format!("phase A2 error: {}", failed.error.as_ref().unwrap())));
        }

        self.distinct_arts.clear();
        self.distinct_authors.clear();
        self.art_author_ords.clear();
        self.art_meta.clear();

        let pa = &self.pa;
        map_rows_by_str_into(pa, st_prof, &self.k_prof, 1, &mut self.rr.prof_rows);
        if let Some(idx) = st_cmts {
            group_rows_by_ordinal_into(pa, idx, self.k_cmts.len(), &mut self.rr.grp_cmts);
        } else {
            self.rr.grp_cmts.clear();
        }
        let prof_rows = &self.rr.prof_rows;
        let grp_cmts = &self.rr.grp_cmts;

        let mut intern_art = |aid: i64, author: i64, span: wire::RowSpan, meta_src: MetaSource| -> ArticleRef {
            let prev_len = self.distinct_arts.len();
            let ord = self.distinct_arts.intern(aid);
            if (ord as usize) == prev_len {
                let au_ord = self.distinct_authors.intern(author);
                self.art_author_ords.push(au_ord);
                self.art_meta.push(meta_src);
            } else if !matches!(meta_src, MetaSource::None) && matches!(self.art_meta[ord as usize], MetaSource::None) {
                self.art_meta[ord as usize] = meta_src;
            }
            ArticleRef {
                aid,
                author,
                art_ord: ord,
                row: span,
            }
        };

        self.rr.slug_rows.clear();
        self.rr.slug_rows.resize(self.k_slug.len(), None);
        if let Some(idx) = st_slug {
            for &span in pa.result_rows(idx) {
                let r = pa.row(span);
                if let Some(raw) = pa.bytes(r[3]) {
                    if let Ok(s) = std::str::from_utf8(raw) {
                        if let Some(&ord) = self.k_slug.index.get(s) {
                            self.rr.slug_rows[ord as usize] =
                                Some(intern_art(pa.i64(r[1]), pa.i64(r[2]), span, MetaSource::PhaseA(span)));
                        }
                    }
                }
            }
        }
        self.rr.aid_rows.clear();
        self.rr.aid_rows.resize(self.k_aid.len(), None);
        if let Some(idx) = st_aid {
            for &span in pa.result_rows(idx) {
                let r = pa.row(span);
                let aid = pa.i64(r[1]);
                if let Some(&ord) = self.k_aid.index.get(&aid) {
                    self.rr.aid_rows[ord as usize] =
                        Some(intern_art(aid, pa.i64(r[2]), span, MetaSource::PhaseA(span)));
                }
            }
        }
        let slug_rows = &self.rr.slug_rows;
        let aid_rows = &self.rr.aid_rows;

        let raw_pages = &mut self.rr.raw_pages;
        let mut unpack_list_into = |s: Option<usize>,
                                    n_cnt: usize,
                                    n_page: usize,
                                    has_meta: bool,
                                    counts: &mut Vec<i64>,
                                    pages: &mut Vec<ArticlePage>| {
            counts.clear();
            counts.resize(n_cnt.max(1), 0);
            for p in pages.iter_mut() {
                p.clear();
            }
            if pages.len() < n_page {
                pages.resize_with(n_page, Vec::new);
            } else {
                pages.truncate(n_page);
            }
            if let Some(idx) = s {
                for rp in raw_pages.iter_mut() {
                    rp.clear();
                }
                if raw_pages.len() < n_page {
                    raw_pages.resize_with(n_page, Vec::new);
                } else {
                    raw_pages.truncate(n_page);
                }
                for &span in pa.result_rows(idx) {
                    let r = pa.row(span);
                    let ord = pa.i64(r[0]);
                    if ord <= 0 {
                        let c_idx = (-ord) as usize;
                        let c_idx = if c_idx == 0 { 0 } else { c_idx - 1 };
                        if c_idx < counts.len() {
                            counts[c_idx] = pa.i64(r[1]);
                        }
                    } else if (ord as usize) <= n_page {
                        raw_pages[ord as usize - 1].push((pa.i64(r[1]), pa.i64(r[2]), span));
                    }
                }
                for (p_idx, rp) in raw_pages.iter_mut().enumerate() {
                    if rp.len() > 1 {
                        rp.sort_unstable_by(|a, b| b.0.cmp(&a.0));
                    }
                    let dst = &mut pages[p_idx];
                    dst.reserve(rp.len());
                    for &(aid, author, span) in rp.iter() {
                        dst.push(intern_art(
                            aid,
                            author,
                            span,
                            if has_meta {
                                MetaSource::PhaseA(span)
                            } else {
                                MetaSource::None
                            },
                        ));
                    }
                }
            }
        };

        if use_global_win {
            unpack_list_into(
                st_global,
                1,
                1,
                true,
                &mut self.rr.global_counts,
                &mut self.rr.global_pages,
            );
            let win = self.rr.global_pages.pop().unwrap_or_default();
            let n_g = self.k_global.items.len();
            for p in self.rr.global_pages.iter_mut() {
                p.clear();
            }
            if self.rr.global_pages.len() < n_g {
                self.rr.global_pages.resize_with(n_g, Vec::new);
            } else {
                self.rr.global_pages.truncate(n_g);
            }
            for (idx, &(lim, off)) in self.k_global.items.iter().enumerate() {
                let start = (off.max(0) as usize).min(win.len());
                let end = start.saturating_add(lim.max(0) as usize).min(win.len());
                self.rr.global_pages[idx].extend_from_slice(&win[start..end]);
            }
        } else {
            unpack_list_into(
                st_global,
                1,
                self.k_global.len(),
                true,
                &mut self.rr.global_counts,
                &mut self.rr.global_pages,
            );
        }
        for i in 0..3 {
            unpack_list_into(
                st_filters[i],
                self.k_filters[i].counts.len(),
                self.k_filters[i].pages.len(),
                i != 1,
                &mut self.rr.filter_counts[i],
                &mut self.rr.filter_pages[i],
            );
        }
        unpack_list_into(
            st_feed,
            self.k_feed_cnt.len(),
            self.k_feed_page.len(),
            false,
            &mut self.rr.feed_counts,
            &mut self.rr.feed_pages,
        );
        let global_pages = &self.rr.global_pages;
        let filter_pages = &self.rr.filter_pages;
        let feed_pages = &self.rr.feed_pages;

        self.meta_req_ids.clear();
        for (k, &meta) in self.art_meta.iter().enumerate() {
            if matches!(meta, MetaSource::None) {
                self.meta_req_ids.push(self.distinct_arts.items[k]);
            }
        }

        self.fav_pairs.clear();
        self.foll_pairs.clear();

        for (task, slot) in tasks.iter().zip(self.plan.iter()) {
            let viewer = task.viewer;
            if viewer == 0 {
                continue;
            }
            match *slot {
                PlanSlot::BySlug(k) => {
                    if let Some(art) = slug_rows[k as usize] {
                        self.fav_pairs.push((viewer, art.aid));
                        self.foll_pairs.push((viewer, art.author));
                    }
                }
                PlanSlot::ById(k, known_fav) => {
                    if let Some(art) = aid_rows[k as usize] {
                        if known_fav.is_none() {
                            self.fav_pairs.push((viewer, art.aid));
                        }
                        self.foll_pairs.push((viewer, art.author));
                    }
                }
                PlanSlot::Global(p) => {
                    for &art in &global_pages[p as usize] {
                        self.fav_pairs.push((viewer, art.aid));
                        self.foll_pairs.push((viewer, art.author));
                    }
                }
                PlanSlot::Filtered(kind, _, p) => {
                    let rows = &filter_pages[kind][p as usize];
                    if kind == 1 {
                        if let Some(&first) = rows.first() {
                            self.foll_pairs.push((viewer, first.author));
                        }
                        for &art in rows {
                            self.fav_pairs.push((viewer, art.aid));
                        }
                    } else {
                        for &art in rows {
                            self.fav_pairs.push((viewer, art.aid));
                            self.foll_pairs.push((viewer, art.author));
                        }
                    }
                }
                PlanSlot::Feed(_, p) => {
                    for &art in &feed_pages[p as usize] {
                        self.fav_pairs.push((viewer, art.aid));
                    }
                }
                PlanSlot::Comments(k) => {
                    if let Some(s) = st_cmts {
                        let rows = pa.result_rows(s);
                        for &row_i in &grp_cmts[k as usize] {
                            let r = pa.row(rows[row_i]);
                            if r[1].len >= 0 {
                                self.foll_pairs.push((viewer, pa.i64(r[5])));
                            }
                        }
                    }
                }
                PlanSlot::Profile(k) => {
                    if let Some(span) = prof_rows.get(k as usize).copied().flatten() {
                        let r = pa.row(span);
                        self.foll_pairs.push((viewer, pa.i64(r[0])));
                    }
                }
                PlanSlot::Tags | PlanSlot::User(_) | PlanSlot::Login(_) => {}
            }
        }

        build_flag_runs(
            &mut self.fav_pairs,
            &mut self.fav_viewers,
            &mut self.fav_targets,
            &mut self.fav_starts,
            &mut self.fav_ends,
        );
        build_flag_runs(
            &mut self.foll_pairs,
            &mut self.foll_viewers,
            &mut self.foll_targets,
            &mut self.foll_starts,
            &mut self.foll_ends,
        );

        let mut n_phase_b = 0usize;
        let mut alloc_b = |active: bool| -> Option<usize> {
            if active {
                let s = n_phase_b;
                n_phase_b += 1;
                Some(s)
            } else {
                None
            }
        };
        let b_artmeta = alloc_b(!self.meta_req_ids.is_empty());
        let b_artx = alloc_b(self.distinct_arts.len() > 0);
        let b_artau = alloc_b(self.distinct_authors.len() > 0);
        let b_flags = alloc_b(!self.fav_viewers.is_empty() || !self.foll_viewers.is_empty());

        if n_phase_b > 0 {
            let tx = &mut conn.tx;
            if b_artmeta.is_some() {
                tx.bind_and_exec("artmeta", &[BindParam::I64Slice(&self.meta_req_ids)]);
            }
            if b_artx.is_some() {
                tx.bind_and_exec("artx", &[BindParam::I64Slice(&self.distinct_arts.items)]);
            }
            if b_artau.is_some() {
                tx.bind_and_exec("artau", &[BindParam::I64Slice(&self.distinct_authors.items)]);
            }
            if b_flags.is_some() {
                tx.bind_and_exec(
                    "flags",
                    &[
                        BindParam::I64Slice(&self.fav_viewers),
                        BindParam::I64Slice(&self.fav_targets),
                        BindParam::I32Slice(&self.fav_starts),
                        BindParam::I32Slice(&self.fav_ends),
                        BindParam::I64Slice(&self.foll_viewers),
                        BindParam::I64Slice(&self.foll_targets),
                        BindParam::I32Slice(&self.foll_starts),
                        BindParam::I32Slice(&self.foll_ends),
                    ],
                );
            }
            tx.write_sync();
            conn.flush()?;
        } else {
            self.pb.clear();
        }

        self.author_spans.clear();
        self.author_spans.resize(self.distinct_authors.len(), None);
        self.cached_arts.clear();
        self.cached_arts
            .resize(self.distinct_arts.len(), CachedArticleSlices::default());
        self.arena.clear();
        self.fav_hits.clear();
        self.foll_hits.clear();

        self.rr.cached_cmts.clear();
        self.rr.rendered_profiles.clear();
        self.rr.rendered_profiles.resize(self.k_prof.len(), None);
        self.rr.rendered_cmts.clear();
        self.rr.rendered_cmts.resize(self.k_cmts.len(), None);
        {
            let pa = &self.pa;
            let arena = &mut self.arena;
            let cached_cmts = &mut self.rr.cached_cmts;
            let cmt_sort_buf = &mut self.rr.cmt_sort_buf;
            let rendered_profiles = &mut self.rr.rendered_profiles;
            let rendered_cmts = &mut self.rr.rendered_cmts;
            if let Some(s) = st_cmts {
                let cmt_rows = pa.result_rows(s);
                for row_indices in grp_cmts {
                    if row_indices.is_empty() {
                        cached_cmts.push(None);
                        continue;
                    }
                    cmt_sort_buf.clear();
                    for &i in row_indices {
                        let span = cmt_rows[i];
                        let r = pa.row(span);
                        if r[1].len >= 0 && r[6].len >= 0 {
                            cmt_sort_buf.push((pa.i64(r[3]), pa.i64(r[1]), span));
                        }
                    }
                    cmt_sort_buf.sort_unstable_by(|a, b| (b.0, b.1).cmp(&(a.0, a.1)));
                    let mut list = Vec::with_capacity(cmt_sort_buf.len());
                    for &(_, cid, span) in cmt_sort_buf.iter() {
                        let r = pa.row(span);
                        let start = arena.len() as u32;
                        arena.extend_from_slice(b"{\"id\":");
                        codec::write_i64(arena, cid);
                        arena.extend_from_slice(b",\"createdAt\":");
                        codec::write_timestamp(arena, pa.i64(r[3]));
                        arena.extend_from_slice(b",\"updatedAt\":");
                        codec::write_timestamp(arena, pa.i64(r[4]));
                        arena.extend_from_slice(b",\"body\":");
                        codec::write_str(arena, pa.bytes(r[2]).unwrap_or(b""));
                        arena.extend_from_slice(b",\"author\":{\"username\":");
                        codec::write_str(arena, pa.bytes(r[6]).unwrap_or(b""));
                        arena.extend_from_slice(b",\"bio\":");
                        codec::write_nullable_str(arena, pa.bytes(r[7]));
                        arena.extend_from_slice(b",\"image\":");
                        codec::write_nullable_str(arena, pa.bytes(r[8]));
                        arena.extend_from_slice(b",\"following\":");
                        let end = arena.len() as u32;
                        list.push(CachedCommentSlice {
                            author_id: pa.i64(r[5]),
                            start,
                            end,
                        });
                    }
                    cached_cmts.push(Some(list));
                }
            }

            if st_prof.is_some() || st_cmts.is_some() {
                let mut mid_replies: Vec<OutgoingReply> = Vec::new();
                for (task, &slot) in tasks.iter().zip(self.plan.iter()) {
                    if task.viewer != 0 {
                        continue;
                    }
                    let addr = task.addr;
                    match slot {
                        PlanSlot::Profile(k) => match prof_rows.get(k as usize).copied().flatten() {
                            Some(span) => {
                                if let Some(shared) = &rendered_profiles[k as usize] {
                                    mid_replies.push(OutgoingReply {
                                        addr,
                                        status: 200,
                                        body: ReplyBody::Shared(shared.clone()),
                                    });
                                } else {
                                    let r = pa.row(span);
                                    let mut body = Vec::with_capacity(256);
                                    body.extend_from_slice(b"{\"profile\":");
                                    write_profile_json(
                                        &mut body,
                                        pa.bytes(r[1]).unwrap_or(b""),
                                        pa.bytes(r[2]),
                                        pa.bytes(r[3]),
                                        false,
                                    );
                                    body.push(b'}');
                                    let arc: Arc<[u8]> = body.into();
                                    rendered_profiles[k as usize] = Some(arc.clone());
                                    mid_replies.push(OutgoingReply {
                                        addr,
                                        status: 200,
                                        body: ReplyBody::Shared(arc),
                                    });
                                }
                            }
                            None => mid_replies.push(reactor::error_reply(addr, 404, "profile not found")),
                        },
                        PlanSlot::Comments(k) => {
                            let Some(list) = &cached_cmts[k as usize] else {
                                mid_replies.push(reactor::error_reply(addr, 404, "article not found"));
                                continue;
                            };
                            if let Some(shared) = &rendered_cmts[k as usize] {
                                mid_replies.push(OutgoingReply {
                                    addr,
                                    status: 200,
                                    body: ReplyBody::Shared(shared.clone()),
                                });
                            } else {
                                let mut body = Vec::with_capacity(64 + 320 * list.len());
                                body.extend_from_slice(b"{\"comments\":[");
                                for (idx, c) in list.iter().enumerate() {
                                    if idx > 0 {
                                        body.push(b',');
                                    }
                                    body.extend_from_slice(&arena[c.start as usize..c.end as usize]);
                                    body.extend_from_slice(b"false}}");
                                }
                                body.extend_from_slice(b"]}");
                                let arc: Arc<[u8]> = body.into();
                                rendered_cmts[k as usize] = Some(arc.clone());
                                mid_replies.push(OutgoingReply {
                                    addr,
                                    status: 200,
                                    body: ReplyBody::Shared(arc),
                                });
                            }
                        }
                        _ => {}
                    }
                }
                if !mid_replies.is_empty() {
                    reactor::complete_batch(mid_replies);
                    err_addrs.clear();
                    for (t, &slot) in tasks.iter().zip(self.plan.iter()) {
                        let done_a1 = matches!(slot, PlanSlot::Tags | PlanSlot::User(_) | PlanSlot::Login(_));
                        let done_mid = t.viewer == 0 && matches!(slot, PlanSlot::Profile(_) | PlanSlot::Comments(_));
                        if !done_a1 && !done_mid {
                            err_addrs.push(t.addr);
                        }
                    }
                }
            }
        }

        if n_phase_b > 0 {
            conn.read_pipeline_into(n_phase_b, &mut self.pb)?;
            if let Some(failed) = self.pb.results.iter().find(|r| r.error.is_some()) {
                return Err(PgError::Wire(format!("phase B error: {}", failed.error.as_ref().unwrap())));
            }
        }

        let pa = &self.pa;
        let pb = &self.pb;
        let arena = &mut self.arena;
        let mut fav_viewer_mask = 0u64;
        let mut foll_viewer_mask = 0u64;
        let mut tag_sort_buf: Vec<&[u8]> = Vec::with_capacity(8);

        if n_phase_b > 0 {
            if let Some(s) = b_artmeta {
                for &span in pb.result_rows(s) {
                    let r = pb.row(span);
                    if let Some(&art_k) = self.distinct_arts.index.get(&pb.i64(r[0])) {
                        self.art_meta[art_k as usize] = MetaSource::PhaseB(span);
                    }
                }
            }
            if let Some(s) = b_artau {
                for &span in pb.result_rows(s) {
                    let r = pb.row(span);
                    if let Some(&au_ord) = self.distinct_authors.index.get(&pb.i64(r[0])) {
                        self.author_spans[au_ord as usize] = Some(span);
                    }
                }
            }
            if let Some(s) = b_artx {
                let n_arts = self.distinct_arts.len();
                self.art_fav_counts.clear();
                self.art_fav_counts.resize(n_arts, 0);
                self.art_tag_head.clear();
                self.art_tag_head.resize(n_arts, u32::MAX);
                self.art_tag_nodes.clear();
                for &span in pb.result_rows(s) {
                    let r = pb.row(span);
                    let kind = pb.i64(r[0]);
                    let aid = pb.i64(r[1]);
                    let val = pb.i64(r[2]);
                    if let Some(&ord) = self.distinct_arts.index.get(&aid) {
                        let k = ord as usize;
                        if kind == 0 {
                            let node_idx = self.art_tag_nodes.len() as u32;
                            self.art_tag_nodes.push((val as u32, self.art_tag_head[k]));
                            self.art_tag_head[k] = node_idx;
                        } else {
                            self.art_fav_counts[k] = val;
                        }
                    }
                }
                for k in 0..n_arts {
                    let au_ord = self.art_author_ords[k] as usize;
                    let Some(au_span) = self.author_spans.get(au_ord).copied().flatten() else {
                        continue;
                    };
                    let (slug_b, title_b, desc_b, created_at, updated_at) = match self.art_meta[k] {
                        MetaSource::PhaseA(mspan) => {
                            let mr = pa.row(mspan);
                            (
                                pa.bytes(mr[3]).unwrap_or(b""),
                                pa.bytes(mr[4]).unwrap_or(b""),
                                pa.bytes(mr[5]).unwrap_or(b""),
                                pa.i64(mr[6]),
                                pa.i64(mr[7]),
                            )
                        }
                        MetaSource::PhaseB(mspan) => {
                            let mr = pb.row(mspan);
                            (
                                pb.bytes(mr[1]).unwrap_or(b""),
                                pb.bytes(mr[2]).unwrap_or(b""),
                                pb.bytes(mr[3]).unwrap_or(b""),
                                pb.i64(mr[4]),
                                pb.i64(mr[5]),
                            )
                        }
                        MetaSource::None => continue,
                    };
                    let au = pb.row(au_span);

                    let head_start = arena.len() as u32;
                    arena.extend_from_slice(b"{\"slug\":");
                    codec::write_str(arena, slug_b);
                    arena.extend_from_slice(b",\"title\":");
                    codec::write_str(arena, title_b);
                    arena.extend_from_slice(b",\"description\":");
                    codec::write_str(arena, desc_b);
                    let head_end = arena.len() as u32;

                    arena.extend_from_slice(b",\"tagList\":[");
                    tag_sort_buf.clear();
                    let mut cur = self.art_tag_head[k];
                    while cur != u32::MAX {
                        let (tid, next) = self.art_tag_nodes[cur as usize];
                        cur = next;
                        if let Some(&name_cell) = self.tag_lut.get(tid as usize) {
                            if let Some(name_bytes) = pa.bytes(name_cell) {
                                tag_sort_buf.push(name_bytes);
                            }
                        }
                    }
                    if tag_sort_buf.len() > 1 {
                        tag_sort_buf.sort_unstable();
                    }
                    for (idx, &name_bytes) in tag_sort_buf.iter().enumerate() {
                        if idx > 0 {
                            arena.push(b',');
                        }
                        codec::write_str(arena, name_bytes);
                    }
                    arena.extend_from_slice(b"],\"createdAt\":");
                    codec::write_timestamp(arena, created_at);
                    arena.extend_from_slice(b",\"updatedAt\":");
                    codec::write_timestamp(arena, updated_at);
                    arena.extend_from_slice(b",\"favorited\":");
                    let mid_end = arena.len() as u32;

                    arena.extend_from_slice(b",\"favoritesCount\":");
                    codec::write_i64(arena, self.art_fav_counts[k]);
                    arena.extend_from_slice(b",\"author\":{\"username\":");
                    codec::write_str(arena, pb.bytes(au[1]).unwrap_or(b""));
                    arena.extend_from_slice(b",\"bio\":");
                    codec::write_nullable_str(arena, pb.bytes(au[2]));
                    arena.extend_from_slice(b",\"image\":");
                    codec::write_nullable_str(arena, pb.bytes(au[3]));
                    arena.extend_from_slice(b",\"following\":");
                    let tail_end = arena.len() as u32;

                    self.cached_arts[k] = CachedArticleSlices {
                        ready: true,
                        head_start,
                        head_end,
                        mid_end,
                        tail_end,
                    };
                }
            }
            if let Some(s) = b_flags {
                for &span in pb.result_rows(s) {
                    let r = pb.row(span);
                    let (kind, viewer_id, target_id) = (pb.i64(r[0]), pb.i64(r[1]), pb.i64(r[2]));
                    let bit = 1u64 << ((viewer_id as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 58);
                    if kind == 0 {
                        fav_viewer_mask |= bit;
                        self.fav_hits.push((viewer_id, target_id));
                    } else {
                        foll_viewer_mask |= bit;
                        self.foll_hits.push((viewer_id, target_id));
                    }
                }
                self.fav_hits.sort_unstable();
                self.foll_hits.sort_unstable();
            }
        }

        let render_ctx = RenderCtx {
            cached_arts: &self.cached_arts,
            arena,
            fav_hits: &self.fav_hits,
            foll_hits: &self.foll_hits,
            fav_viewer_mask,
            foll_viewer_mask,
        };

        self.rr.rendered_slugs.clear();
        self.rr.rendered_slugs.resize(self.k_slug.len(), None);
        self.rr.rendered_global.clear();
        self.rr.rendered_global.resize(self.rr.global_pages.len(), None);
        for i in 0..3 {
            self.rr.rendered_filters[i].clear();
            self.rr.rendered_filters[i].resize(self.rr.filter_pages[i].len(), None);
        }
        let prof_rows = &self.rr.prof_rows;
        let slug_rows = &self.rr.slug_rows;
        let aid_rows = &self.rr.aid_rows;
        let cached_cmts = &self.rr.cached_cmts;
        let rendered_profiles = &mut self.rr.rendered_profiles;
        let rendered_cmts = &mut self.rr.rendered_cmts;
        let rendered_slugs = &mut self.rr.rendered_slugs;
        let rendered_global = &mut self.rr.rendered_global;
        let rendered_filters = &mut self.rr.rendered_filters;
        let global_counts = &self.rr.global_counts;
        let global_pages = &self.rr.global_pages;
        let filter_counts = &self.rr.filter_counts;
        let filter_pages = &self.rr.filter_pages;
        let feed_counts = &self.rr.feed_counts;
        let feed_pages = &self.rr.feed_pages;
        let mut replies: Vec<OutgoingReply> = Vec::with_capacity(tasks.len());

        for (task, &slot) in tasks.drain(..).zip(self.plan.iter()) {
            let viewer = task.viewer;
            let addr = task.addr;
            match slot {
                PlanSlot::Tags | PlanSlot::User(_) | PlanSlot::Login(_) => {}
                PlanSlot::Profile(k) => {
                    if viewer == 0 {
                        continue;
                    }
                    match prof_rows.get(k as usize).copied().flatten() {
                        Some(span) => {
                            let r = pa.row(span);
                            let following = render_ctx.is_following(viewer, pa.i64(r[0]));
                            if !following {
                                if let Some(shared) = &rendered_profiles[k as usize] {
                                    replies.push(OutgoingReply {
                                        addr,
                                        status: 200,
                                        body: ReplyBody::Shared(shared.clone()),
                                    });
                                    continue;
                                }
                            }
                            let mut body = Vec::with_capacity(256);
                            body.extend_from_slice(b"{\"profile\":");
                            write_profile_json(
                                &mut body,
                                pa.bytes(r[1]).unwrap_or(b""),
                                pa.bytes(r[2]),
                                pa.bytes(r[3]),
                                following,
                            );
                            body.push(b'}');
                            let reply_body = if !following {
                                let arc: Arc<[u8]> = body.into();
                                rendered_profiles[k as usize] = Some(arc.clone());
                                ReplyBody::Shared(arc)
                            } else {
                                ReplyBody::Owned(body)
                            };
                            replies.push(OutgoingReply {
                                addr,
                                status: 200,
                                body: reply_body,
                            });
                        }
                        None => replies.push(reactor::error_reply(addr, 404, "profile not found")),
                    }
                }
                PlanSlot::BySlug(k) => {
                    let Some(art) = slug_rows[k as usize] else {
                        replies.push(reactor::error_reply(addr, 404, "article not found"));
                        continue;
                    };
                    let unflagged = render_ctx.is_article_unflagged(art, viewer);
                    if unflagged {
                        if let Some(shared) = &rendered_slugs[k as usize] {
                            replies.push(OutgoingReply {
                                addr,
                                status: 200,
                                body: ReplyBody::Shared(shared.clone()),
                            });
                            continue;
                        }
                    }
                    let mut body = Vec::with_capacity(2048);
                    body.extend_from_slice(b"{\"article\":");
                    if render_ctx.write_article(&mut body, pa, art, true, viewer, false, None) {
                        body.push(b'}');
                        let reply_body = if unflagged {
                            let arc: Arc<[u8]> = body.into();
                            rendered_slugs[k as usize] = Some(arc.clone());
                            ReplyBody::Shared(arc)
                        } else {
                            ReplyBody::Owned(body)
                        };
                        replies.push(OutgoingReply {
                            addr,
                            status: 200,
                            body: reply_body,
                        });
                    } else {
                        replies.push(reactor::error_reply(addr, 404, "article not found"));
                    }
                }
                PlanSlot::ById(k, known_fav) => {
                    let Some(art) = aid_rows[k as usize] else {
                        replies.push(reactor::error_reply(addr, 404, "article not found"));
                        continue;
                    };
                    let mut body = Vec::with_capacity(2048);
                    body.extend_from_slice(b"{\"article\":");
                    if render_ctx.write_article(&mut body, pa, art, true, viewer, false, known_fav) {
                        body.push(b'}');
                        replies.push(OutgoingReply {
                            addr,
                            status: 200,
                            body: ReplyBody::Owned(body),
                        });
                    } else {
                        replies.push(reactor::error_reply(addr, 404, "article not found"));
                    }
                }
                PlanSlot::Comments(k) => {
                    if viewer == 0 {
                        continue;
                    }
                    let Some(list) = &cached_cmts[k as usize] else {
                        replies.push(reactor::error_reply(addr, 404, "article not found"));
                        continue;
                    };
                    let unflagged = list.iter().all(|c| !render_ctx.is_following(viewer, c.author_id));
                    if unflagged {
                        if let Some(shared) = &rendered_cmts[k as usize] {
                            replies.push(OutgoingReply {
                                addr,
                                status: 200,
                                body: ReplyBody::Shared(shared.clone()),
                            });
                            continue;
                        }
                    }
                    let mut body = Vec::with_capacity(64 + 320 * list.len());
                    body.extend_from_slice(b"{\"comments\":[");
                    for (idx, c) in list.iter().enumerate() {
                        if idx > 0 {
                            body.push(b',');
                        }
                        body.extend_from_slice(&render_ctx.arena[c.start as usize..c.end as usize]);
                        let foll = !unflagged && render_ctx.is_following(viewer, c.author_id);
                        body.extend_from_slice(if foll { b"true}}" } else { b"false}}" });
                    }
                    body.extend_from_slice(b"]}");
                    let reply_body = if unflagged {
                        let arc: Arc<[u8]> = body.into();
                        rendered_cmts[k as usize] = Some(arc.clone());
                        ReplyBody::Shared(arc)
                    } else {
                        ReplyBody::Owned(body)
                    };
                    replies.push(OutgoingReply {
                        addr,
                        status: 200,
                        body: reply_body,
                    });
                }
                PlanSlot::Global(_) | PlanSlot::Filtered(..) | PlanSlot::Feed(..) => {
                    let (rows, total_count, is_feed): (&ArticlePage, i64, bool) = match slot {
                        PlanSlot::Global(p) => (&global_pages[p as usize], global_counts[0], false),
                        PlanSlot::Filtered(kind, c, p) => (
                            &filter_pages[kind][p as usize],
                            filter_counts[kind][c as usize],
                            false,
                        ),
                        PlanSlot::Feed(c, p) => (&feed_pages[p as usize], feed_counts[c as usize], true),
                        _ => unreachable!(),
                    };
                    let unflagged = !is_feed
                        && (viewer == 0 || rows.iter().all(|&art| render_ctx.is_article_unflagged(art, viewer)));
                    if unflagged {
                        let cached = match slot {
                            PlanSlot::Global(p) => &rendered_global[p as usize],
                            PlanSlot::Filtered(kind, _, p) => &rendered_filters[kind][p as usize],
                            _ => &None,
                        };
                        if let Some(shared) = cached {
                            replies.push(OutgoingReply {
                                addr,
                                status: 200,
                                body: ReplyBody::Shared(shared.clone()),
                            });
                            continue;
                        }
                    }
                    let mut body = Vec::with_capacity(512 + 700 * rows.len());
                    body.extend_from_slice(b"{\"articles\":[");
                    let mut first = true;
                    for &art in rows {
                        let mark = body.len();
                        if !first {
                            body.push(b',');
                        }
                        if render_ctx.write_article(
                            &mut body,
                            pa,
                            art,
                            false,
                            if unflagged { 0 } else { viewer },
                            is_feed,
                            None,
                        ) {
                            first = false;
                        } else {
                            body.truncate(mark);
                        }
                    }
                    body.extend_from_slice(b"],\"articlesCount\":");
                    codec::write_i64(&mut body, total_count);
                    body.push(b'}');
                    let reply_body = if unflagged {
                        let arc: Arc<[u8]> = body.into();
                        match slot {
                            PlanSlot::Global(p) => rendered_global[p as usize] = Some(arc.clone()),
                            PlanSlot::Filtered(kind, _, p) => rendered_filters[kind][p as usize] = Some(arc.clone()),
                            _ => {}
                        }
                        ReplyBody::Shared(arc)
                    } else {
                        ReplyBody::Owned(body)
                    };
                    replies.push(OutgoingReply {
                        addr,
                        status: 200,
                        body: reply_body,
                    });
                }
            }
        }

        if !replies.is_empty() {
            reactor::complete_batch(replies);
        }
        Ok(())
    }
}

struct RenderCtx<'a> {
    cached_arts: &'a [CachedArticleSlices],
    arena: &'a [u8],
    fav_hits: &'a [(i64, i64)],
    foll_hits: &'a [(i64, i64)],
    fav_viewer_mask: u64,
    foll_viewer_mask: u64,
}

#[inline(always)]
fn viewer_bit(viewer: i64) -> u64 {
    1u64 << ((viewer as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) >> 58)
}

impl RenderCtx<'_> {
    #[inline]
    fn is_following(&self, viewer: i64, author: i64) -> bool {
        (self.foll_viewer_mask & viewer_bit(viewer)) != 0
            && self.foll_hits.binary_search(&(viewer, author)).is_ok()
    }

    #[inline]
    fn is_favorited(&self, viewer: i64, article: i64) -> bool {
        (self.fav_viewer_mask & viewer_bit(viewer)) != 0
            && self.fav_hits.binary_search(&(viewer, article)).is_ok()
    }

    #[inline]
    fn is_article_unflagged(&self, art: ArticleRef, viewer: i64) -> bool {
        viewer == 0 || (!self.is_favorited(viewer, art.aid) && !self.is_following(viewer, art.author))
    }

    #[inline]
    #[allow(clippy::too_many_arguments)]
    fn write_article(
        &self,
        dst: &mut Vec<u8>,
        pa: &PipelineBuf,
        art: ArticleRef,
        include_body: bool,
        viewer: i64,
        known_following: bool,
        known_fav: Option<bool>,
    ) -> bool {
        let Some(slices) = self.cached_arts.get(art.art_ord as usize) else {
            return false;
        };
        if !slices.ready {
            return false;
        };
        let fav = known_fav.unwrap_or_else(|| viewer != 0 && self.is_favorited(viewer, art.aid));
        let foll = known_following || (viewer != 0 && self.is_following(viewer, art.author));
        if !include_body {
            dst.extend_from_slice(&self.arena[slices.head_start as usize..slices.mid_end as usize]);
            dst.extend_from_slice(if fav { b"true" } else { b"false" });
            dst.extend_from_slice(&self.arena[slices.mid_end as usize..slices.tail_end as usize]);
            dst.extend_from_slice(if foll { b"true}}" } else { b"false}}" });
        } else {
            let ar = pa.row(art.row);
            dst.extend_from_slice(&self.arena[slices.head_start as usize..slices.head_end as usize]);
            dst.extend_from_slice(b",\"body\":");
            codec::write_str(dst, pa.bytes(ar[8]).unwrap_or(b""));
            dst.extend_from_slice(&self.arena[slices.head_end as usize..slices.mid_end as usize]);
            dst.extend_from_slice(if fav { b"true" } else { b"false" });
            dst.extend_from_slice(&self.arena[slices.mid_end as usize..slices.tail_end as usize]);
            dst.extend_from_slice(if foll { b"true}}" } else { b"false}}" });
        }
        true
    }
}

pub struct WriteWorker {
    conn: Option<PgConn>,
    cfg: &'static RuntimeConfig,
    pipe: PipelineBuf,
    enc_i64: ArrayEncoder,
    enc_txt1: ArrayEncoder,
    enc_txt2: ArrayEncoder,
}

fn stmt_count_for_write(task: &WriteTask) -> usize {
    match &task.op {
        WriteOp::CreateArticle { tags, .. } if !tags.is_empty() => 3,
        _ => 1,
    }
}

fn slugify_ascii(title: &str) -> String {
    let mut out = Vec::with_capacity(title.len());
    let mut pending_dash = false;
    for &b in title.as_bytes() {
        match b {
            b'A'..=b'Z' => {
                if pending_dash && !out.is_empty() {
                    out.push(b'-');
                }
                pending_dash = false;
                out.push(b + 32);
            }
            b'a'..=b'z' | b'0'..=b'9' => {
                if pending_dash && !out.is_empty() {
                    out.push(b'-');
                }
                pending_dash = false;
                out.push(b);
            }
            _ => {
                pending_dash = true;
            }
        }
    }
    // out only contains ASCII lowercase letters, digits, and '-'.
    unsafe { String::from_utf8_unchecked(out) }
}

fn opt_str_param(opt: &Option<String>) -> BindParam<'_> {
    match opt {
        Some(s) => BindParam::Text(s.as_bytes()),
        None => BindParam::Null,
    }
}

fn bind_single_write(tx: &mut wire::TxBuf, task: &WriteTask) {
    let v = task.viewer;
    match &task.op {
        WriteOp::Register { username, email, hash } => tx.bind_and_exec(
            "register",
            &[
                BindParam::Text(username.as_bytes()),
                BindParam::Text(email.as_bytes()),
                BindParam::Text(hash.as_bytes()),
            ],
        ),
        WriteOp::UpdateUser {
            email,
            username,
            hash,
            bio,
            image,
            ..
        } => tx.bind_and_exec(
            "upduser",
            &[
                BindParam::I64(v),
                opt_str_param(email),
                opt_str_param(username),
                opt_str_param(hash),
                opt_str_param(bio),
                opt_str_param(image),
            ],
        ),
        WriteOp::Follow { username, on } => tx.bind_and_exec(
            if *on { "follow" } else { "unfollow" },
            &[BindParam::I64(v), BindParam::Text(username.as_bytes())],
        ),
        WriteOp::Favorite { slug, on } => tx.bind_and_exec(
            if *on { "fav" } else { "unfav" },
            &[BindParam::I64(v), BindParam::Text(slug.as_bytes())],
        ),
        WriteOp::CreateArticle {
            title,
            description,
            body,
            tags,
        } => {
            let slug_prefix = slugify_ascii(title);
            tx.bind_and_exec(
                "newart",
                &[
                    BindParam::I64(v),
                    BindParam::Text(title.as_bytes()),
                    BindParam::Text(description.as_bytes()),
                    BindParam::Text(body.as_bytes()),
                    BindParam::Text(slug_prefix.as_bytes()),
                ],
            );
            if !tags.is_empty() {
                tx.bind_and_exec("newtags", &[BindParam::TextSlice(tags)]);
                tx.bind_and_exec("arttags", &[BindParam::TextSlice(tags)]);
            }
        }
        WriteOp::UpdateArticle {
            slug,
            title,
            description,
            body,
        } => {
            let slug_prefix = title.as_deref().map(slugify_ascii);
            tx.bind_and_exec(
                "updart",
                &[
                    BindParam::Text(slug.as_bytes()),
                    opt_str_param(title),
                    opt_str_param(description),
                    opt_str_param(body),
                    BindParam::I64(v),
                    opt_str_param(&slug_prefix),
                ],
            )
        }
        WriteOp::DeleteArticle { slug } => {
            tx.bind_and_exec("delart", &[BindParam::Text(slug.as_bytes()), BindParam::I64(v)])
        }
        WriteOp::CreateComment { slug, body } => tx.bind_and_exec(
            "newcmt",
            &[
                BindParam::Text(slug.as_bytes()),
                BindParam::I64(v),
                BindParam::Text(body.as_bytes()),
            ],
        ),
        WriteOp::DeleteComment { slug, id } => tx.bind_and_exec(
            "delcmt",
            &[
                BindParam::I64(*id),
                BindParam::Text(slug.as_bytes()),
                BindParam::I64(v),
            ],
        ),
    }
}

#[derive(Clone, Copy)]
enum WriteDispatchLoc {
    Direct { start: usize, count: usize },
    BatchedFav { on: bool, ord: usize },
    BatchedFollow { on: bool, ord: usize },
    BatchedComment { ord: usize },
}

impl WriteWorker {
    pub fn new(cfg: &'static RuntimeConfig) -> Self {
        WriteWorker {
            conn: None,
            cfg,
            pipe: PipelineBuf::with_capacity(),
            enc_i64: ArrayEncoder::with_capacity(OID_INT8, 64),
            enc_txt1: ArrayEncoder::with_capacity(OID_TEXT, 64),
            enc_txt2: ArrayEncoder::with_capacity(OID_TEXT, 64),
        }
    }

    fn ensure_conn<'a>(conn_slot: &'a mut Option<PgConn>, cfg: &RuntimeConfig) -> PgResult<&'a mut PgConn> {
        if conn_slot.is_none() {
            let mut c = PgConn::connect(&cfg.db)?;
            let defs = queries::write_catalog();
            let refs: Vec<(&str, &str, &[u32])> = defs.iter().map(|d| (d.name, d.sql.as_str(), d.oids)).collect();
            c.prepare_batch(&refs)?;
            *conn_slot = Some(c);
        }
        Ok(conn_slot.as_mut().unwrap())
    }

    pub fn run_loop(mut self) {
        let mut tasks = Vec::new();
        let num_families = queries::read_catalog().len();
        let rw = self.cfg.read_workers.max(2);
        let max_cap = num_families * rw * 2;
        loop {
            tasks.clear();
            WRITE_QUEUE.drain_up_to(max_cap, &mut tasks);
            if let Err((err, pending_addrs)) = self.commit_group(&mut tasks) {
                eprintln!("write group error: {err}");
                self.conn = None;
                reactor::complete_batch(
                    pending_addrs
                        .into_iter()
                        .map(|a| reactor::error_reply(a, 500, "internal server error"))
                        .collect(),
                );
            }
        }
    }

    fn commit_group(&mut self, tasks: &mut Vec<WriteTask>) -> Result<(), (PgError, Vec<ReplyAddr>)> {
        tasks.retain(|t| reactor::is_addr_alive(t.addr));
        if tasks.is_empty() {
            return Ok(());
        }
        let all_addrs: Vec<ReplyAddr> = tasks.iter().map(|t| t.addr).collect();
        let conn = match Self::ensure_conn(&mut self.conn, self.cfg) {
            Ok(c) => c,
            Err(e) => return Err((e, all_addrs)),
        };

        let is_single_task = tasks.len() == 1;
        let has_slug_mutation = !is_single_task
            && tasks.iter().any(|t| {
                matches!(
                    t.op,
                    WriteOp::CreateArticle { .. }
                        | WriteOp::UpdateArticle { .. }
                        | WriteOp::DeleteArticle { .. }
                        | WriteOp::UpdateUser { .. }
                )
            });

        let mut fav_on_jobs: Vec<(i64, &str)> = Vec::new();
        let mut fav_off_jobs: Vec<(i64, &str)> = Vec::new();
        let mut foll_on_jobs: Vec<(i64, &str)> = Vec::new();
        let mut foll_off_jobs: Vec<(i64, &str)> = Vec::new();
        let mut cmt_jobs: Vec<(i64, &str, &str)> = Vec::new();

        if !is_single_task && !has_slug_mutation {
            for t in tasks.iter() {
                match &t.op {
                    WriteOp::Favorite { slug, on: true } => fav_on_jobs.push((t.viewer, slug.as_str())),
                    WriteOp::Favorite { slug, on: false } => fav_off_jobs.push((t.viewer, slug.as_str())),
                    WriteOp::Follow { username, on: true } => foll_on_jobs.push((t.viewer, username.as_str())),
                    WriteOp::Follow { username, on: false } => foll_off_jobs.push((t.viewer, username.as_str())),
                    WriteOp::CreateComment { slug, body } => cmt_jobs.push((t.viewer, slug.as_str(), body.as_str())),
                    _ => {}
                }
            }
        }

        let fav_conflict = fav_on_jobs
            .iter()
            .any(|(_, s1)| fav_off_jobs.iter().any(|(_, s2)| s1 == s2));
        let foll_conflict = foll_on_jobs
            .iter()
            .any(|(_, u1)| foll_off_jobs.iter().any(|(_, u2)| u1 == u2));

        let batch_fav_on = !fav_conflict && fav_on_jobs.len() >= 2;
        let batch_fav_off = !fav_conflict && fav_off_jobs.len() >= 2;
        let batch_foll_on = !foll_conflict && foll_on_jobs.len() >= 2;
        let batch_foll_off = !foll_conflict && foll_off_jobs.len() >= 2;
        let batch_cmt = cmt_jobs.len() >= 2;

        let mut n_exec = 0usize;

        let slot_foll_on = if batch_foll_on {
            let s = n_exec;
            n_exec += 1;
            self.enc_i64.reset(OID_INT8, foll_on_jobs.len());
            self.enc_txt1.reset(OID_TEXT, foll_on_jobs.len());
            for &(v, u) in &foll_on_jobs {
                self.enc_i64.push_i64(v);
                self.enc_txt1.push_bytes(u.as_bytes());
            }
            conn.tx.bind_and_exec(
                "follow_batch",
                &[
                    BindParam::Raw(self.enc_i64.finish()),
                    BindParam::Raw(self.enc_txt1.finish()),
                ],
            );
            Some(s)
        } else {
            None
        };

        let slot_foll_off = if batch_foll_off {
            let s = n_exec;
            n_exec += 1;
            self.enc_i64.reset(OID_INT8, foll_off_jobs.len());
            self.enc_txt1.reset(OID_TEXT, foll_off_jobs.len());
            for &(v, u) in &foll_off_jobs {
                self.enc_i64.push_i64(v);
                self.enc_txt1.push_bytes(u.as_bytes());
            }
            conn.tx.bind_and_exec(
                "unfollow_batch",
                &[
                    BindParam::Raw(self.enc_i64.finish()),
                    BindParam::Raw(self.enc_txt1.finish()),
                ],
            );
            Some(s)
        } else {
            None
        };

        let slot_fav_on = if batch_fav_on {
            let s = n_exec;
            n_exec += 1;
            self.enc_i64.reset(OID_INT8, fav_on_jobs.len());
            self.enc_txt1.reset(OID_TEXT, fav_on_jobs.len());
            for &(v, sl) in &fav_on_jobs {
                self.enc_i64.push_i64(v);
                self.enc_txt1.push_bytes(sl.as_bytes());
            }
            conn.tx.bind_and_exec(
                "fav_batch",
                &[
                    BindParam::Raw(self.enc_i64.finish()),
                    BindParam::Raw(self.enc_txt1.finish()),
                ],
            );
            Some(s)
        } else {
            None
        };

        let slot_fav_off = if batch_fav_off {
            let s = n_exec;
            n_exec += 1;
            self.enc_i64.reset(OID_INT8, fav_off_jobs.len());
            self.enc_txt1.reset(OID_TEXT, fav_off_jobs.len());
            for &(v, sl) in &fav_off_jobs {
                self.enc_i64.push_i64(v);
                self.enc_txt1.push_bytes(sl.as_bytes());
            }
            conn.tx.bind_and_exec(
                "unfav_batch",
                &[
                    BindParam::Raw(self.enc_i64.finish()),
                    BindParam::Raw(self.enc_txt1.finish()),
                ],
            );
            Some(s)
        } else {
            None
        };

        let slot_cmt = if batch_cmt {
            let s = n_exec;
            n_exec += 1;
            self.enc_i64.reset(OID_INT8, cmt_jobs.len());
            self.enc_txt1.reset(OID_TEXT, cmt_jobs.len());
            self.enc_txt2.reset(OID_TEXT, cmt_jobs.len());
            for &(v, sl, bd) in &cmt_jobs {
                self.enc_i64.push_i64(v);
                self.enc_txt1.push_bytes(sl.as_bytes());
                self.enc_txt2.push_bytes(bd.as_bytes());
            }
            conn.tx.bind_and_exec(
                "newcmt_batch",
                &[
                    BindParam::Raw(self.enc_i64.finish()),
                    BindParam::Raw(self.enc_txt1.finish()),
                    BindParam::Raw(self.enc_txt2.finish()),
                ],
            );
            Some(s)
        } else {
            None
        };

        let (mut c_fav_on, mut c_fav_off, mut c_foll_on, mut c_foll_off, mut c_cmt) =
            (0usize, 0usize, 0usize, 0usize, 0usize);
        let mut locs = Vec::with_capacity(tasks.len());
        for t in tasks.iter() {
            match &t.op {
                WriteOp::Favorite { on: true, .. } if batch_fav_on => {
                    c_fav_on += 1;
                    locs.push(WriteDispatchLoc::BatchedFav { on: true, ord: c_fav_on });
                }
                WriteOp::Favorite { on: false, .. } if batch_fav_off => {
                    c_fav_off += 1;
                    locs.push(WriteDispatchLoc::BatchedFav {
                        on: false,
                        ord: c_fav_off,
                    });
                }
                WriteOp::Follow { on: true, .. } if batch_foll_on => {
                    c_foll_on += 1;
                    locs.push(WriteDispatchLoc::BatchedFollow {
                        on: true,
                        ord: c_foll_on,
                    });
                }
                WriteOp::Follow { on: false, .. } if batch_foll_off => {
                    c_foll_off += 1;
                    locs.push(WriteDispatchLoc::BatchedFollow {
                        on: false,
                        ord: c_foll_off,
                    });
                }
                WriteOp::CreateComment { .. } if batch_cmt => {
                    c_cmt += 1;
                    locs.push(WriteDispatchLoc::BatchedComment { ord: c_cmt });
                }
                _ => {
                    let cnt = stmt_count_for_write(t);
                    locs.push(WriteDispatchLoc::Direct {
                        start: n_exec,
                        count: cnt,
                    });
                    bind_single_write(&mut conn.tx, t);
                    n_exec += cnt;
                }
            }
        }

        conn.tx.write_sync();

        if let Err(e) = conn.flush().and_then(|_| conn.read_pipeline_into(n_exec, &mut self.pipe)) {
            return Err((e, all_addrs));
        }

        let any_failed = self.pipe.results.iter().any(|r| r.error.is_some());
        if any_failed && !is_single_task {
            for t in tasks.drain(..) {
                let addr = t.addr;
                if let Err(e) = self.exec_individual(t) {
                    return Err((e, vec![addr]));
                }
            }
            return Ok(());
        }

        let pipe = &self.pipe;
        let decode_ord_rows = |slot: Option<usize>, len: usize| -> Vec<Option<&[Cell]>> {
            let mut out = vec![None; len];
            if let Some(s) = slot {
                for &span in pipe.result_rows(s) {
                    let r = pipe.row(span);
                    let k = pipe.i64(r[0]);
                    if k >= 1 && (k as usize) <= len {
                        out[k as usize - 1] = Some(r);
                    }
                }
            }
            out
        };
        let fav_on_res = decode_ord_rows(slot_fav_on, c_fav_on);
        let fav_off_res = decode_ord_rows(slot_fav_off, c_fav_off);
        let foll_on_res = decode_ord_rows(slot_foll_on, c_foll_on);
        let foll_off_res = decode_ord_rows(slot_foll_off, c_foll_off);
        let cmt_res = decode_ord_rows(slot_cmt, c_cmt);

        let mut replies = Vec::with_capacity(tasks.len());
        let mut post_reads: Vec<ReadTask> = Vec::new();
        for (task, loc) in tasks.drain(..).zip(locs) {
            match loc {
                WriteDispatchLoc::Direct { start, count } => {
                    finalize_write_task(task, pipe, start, count, self.cfg, &mut replies, &mut post_reads);
                }
                WriteDispatchLoc::BatchedFav { on, ord } => {
                    let row = if on {
                        fav_on_res[ord - 1]
                    } else {
                        fav_off_res[ord - 1]
                    };
                    match row {
                        Some(r) => {
                            post_reads.push(ReadTask {
                                op: ReadOp::ArticleById {
                                    id: pipe.i64(r[1]),
                                    known_fav: Some(on),
                                },
                                viewer: task.viewer,
                                addr: task.addr,
                            });
                        }
                        None => replies.push(reactor::error_reply(task.addr, 404, "article not found")),
                    }
                }
                WriteDispatchLoc::BatchedFollow { on, ord } => {
                    let row = if on {
                        foll_on_res[ord - 1]
                    } else {
                        foll_off_res[ord - 1]
                    };
                    match row {
                        Some(r) => {
                            let mut body = Vec::with_capacity(256);
                            body.extend_from_slice(b"{\"profile\":");
                            write_profile_json(
                                &mut body,
                                pipe.bytes(r[1]).unwrap_or(b""),
                                pipe.bytes(r[2]),
                                pipe.bytes(r[3]),
                                on,
                            );
                            body.push(b'}');
                            replies.push(OutgoingReply {
                                addr: task.addr,
                                status: 200,
                                body: ReplyBody::Owned(body),
                            });
                        }
                        None => replies.push(reactor::error_reply(task.addr, 404, "profile not found")),
                    }
                }
                WriteDispatchLoc::BatchedComment { ord } => match cmt_res[ord - 1] {
                    Some(r) => {
                        let mut body = Vec::with_capacity(512);
                        body.extend_from_slice(b"{\"comment\":{\"id\":");
                        codec::write_i64(&mut body, pipe.i64(r[1]));
                        body.extend_from_slice(b",\"createdAt\":");
                        codec::write_timestamp(&mut body, pipe.i64(r[3]));
                        body.extend_from_slice(b",\"updatedAt\":");
                        codec::write_timestamp(&mut body, pipe.i64(r[4]));
                        body.extend_from_slice(b",\"body\":");
                        codec::write_str(&mut body, pipe.bytes(r[2]).unwrap_or(b""));
                        body.extend_from_slice(b",\"author\":");
                        write_profile_json(
                            &mut body,
                            pipe.bytes(r[5]).unwrap_or(b""),
                            pipe.bytes(r[6]),
                            pipe.bytes(r[7]),
                            false,
                        );
                        body.extend_from_slice(b"}}");
                        replies.push(OutgoingReply {
                            addr: task.addr,
                            status: 201,
                            body: ReplyBody::Owned(body),
                        });
                    }
                    None => replies.push(reactor::error_reply(task.addr, 404, "article not found")),
                },
            }
        }

        if !post_reads.is_empty() {
            READ_QUEUE.push_batch(&mut post_reads);
        }
        reactor::complete_batch(replies);
        Ok(())
    }

    fn exec_individual(&mut self, task: WriteTask) -> PgResult<()> {
        let conn = Self::ensure_conn(&mut self.conn, self.cfg)?;
        let cnt = stmt_count_for_write(&task);
        bind_single_write(&mut conn.tx, &task);
        conn.tx.write_sync();
        conn.flush()?;
        conn.read_pipeline_into(cnt, &mut self.pipe)?;
        let mut replies = Vec::new();
        let mut post_reads = Vec::new();
        finalize_write_task(task, &self.pipe, 0, cnt, self.cfg, &mut replies, &mut post_reads);
        if !post_reads.is_empty() {
            READ_QUEUE.push_batch(&mut post_reads);
        }
        reactor::complete_batch(replies);
        Ok(())
    }
}

fn finalize_write_task(
    task: WriteTask,
    pipe: &PipelineBuf,
    start: usize,
    count: usize,
    cfg: &RuntimeConfig,
    replies: &mut Vec<OutgoingReply>,
    post_reads: &mut Vec<ReadTask>,
) {
    let addr = task.addr;
    let viewer = task.viewer;
    let slice = &pipe.results[start..start + count];
    if let Some(err) = slice.iter().find_map(|r| r.error.as_ref()) {
        if err.code == "23505" {
            replies.push(reactor::error_reply(addr, 422, "duplicate username or email"));
        } else {
            eprintln!("write statement error: {err}");
            replies.push(reactor::error_reply(addr, 500, "internal server error"));
        }
        return;
    }

    let first_row = pipe.result_rows(start).first().map(|&span| pipe.row(span));
    match task.op {
        WriteOp::Register { .. } => match first_row {
            Some(r) => {
                let tok = cfg.signer.issue(pipe.i64(r[0]));
                let mut body = Vec::with_capacity(512);
                write_user_envelope(
                    &mut body,
                    pipe.bytes(r[2]).unwrap_or(b""),
                    tok.as_bytes(),
                    pipe.bytes(r[1]).unwrap_or(b""),
                    pipe.bytes(r[3]),
                    pipe.bytes(r[4]),
                );
                replies.push(OutgoingReply {
                    addr,
                    status: 201,
                    body: ReplyBody::Owned(body),
                });
            }
            None => replies.push(reactor::error_reply(addr, 422, "duplicate username or email")),
        },
        WriteOp::UpdateUser { token, .. } => match first_row {
            Some(r) => {
                let mut body = Vec::with_capacity(512);
                write_user_envelope(
                    &mut body,
                    pipe.bytes(r[2]).unwrap_or(b""),
                    token.as_bytes(),
                    pipe.bytes(r[1]).unwrap_or(b""),
                    pipe.bytes(r[3]),
                    pipe.bytes(r[4]),
                );
                replies.push(OutgoingReply {
                    addr,
                    status: 200,
                    body: ReplyBody::Owned(body),
                });
            }
            None => replies.push(reactor::error_reply(addr, 401, "unauthorized")),
        },
        WriteOp::Follow { on, .. } => match first_row {
            Some(r) => {
                let mut body = Vec::with_capacity(256);
                body.extend_from_slice(b"{\"profile\":");
                write_profile_json(
                    &mut body,
                    pipe.bytes(r[0]).unwrap_or(b""),
                    pipe.bytes(r[1]),
                    pipe.bytes(r[2]),
                    on,
                );
                body.push(b'}');
                replies.push(OutgoingReply {
                    addr,
                    status: 200,
                    body: ReplyBody::Owned(body),
                });
            }
            None => replies.push(reactor::error_reply(addr, 404, "profile not found")),
        },
        WriteOp::Favorite { on, .. } => match first_row {
            Some(r) => {
                post_reads.push(ReadTask {
                    op: ReadOp::ArticleById {
                        id: pipe.i64(r[0]),
                        known_fav: Some(on),
                    },
                    viewer,
                    addr,
                });
            }
            None => replies.push(reactor::error_reply(addr, 404, "article not found")),
        },
        WriteOp::CreateArticle {
            title,
            description,
            body: art_body,
            tags,
        } => match first_row {
            Some(r) => {
                let mut local_tags: Vec<&[u8]> = tags.iter().map(|s| s.as_bytes()).collect();
                if local_tags.len() > 1 {
                    local_tags.sort_unstable();
                    local_tags.dedup();
                }
                let mut body = Vec::with_capacity(2048);
                write_full_article_envelope(
                    &mut body,
                    pipe.bytes(r[0]).unwrap_or(b""),
                    title.as_bytes(),
                    description.as_bytes(),
                    art_body.as_bytes(),
                    &local_tags,
                    pipe.i64(r[1]),
                    pipe.i64(r[2]),
                    false,
                    0,
                    pipe.bytes(r[3]).unwrap_or(b""),
                    pipe.bytes(r[4]),
                    pipe.bytes(r[5]),
                    pipe.bool(r[6]),
                );
                replies.push(OutgoingReply {
                    addr,
                    status: 201,
                    body: ReplyBody::Owned(body),
                });
            }
            None => replies.push(reactor::error_reply(addr, 500, "internal server error")),
        },
        WriteOp::UpdateArticle { .. } => match first_row {
            Some(r) if pipe.i64(r[1]) != viewer => replies.push(reactor::error_reply(addr, 403, "forbidden")),
            Some(r) => {
                post_reads.push(ReadTask {
                    op: ReadOp::ArticleById {
                        id: pipe.i64(r[0]),
                        known_fav: None,
                    },
                    viewer,
                    addr,
                });
            }
            None => replies.push(reactor::error_reply(addr, 404, "article not found")),
        },
        WriteOp::DeleteArticle { .. } => match first_row {
            Some(r) if pipe.i64(r[0]) != viewer => replies.push(reactor::error_reply(addr, 403, "forbidden")),
            Some(_) => replies.push(OutgoingReply {
                addr,
                status: 204,
                body: ReplyBody::Empty,
            }),
            None => replies.push(reactor::error_reply(addr, 404, "article not found")),
        },
        WriteOp::CreateComment { .. } => match first_row {
            Some(r) => {
                let mut body = Vec::with_capacity(512);
                body.extend_from_slice(b"{\"comment\":{\"id\":");
                codec::write_i64(&mut body, pipe.i64(r[0]));
                body.extend_from_slice(b",\"createdAt\":");
                codec::write_timestamp(&mut body, pipe.i64(r[2]));
                body.extend_from_slice(b",\"updatedAt\":");
                codec::write_timestamp(&mut body, pipe.i64(r[3]));
                body.extend_from_slice(b",\"body\":");
                codec::write_str(&mut body, pipe.bytes(r[1]).unwrap_or(b""));
                body.extend_from_slice(b",\"author\":");
                write_profile_json(
                    &mut body,
                    pipe.bytes(r[4]).unwrap_or(b""),
                    pipe.bytes(r[5]),
                    pipe.bytes(r[6]),
                    false,
                );
                body.extend_from_slice(b"}}");
                replies.push(OutgoingReply {
                    addr,
                    status: 201,
                    body: ReplyBody::Owned(body),
                });
            }
            None => replies.push(reactor::error_reply(addr, 404, "article not found")),
        },
        WriteOp::DeleteComment { .. } => match first_row {
            Some(r) if pipe.i64(r[0]) != viewer => replies.push(reactor::error_reply(addr, 403, "forbidden")),
            Some(_) => replies.push(OutgoingReply {
                addr,
                status: 204,
                body: ReplyBody::Empty,
            }),
            None => replies.push(reactor::error_reply(addr, 404, "comment not found")),
        },
    }
}

pub fn run_crypto_worker(cfg: &'static RuntimeConfig) {
    let mut batch: Vec<CryptoTask> = Vec::with_capacity(cfg.bcrypt_lanes.max(1));
    let mut non_std: Vec<CryptoTask> = Vec::new();
    let lanes = cfg.bcrypt_lanes.max(1);
    loop {
        batch.clear();
        {
            let _token = CRYPTO_LOCK.lock().unwrap();
            let busy = BUSY_CRYPTO_WORKERS.load(Ordering::Acquire);
            let tau_us = EWMA_BCRYPT_US.load(Ordering::Relaxed);
            let ewma_c = EWMA_CRYPTO_LEN.load(Ordering::Relaxed);
            let age_us = if busy == 0 && ewma_c <= 1 {
                (tau_us / (lanes * 2)).max(1)
            } else {
                tau_us.saturating_mul(2).max(1)
            };
            CRYPTO_QUEUE.take_aged(lanes, Duration::from_micros(age_us as u64), lanes, &mut batch);
            BUSY_CRYPTO_WORKERS.fetch_add(1, Ordering::AcqRel);
        }
        let batch_n = batch.len();
        let prev_c = EWMA_CRYPTO_LEN.load(Ordering::Relaxed);
        let next_c = if prev_c == 0 {
            batch_n
        } else {
            (prev_c * 3 + batch_n) / 4
        };
        EWMA_CRYPTO_LEN.store(next_c, Ordering::Relaxed);
        batch.retain(|t| match t {
            CryptoTask::VerifyLogin { addr, .. } => reactor::is_addr_alive(*addr),
            CryptoTask::HashPassword { write, .. } => reactor::is_addr_alive(write.addr),
        });
        let t0 = Instant::now();
        non_std.clear();
        let mut i = 0;
        while i < batch.len() {
            let cost = match &batch[i] {
                CryptoTask::VerifyLogin { hash, .. } => auth::parse_bcrypt(hash).map(|p| p.cost),
                CryptoTask::HashPassword { .. } => Some(10),
            };
            if cost != Some(10) {
                non_std.push(batch.swap_remove(i));
            } else {
                i += 1;
            }
        }
        let had_std = !batch.is_empty();
        execute_bcrypt_batch(&mut batch, cfg, 10);
        if had_std {
            let elapsed_us = t0.elapsed().as_micros() as usize;
            let prev = EWMA_BCRYPT_US.load(Ordering::Relaxed);
            let next = if prev == 0 {
                elapsed_us
            } else {
                (prev * 3 + elapsed_us) / 4
            }
            .clamp(1_000, 150_000);
            EWMA_BCRYPT_US.store(next, Ordering::Relaxed);
        }
        let mut single: Vec<CryptoTask> = Vec::new();
        for task in non_std.drain(..) {
            let cost = match &task {
                CryptoTask::VerifyLogin { hash, .. } => auth::parse_bcrypt(hash).map(|p| p.cost),
                _ => Some(10),
            };
            match cost {
                Some(c) => {
                    single.clear();
                    single.push(task);
                    execute_bcrypt_batch(&mut single, cfg, c);
                }
                None => {
                    if let CryptoTask::VerifyLogin { addr, .. } = task {
                        reactor::complete_one(addr, 401, reactor::make_error_json("invalid credentials"));
                    }
                }
            }
        }
        if BUSY_CRYPTO_WORKERS.fetch_sub(1, Ordering::AcqRel) == 1 {
            CRYPTO_QUEUE.notify();
        }
    }
}

fn execute_bcrypt_batch(tasks: &mut Vec<CryptoTask>, cfg: &RuntimeConfig, cost: u32) {
    if tasks.is_empty() {
        return;
    }
    let mut replies: Vec<OutgoingReply> = Vec::with_capacity(tasks.len());
    let mut writes: Vec<WriteTask> = Vec::new();
    let mut salts = [[0u8; 16]; 6];
    let mut expected: [Option<[u8; 23]>; 6] = [None; 6];
    let mut digests = [[0u8; 23]; 6];

    while !tasks.is_empty() {
        let chunk_n = tasks.len().min(6);
        for k in 0..chunk_n {
            match &tasks[k] {
                CryptoTask::VerifyLogin { hash, .. } => {
                    let parsed = auth::parse_bcrypt(hash).expect("validated hash");
                    salts[k] = parsed.salt;
                    expected[k] = Some(parsed.digest);
                }
                CryptoTask::HashPassword { .. } => {
                    assert!(codec::fill_random(&mut salts[k]), "getrandom");
                    expected[k] = None;
                }
            }
        }
        {
            let pw = |k: usize| -> &[u8] {
                match &tasks[k] {
                    CryptoTask::VerifyLogin { password, .. } | CryptoTask::HashPassword { password, .. } => {
                        password.as_slice()
                    }
                }
            };
            macro_rules! run_n {
                ($n:literal) => {{
                    let inputs: [BcryptInput; $n] = std::array::from_fn(|k| BcryptInput {
                        password: pw(k),
                        salt: salts[k],
                    });
                    digests[..$n].copy_from_slice(&auth::bcrypt_lanes::<$n>(&inputs, cost));
                }};
            }
            match chunk_n {
                1 => run_n!(1),
                2 => run_n!(2),
                3 => run_n!(3),
                4 => run_n!(4),
                5 => run_n!(5),
                _ => run_n!(6),
            }
        }
        for (k, task) in tasks.drain(..chunk_n).enumerate() {
            let digest = &digests[k];
            let salt = &salts[k];
            match task {
                CryptoTask::VerifyLogin { user, addr, .. } => {
                    if auth::ct_digest_eq(digest, &expected[k].unwrap()) {
                        let tok = cfg.signer.issue(user.id);
                        let mut body = Vec::with_capacity(512);
                        write_user_envelope(
                            &mut body,
                            &user.email,
                            tok.as_bytes(),
                            &user.username,
                            user.bio.as_deref(),
                            user.image.as_deref(),
                        );
                        replies.push(OutgoingReply {
                            addr,
                            status: 200,
                            body: ReplyBody::Owned(body),
                        });
                    } else {
                        replies.push(reactor::error_reply(addr, 401, "invalid credentials"));
                    }
                }
                CryptoTask::HashPassword { mut write, .. } => {
                    let formatted = auth::format_bcrypt(cost, salt, digest);
                    match &mut write.op {
                        WriteOp::Register { hash, .. } => *hash = formatted,
                        WriteOp::UpdateUser { hash, .. } => *hash = Some(formatted),
                        _ => {}
                    }
                    writes.push(write);
                }
            }
        }
    }
    if !replies.is_empty() {
        reactor::complete_batch(replies);
    }
    if !writes.is_empty() {
        WRITE_QUEUE.push_batch_front(&mut writes);
    }
}
