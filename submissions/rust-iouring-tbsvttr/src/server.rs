#![allow(dead_code, unused_imports, unused_mut)]

use std::ffi::c_int;
use std::sync::{Arc, Condvar, Mutex};

use crate::bcrypt::{self, BCRYPT_LANES, BcryptJob};
use crate::buf::{put_int, put_json_string, put_timestamp};
use crate::json;
use crate::jwt::{JwtKey, ct_eq, parse_id};
use crate::pg::{
    DbUrl, Int8s, Row, be_int, be32, length_slot, pg_connect_and_prepare, put32, put64, set32,
    sqlstate_is, statement_name,
};
use crate::sys::{
    EAGAIN, EINTR, MSG_NOSIGNAL, PRIO_PROCESS, close, clock_ms, disable_quickack, fill_random,
    nanosleep, recv, send, set_tcp_nodelay, setpriority, timespec, unix_now,
};

#[cfg(target_os = "linux")]
use crate::sys::{
    EFD_CLOEXEC, EFD_NONBLOCK, EPOLL_CTL_ADD, EPOLL_CTL_DEL, EPOLL_CTL_MOD, EPOLLIN, EPOLLOUT,
    SOCK_CLOEXEC, SOCK_NONBLOCK, TCP_QUICKACK, accept4, epoll_create1, epoll_ctl, epoll_event,
    epoll_wait, eventfd,
};

pub const N_STATEMENTS: usize = 22;

#[repr(u8)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Job {
    None = 0,
    Tags = 1,
    UserGet = 2,
    Login = 3,
    Register = 4,
    UserUpdate = 5,
    Profile = 6,
    Follow = 7,
    Unfollow = 8,
    ListGlobal = 9,
    ListTag = 10,
    ListAuthor = 11,
    ListFavorited = 12,
    Feed = 13,
    Article = 14,
    ArticleCreate = 15,
    ArticleUpdate = 16,
    ArticleDelete = 17,
    Favorite = 18,
    Unfavorite = 19,
    Comments = 20,
    CommentAdd = 21,
    CommentDelete = 22,
    BcLogin = 23,
    BcRegister = 24,
    BcUpdate = 25,
}

impl Job {
    #[inline]
    pub fn is_write(self) -> bool {
        matches!(
            self,
            Job::Register
                | Job::UserUpdate
                | Job::Follow
                | Job::Unfollow
                | Job::ArticleCreate
                | Job::ArticleUpdate
                | Job::ArticleDelete
                | Job::Favorite
                | Job::Unfavorite
                | Job::CommentAdd
                | Job::CommentDelete
        )
    }

    #[inline]
    pub fn batch_job(self) -> Job {
        match self {
            Job::ListGlobal
            | Job::ListTag
            | Job::ListAuthor
            | Job::ListFavorited
            | Job::Feed
            | Job::Article => Job::ListGlobal,
            other => other,
        }
    }

    #[inline]
    pub fn from_u8(v: u8) -> Job {
        match v {
            1 => Job::Tags,
            2 => Job::UserGet,
            3 => Job::Login,
            4 => Job::Register,
            5 => Job::UserUpdate,
            6 => Job::Profile,
            7 => Job::Follow,
            8 => Job::Unfollow,
            9 => Job::ListGlobal,
            10 => Job::ListTag,
            11 => Job::ListAuthor,
            12 => Job::ListFavorited,
            13 => Job::Feed,
            14 => Job::Article,
            15 => Job::ArticleCreate,
            16 => Job::ArticleUpdate,
            17 => Job::ArticleDelete,
            18 => Job::Favorite,
            19 => Job::Unfavorite,
            20 => Job::Comments,
            21 => Job::CommentAdd,
            22 => Job::CommentDelete,
            23 => Job::BcLogin,
            24 => Job::BcRegister,
            25 => Job::BcUpdate,
            _ => Job::None,
        }
    }
}

// ---------------------------------------------------------------------------
// SQL Statement Builder (22 statements matching nelua-epoll-tbsvttr)
// ---------------------------------------------------------------------------

fn tags_of(id: &str) -> String {
    format!(
        "ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) AS name \
         FROM article_tags at WHERE at.article_id = {id} ORDER BY 1)"
    )
}

fn slugify(x: &str) -> String {
    format!("trim(both '-' from lower(regexp_replace({x}, '[^A-Za-z0-9]+', '-', 'g')))")
}

fn capped(rows: &str) -> String {
    format!("(SELECT count(*) FROM ({rows} LIMIT 1000) s)")
}

fn page(rows: &str) -> String {
    format!("(SELECT * FROM ({rows} LIMIT g.lim OFFSET g.ofs) z LIMIT 100)")
}

fn req(cols: &[(&str, &str)]) -> String {
    let mut types = Vec::with_capacity(cols.len());
    let mut names = Vec::with_capacity(cols.len());
    for (i, (name, ty)) in cols.iter().enumerate() {
        types.push(format!("${}::{ty}[]", i + 1));
        names.push(*name);
    }
    format!(
        "req AS (SELECT * FROM unnest({}) WITH ORDINALITY r({}, k))",
        types.join(", "),
        names.join(", ")
    )
}

fn grouped(kind: i32, cols: &str) -> String {
    format!(
        "(SELECT {cols}, array_agg(k) AS ks, array_agg(viewer) AS vs \
         FROM req WHERE kind = {kind} GROUP BY {cols})"
    )
}

fn each_request(group: &str) -> String {
    format!("CROSS JOIN LATERAL unnest({group}.ks, {group}.vs) u(k, viewer)")
}

fn page_ids(rows: &str) -> String {
    format!("ARRAY(SELECT x.id FROM {} x ORDER BY x.id DESC)", page(rows))
}

fn keyed(p: &str, kind: i32, key_sql: &str, count_sql: &str, page_sql: &str) -> String {
    format!(
        "{p}cnt AS MATERIALIZED (SELECT ky.key, ky.fid, {} AS n FROM \
         (SELECT s.key, ({key_sql}) AS fid FROM (SELECT DISTINCT key FROM req WHERE kind = {kind}) s) ky), \
         {p}pa AS MATERIALIZED (SELECT g.ks, g.vs, ky.n, {} AS ids FROM {} g JOIN {p}cnt ky ON ky.key = g.key)",
        capped(count_sql),
        page_ids(page_sql),
        grouped(kind, "key, lim, ofs")
    )
}

fn keyed_rq(p: &str, kind: i32) -> String {
    format!(
        "SELECT u.k, {kind} AS kind, u.viewer, pa.n, pa.ids FROM {p}pa pa {}",
        each_request("pa")
    )
}

fn favorite(write: &str, sign: &str, flag: &str) -> String {
    format!(
        "WITH t AS (SELECT id FROM articles WHERE slug = $2), w AS ({write}) \
         SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, {}, \
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) {sign} (SELECT count(*) FROM w), {flag}, \
         u.username, u.bio, u.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) \
         FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM t)",
        tags_of("a.id")
    )
}

pub fn build_statements() -> Vec<String> {
    let mut s = Vec::with_capacity(N_STATEMENTS);

    // S[1] (s00): TAGS
    s.push("SELECT name FROM tags ORDER BY name".to_string());

    // S[2] (s01): USER_GET ($1 id)
    s.push(format!(
        "WITH {} SELECT r.k, u.id, u.username, u.email, u.bio, u.image FROM req r \
         CROSS JOIN LATERAL (SELECT * FROM users u WHERE u.id = r.id LIMIT 1) u ORDER BY r.k",
        req(&[("id", "int8")])
    ));

    // S[3] (s02): LOGIN ($1 email)
    s.push(format!(
        "WITH {} SELECT r.k, u.id, u.username, u.email, u.bio, u.image, u.password_hash FROM req r \
         CROSS JOIN LATERAL (SELECT * FROM users u WHERE u.email = r.email LIMIT 1) u ORDER BY r.k",
        req(&[("email", "text")])
    ));

    // S[4] (s03): REGISTER ($1 username, $2 email, $3 hash)
    s.push(
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING \
         RETURNING id, username, email, bio, image"
            .to_string(),
    );

    // S[5] (s04): USER_UPDATE ($1 id, $2 email, $3 username, $4 bio, $5 image, $6 hash)
    s.push(
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
         password_hash = COALESCE($6, password_hash), bio = COALESCE($4, bio), image = COALESCE($5, image) \
         WHERE id = $1 RETURNING id, username, email, bio, image"
            .to_string(),
    );

    // S[6] (s05): PROFILE ($1 viewer, $2 username)
    s.push(format!(
        "WITH {} SELECT r.k, u.username, u.bio, u.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = u.id) \
         FROM req r CROSS JOIN LATERAL (SELECT * FROM users u WHERE u.username = r.username LIMIT 1) u ORDER BY r.k",
        req(&[("viewer", "int8"), ("username", "text")])
    ));

    // S[7] (s06): FOLLOW ($1 viewer, $2 username)
    s.push(
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
         w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
         SELECT username, bio, image FROM t"
            .to_string(),
    );

    // S[8] (s07): UNFOLLOW ($1 viewer, $2 username)
    s.push(
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
         w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) \
         SELECT username, bio, image FROM t"
            .to_string(),
    );

    // S[9] (s08): PAGES ($1 kind, $2 viewer, $3 limit, $4 offset, $5 key)
    let pages_sql = format!(
        "WITH req AS (SELECT * FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::int8[], $5::text[]) \
         WITH ORDINALITY r(kind, viewer, lim, ofs, key, k)), \
         gpa AS MATERIALIZED (SELECT g.ks, g.vs, {} AS ids FROM {} g), \
         gcnt AS MATERIALIZED (SELECT {} AS n FROM (SELECT 1 FROM gpa LIMIT 1) g), \
         {}, {}, {}, \
         v AS MATERIALIZED (SELECT viewer, max(lim + ofs) AS depth, array_agg(k) AS ks, array_agg(lim) AS lims, \
           array_agg(ofs) AS ofss FROM req WHERE kind = 5 GROUP BY viewer), \
         fl AS MATERIALIZED (SELECT v.*, f.fid FROM v LEFT JOIN LATERAL \
           (SELECT fo.followee_id AS fid FROM follows fo WHERE fo.follower_id = v.viewer OFFSET 0) f ON true), \
         hubs AS MATERIALIZED (SELECT array_agg(h.fid) AS fids, \
           array_agg((SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC OFFSET h.depth - 1 LIMIT 1)) AS floors, \
           array_agg(EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC OFFSET 999 LIMIT 1)) AS bigs \
           FROM (SELECT fid, max(depth) AS depth FROM fl WHERE fid IS NOT NULL GROUP BY fid HAVING count(*) >= 2 \
           ORDER BY count(*) DESC, fid LIMIT 16) h), \
         vc AS MATERIALIZED (SELECT x.viewer, x.ks, x.lims, x.ofss, COALESCE(x.floor, 0) AS floor, \
           CASE WHEN x.big THEN 1000 ELSE {} END AS n FROM \
           (SELECT fl.viewer, any_value(fl.ks) AS ks, any_value(fl.lims) AS lims, \
            any_value(fl.ofss) AS ofss, bool_or(h.bigs[array_position(h.fids, fl.fid)]) AS big, \
            max(h.floors[array_position(h.fids, fl.fid)]) AS floor FROM fl CROSS JOIN hubs h GROUP BY fl.viewer) x), \
         epa AS MATERIALIZED (SELECT g.k, vc.viewer, vc.n, {} AS ids \
           FROM vc CROSS JOIN LATERAL unnest(vc.ks, vc.lims, vc.ofss) g(k, lim, ofs)), \
         arts AS MATERIALIZED (SELECT s.ks, s.vs, (SELECT a.id FROM articles a WHERE a.slug = s.key) AS id \
           FROM {} s), \
         rq AS MATERIALIZED (\
           SELECT u.k, 1 AS kind, u.viewer, c.n, g.ids FROM gpa g CROSS JOIN gcnt c {} \
           UNION ALL {} UNION ALL {} UNION ALL {} \
           UNION ALL SELECT e.k, 5, e.viewer, e.n, e.ids FROM epa e \
           UNION ALL SELECT u.k, 6, u.viewer, NULL::int8, CASE WHEN ar.id IS NULL THEN NULL ELSE ARRAY[ar.id] END \
             FROM arts ar {}), \
         ids AS MATERIALIZED (SELECT x.id, bool_or(rq.kind = 6) AS with_body FROM rq CROSS JOIN LATERAL unnest(rq.ids) x(id) \
           GROUP BY x.id), \
         info AS MATERIALIZED (SELECT y.* FROM ids x CROSS JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, \
           CASE WHEN x.with_body THEN a.body END AS body, a.created_at, a.updated_at, \
           ARRAY(SELECT at.tag_id::int8 FROM article_tags at WHERE at.article_id = a.id) AS tag_ids, \
           (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fav_count, a.author_id \
           FROM articles a WHERE a.id = x.id LIMIT 1) y), \
         au AS MATERIALIZED (SELECT u.* FROM (SELECT DISTINCT author_id FROM info) x CROSS JOIN LATERAL \
           (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = x.author_id LIMIT 1) u), \
         tn AS MATERIALIZED (SELECT t.id::int8 AS id, t.name, row_number() OVER (ORDER BY t.name) AS rnk \
           FROM (SELECT DISTINCT unnest(tag_ids) AS id FROM info) x CROSS JOIN LATERAL \
           (SELECT t.id, t.name FROM tags t WHERE t.id = x.id LIMIT 1) t) \
         SELECT -2::int8 AS k, tn.rnk AS n, NULL::int8[] AS ids, NULL::int8[] AS favs, NULL::int8[] AS fols, tn.id, \
           tn.name AS slug, NULL::text AS title, NULL::text AS description, NULL::text AS body, \
           NULL::timestamptz AS created_at, NULL::timestamptz AS updated_at, NULL::int8[] AS tag_ids, \
           NULL::int8 AS fav_count, NULL::int8 AS author_id, NULL::text AS username, NULL::text AS bio, NULL::text AS image \
           FROM tn \
         UNION ALL SELECT -1, NULL, NULL, NULL, NULL, au.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, \
           au.username, au.bio, au.image FROM au \
         UNION ALL SELECT 0, NULL, NULL, NULL, NULL, i.id, i.slug, i.title, i.description, i.body, i.created_at, \
           i.updated_at, i.tag_ids, i.fav_count, i.author_id, NULL, NULL, NULL FROM info i \
         UNION ALL SELECT rq.k, rq.n, rq.ids, \
           CASE WHEN rq.viewer <> 0 AND cardinality(rq.ids) > 0 THEN ARRAY(SELECT f.article_id FROM favorites f \
             WHERE f.user_id = rq.viewer AND f.article_id = ANY (rq.ids)) END, \
           CASE WHEN rq.viewer <> 0 AND rq.kind <> 5 THEN ARRAY(SELECT fo.followee_id FROM follows fo \
             WHERE fo.follower_id = rq.viewer) END, \
           NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM rq",
        page_ids("SELECT a.id FROM articles a ORDER BY a.id DESC"),
        grouped(1, "lim, ofs"),
        capped("SELECT 1 FROM articles a"),
        keyed(
            "t",
            2,
            "SELECT t.id FROM tags t WHERE t.name = s.key",
            "SELECT 1 FROM article_tags at WHERE at.tag_id = ky.fid",
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = ky.fid ORDER BY at.article_id DESC",
        ),
        keyed(
            "a",
            3,
            "SELECT u.id FROM users u WHERE u.username = s.key",
            "SELECT 1 FROM articles a WHERE a.author_id = ky.fid",
            "SELECT a.id FROM articles a WHERE a.author_id = ky.fid ORDER BY a.id DESC",
        ),
        keyed(
            "f",
            4,
            "SELECT u.id FROM users u WHERE u.username = s.key",
            "SELECT 1 FROM favorites f WHERE f.user_id = ky.fid",
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = ky.fid ORDER BY f.article_id DESC",
        ),
        capped(
            "SELECT 1 FROM follows fo CROSS JOIN LATERAL \
             (SELECT 1 FROM articles a WHERE a.author_id = fo.followee_id LIMIT 1000) y WHERE fo.follower_id = x.viewer"
        ),
        page_ids(
            "SELECT y.id FROM follows fo CROSS JOIN LATERAL \
             (SELECT a.id FROM articles a WHERE a.author_id = fo.followee_id AND a.id >= vc.floor ORDER BY a.id DESC \
             LIMIT (g.lim + g.ofs)) y WHERE fo.follower_id = vc.viewer ORDER BY y.id DESC"
        ),
        grouped(6, "key"),
        each_request("g"),
        keyed_rq("t", 2),
        keyed_rq("a", 3),
        keyed_rq("f", 4),
        each_request("ar"),
    );
    s.push(pages_sql);

    // S[10]..S[14] (s09..s13): LIST_TAG, LIST_AUTHOR, LIST_FAVORITED, FEED, ARTICLE (in PAGES)
    for _ in 0..5 {
        s.push("SELECT NULL".to_string());
    }

    // S[15] (s14): ARTICLE_CREATE ($1 viewer, $2 title, $3 description, $4 body, $5 tagList JSON)
    s.push(format!(
        "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id), \
         tl AS (SELECT DISTINCT json_array_elements_text($5::json) AS name), \
         a AS (INSERT INTO articles (id, slug, author_id, title, description, body) \
         SELECT n.id, {} || '-' || n.id, $1, $2, $3, $4 FROM n \
         RETURNING id, slug, title, description, body, created_at, updated_at), \
         nt AS (INSERT INTO tags (name) SELECT name FROM tl ORDER BY name ON CONFLICT (name) DO NOTHING RETURNING id), \
         at AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, x.id FROM a, \
         (SELECT id FROM nt UNION SELECT t.id FROM tags t JOIN tl ON t.name = tl.name) x) \
         SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, \
         ARRAY(SELECT name FROM tl ORDER BY name), 0::int8, false, u.username, u.bio, u.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = $1) \
         FROM a JOIN users u ON u.id = $1",
        slugify("$2")
    ));

    // S[16] (s15): ARTICLE_UPDATE ($1 slug, $2 title, $3 description, $4 body, $5 viewer)
    s.push(format!(
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
         w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), \
         body = COALESCE($4, body), slug = CASE WHEN $2::text IS NULL THEN slug ELSE {} || '-' || id END, \
         updated_at = now() WHERE id = (SELECT id FROM t WHERE author_id = $5) \
         RETURNING id, slug, title, description, body, created_at, updated_at, author_id) \
         SELECT t.author_id, w.id, w.slug, w.title, w.description, w.body, w.created_at, w.updated_at, {}, \
         (SELECT count(*) FROM favorites f WHERE f.article_id = w.id), \
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = w.id AND f.user_id = $5), u.username, u.bio, u.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $5 AND fo.followee_id = w.author_id) \
         FROM t LEFT JOIN w ON true LEFT JOIN users u ON u.id = w.author_id",
        slugify("$2"),
        tags_of("w.id")
    ));

    // S[17] (s16): ARTICLE_DELETE ($1 slug, $2 viewer)
    s.push(
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
         w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) SELECT author_id FROM t"
            .to_string(),
    );

    // S[18] (s17): FAVORITE ($1 viewer, $2 slug)
    s.push(favorite(
        "INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING RETURNING 1",
        "+",
        "true",
    ));

    // S[19] (s18): UNFAVORITE ($1 viewer, $2 slug)
    s.push(favorite(
        "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t) RETURNING 1",
        "-",
        "false",
    ));

    // S[20] (s19): COMMENTS ($1 viewer, $2 slug)
    s.push(format!(
        "WITH {}, \
         arts AS MATERIALIZED (SELECT s.slug, s.ks, s.vs, (SELECT a.id FROM articles a WHERE a.slug = s.slug) AS id \
           FROM (SELECT slug, array_agg(k) AS ks, array_agg(viewer) AS vs FROM req GROUP BY slug) s), \
         cm AS MATERIALIZED (SELECT ar.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, \
           u.bio, u.image FROM arts ar CROSS JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id \
           FROM comments c WHERE c.article_id = ar.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c \
           CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id LIMIT 1) u) \
         SELECT 0::int8 AS k, cm.aid, NULL::int8[] AS fols, cm.id, cm.body, cm.created_at, cm.updated_at, cm.author_id, \
           cm.username, cm.bio, cm.image FROM cm \
         UNION ALL SELECT u.k, ar.id, CASE WHEN u.viewer <> 0 AND ar.id IS NOT NULL THEN \
           ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = u.viewer) END, \
           NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM arts ar {} \
         ORDER BY 1, 2, 6 DESC, 4 DESC",
        req(&[("viewer", "int8"), ("slug", "text")]),
        each_request("ar")
    ));

    // S[21] (s20): COMMENT_ADD ($1 slug, $2 viewer, $3 body)
    s.push(
        "WITH t AS (SELECT id FROM articles WHERE slug = $1), \
         c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t \
         RETURNING id, body, created_at, updated_at, author_id) \
         SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"
            .to_string(),
    );

    // S[22] (s21): COMMENT_DELETE ($1 id, $2 slug, $3 viewer)
    s.push(
        "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
         WHERE c.id = $1 AND a.slug = $2), \
         w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) SELECT author_id FROM t"
            .to_string(),
    );

    s
}

// ---------------------------------------------------------------------------
// Open-Addressing ID Lookup Table (IdTable<V>)
// ---------------------------------------------------------------------------

pub struct IdTable<V: Copy + Default> {
    ids: Vec<i64>,
    vals: Vec<V>,
    mask: usize,
}

impl<V: Copy + Default> IdTable<V> {
    pub fn new() -> Self {
        Self {
            ids: Vec::new(),
            vals: Vec::new(),
            mask: 0,
        }
    }

    pub fn reset(&mut self, count: usize) {
        let mut cap = 64usize;
        while cap < count.saturating_mul(2) {
            cap *= 2;
        }
        if cap > self.ids.len() {
            self.ids.resize(cap, 0);
            self.vals.resize(cap, V::default());
        }
        self.ids[..cap].fill(0);
        self.mask = cap - 1;
    }

    #[inline]
    fn slot(&self, id: i64) -> usize {
        let mut i = (((id as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)) >> 32) as usize & self.mask;
        while self.ids[i] != 0 && self.ids[i] != id {
            i = (i + 1) & self.mask;
        }
        i
    }

    #[inline]
    pub fn put(&mut self, id: i64, val: V) {
        if id == 0 {
            return;
        }
        let i = self.slot(id);
        self.ids[i] = id;
        self.vals[i] = val;
    }

    #[inline]
    pub fn get(&self, id: i64) -> Option<V> {
        if id == 0 || self.ids.is_empty() {
            return None;
        }
        let i = self.slot(id);
        if self.ids[i] == id {
            Some(self.vals[i])
        } else {
            None
        }
    }
}

// ---------------------------------------------------------------------------
// In-Process Channels & Messages
// ---------------------------------------------------------------------------

pub struct DbTask {
    pub worker_id: usize,
    pub client_tag: u64,
    pub job: Job,
    pub close_after: bool,
    pub viewer: i64,
    pub nparams: u16,
    pub params: Vec<u8>,
    pub token: Vec<u8>,
}

pub enum HttpPayload {
    Owned(Vec<u8>),
    Shared(Arc<[u8]>),
}

impl HttpPayload {
    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        match self {
            HttpPayload::Owned(v) => v.as_slice(),
            HttpPayload::Shared(a) => a,
        }
    }
}

impl std::ops::Deref for HttpPayload {
    type Target = [u8];

    #[inline]
    fn deref(&self) -> &[u8] {
        self.as_slice()
    }
}

impl AsRef<[u8]> for HttpPayload {
    #[inline]
    fn as_ref(&self) -> &[u8] {
        self.as_slice()
    }
}

pub enum WorkerMsg {
    Http {
        client_tag: u64,
        response: HttpPayload,
    },
    LoginRow {
        client_tag: u64,
        user_id: i64,
        password_hash: Vec<u8>,
        user_prefix: Vec<u8>,
        user_suffix: Vec<u8>,
    },
    BcryptDone {
        client_tag: u64,
        ok: bool,
        hash: [u8; 60],
    },
}

pub struct WorkerInbox {
    pub event_fd: c_int,
    pub queue: Mutex<Vec<WorkerMsg>>,
}

impl WorkerInbox {
    pub fn push_and_wake(&self, msg: WorkerMsg) {
        let should_wake = {
            let mut q = self.queue.lock().unwrap();
            let was_empty = q.is_empty();
            q.push(msg);
            was_empty
        };
        if should_wake {
            wake_eventfd(self.event_fd);
        }
    }
}

pub struct DbInbox {
    pub event_fd: c_int,
    pub queue: Mutex<Vec<DbTask>>,
}

impl DbInbox {
    pub fn push(&self, task: DbTask) -> bool {
        let mut q = self.queue.lock().unwrap();
        let was_empty = q.is_empty();
        q.push(task);
        was_empty
    }
}

#[inline]
pub fn wake_eventfd(fd: c_int) {
    if fd >= 0 {
        let val: u64 = 1;
        unsafe {
            let _ = crate::sys::write(fd, (&val as *const u64).cast(), 8);
        }
    }
}

#[inline]
pub fn drain_eventfd(fd: c_int) {
    if fd >= 0 {
        let mut val: u64 = 0;
        unsafe {
            let _ = crate::sys::read(fd, (&mut val as *mut u64).cast(), 8);
        }
    }
}

// ---------------------------------------------------------------------------
// Multi-Lane Bcrypt Helper Pool
// ---------------------------------------------------------------------------

pub struct BcryptTask {
    pub worker_id: usize,
    pub client_tag: u64,
    pub verify: bool,
    pub password: [u8; 72],
    pub password_len: usize,
    pub hash: [u8; 64],
    pub hash_len: usize,
}

struct BcryptQueue {
    collecting: bool,
    queue: std::collections::VecDeque<BcryptTask>,
}

pub struct BcryptPool {
    state: Mutex<BcryptQueue>,
    cv: Condvar,
    workers: Arc<Vec<Arc<WorkerInbox>>>,
    lanes: usize,
    wait_ms: i64,
}

impl BcryptPool {
    pub fn start(
        helper_count: usize,
        lanes: usize,
        wait_ms: i64,
        workers: Arc<Vec<Arc<WorkerInbox>>>,
    ) -> Arc<Self> {
        let pool = Arc::new(Self {
            state: Mutex::new(BcryptQueue {
                collecting: false,
                queue: std::collections::VecDeque::with_capacity(256),
            }),
            cv: Condvar::new(),
            workers,
            lanes: lanes.clamp(1, BCRYPT_LANES),
            wait_ms,
        });

            for _ in 0..helper_count {
            let p = Arc::clone(&pool);
            std::thread::spawn(move || {
                unsafe {
                    let _ = crate::sys::setpriority(crate::sys::PRIO_PROCESS, 0, 10);
                }
                p.helper_loop();
            });
        }
        pool
    }

    pub fn submit(&self, task: BcryptTask) {
        let mut st = self.state.lock().unwrap();
        st.queue.push_back(task);
        self.cv.notify_all();
    }

    fn helper_loop(&self) {
        let mut reqs: Vec<BcryptTask> = Vec::with_capacity(self.lanes);
        let mut jobs = [BcryptJob::default(); BCRYPT_LANES];
        let mut wants = [[0u8; 23]; BCRYPT_LANES];

        loop {
            reqs.clear();
            {
                let mut st = self.state.lock().unwrap();
                // Wait until we hold the collector token AND at least 1 request is queued
                while st.collecting || st.queue.is_empty() {
                    st = self.cv.wait(st).unwrap();
                }
                st.collecting = true;

                let due = clock_ms() + self.wait_ms;
                while reqs.len() < self.lanes {
                    if let Some(task) = st.queue.pop_front() {
                        let idx = reqs.len();
                        let job = &mut jobs[idx];
                        *job = BcryptJob::default();
                        let mut used = task.password_len.min(72);
                        for i in 0..used {
                            if task.password[i] == 0 {
                                used = i;
                                break;
                            }
                        }
                        job.password[..used].copy_from_slice(&task.password[..used]);
                        job.password_len = used;

                        if task.verify {
                            if !bcrypt::parse(&task.hash[..task.hash_len], job, &mut wants[idx]) {
                                // Invalid bcrypt hash: reply false immediately
                                self.workers[task.worker_id].push_and_wake(WorkerMsg::BcryptDone {
                                    client_tag: task.client_tag,
                                    ok: false,
                                    hash: [0u8; 60],
                                });
                                continue;
                            }
                        } else {
                            job.cost = 10;
                            if !fill_random(&mut job.salt) {
                                self.workers[task.worker_id].push_and_wake(WorkerMsg::BcryptDone {
                                    client_tag: task.client_tag,
                                    ok: false,
                                    hash: [0u8; 60],
                                });
                                continue;
                            }
                        }
                        reqs.push(task);
                    } else if !reqs.is_empty() {
                        let left = due - clock_ms();
                        if left <= 0 {
                            break;
                        }
                        let (new_st, timeout_res) = self
                            .cv
                            .wait_timeout(st, std::time::Duration::from_millis(left as u64))
                            .unwrap();
                        st = new_st;
                        if timeout_res.timed_out() && st.queue.is_empty() {
                            break;
                        }
                    } else {
                        // All popped tasks were invalid and immediately answered; wait for more
                        st = self.cv.wait(st).unwrap();
                    }
                }

                // Hand the collector token to the next helper thread
                st.collecting = false;
                if !st.queue.is_empty() {
                    self.cv.notify_all();
                }
            }

            let n = reqs.len();
            if n == 0 {
                continue;
            }
            bcrypt::run(&mut jobs[..n]);

            for (i, req) in reqs.iter().enumerate() {
                if req.verify {
                    let ok = ct_eq(&jobs[i].digest, &wants[i]);
                    self.workers[req.worker_id].push_and_wake(WorkerMsg::BcryptDone {
                        client_tag: req.client_tag,
                        ok,
                        hash: [0u8; 60],
                    });
                } else {
                    let mut hash = [0u8; 60];
                    bcrypt::format(&jobs[i], &mut hash);
                    self.workers[req.worker_id].push_and_wake(WorkerMsg::BcryptDone {
                        client_tag: req.client_tag,
                        ok: true,
                        hash,
                    });
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// HTTP Response Formatting & Helpers
// ---------------------------------------------------------------------------

#[inline]
fn status_line(status: i32) -> &'static [u8] {
    match status {
        200 => b"200 OK",
        201 => b"201 Created",
        204 => b"204 No Content",
        401 => b"401 Unauthorized",
        403 => b"403 Forbidden",
        404 => b"404 Not Found",
        422 => b"422 Unprocessable Entity",
        503 => b"503 Service Unavailable",
        _ => b"500 Internal Server Error",
    }
}

pub fn build_http_response(out: &mut Vec<u8>, status: i32, close_after: bool, body: &[u8]) {
    out.clear();
    out.extend_from_slice(b"HTTP/1.1 ");
    out.extend_from_slice(status_line(status));
    if status == 204 {
        if close_after {
            out.extend_from_slice(b"\r\nConnection: close");
        }
        out.extend_from_slice(b"\r\n\r\n");
    } else {
        out.extend_from_slice(b"\r\nContent-Type: application/json\r\nContent-Length: ");
        put_int(out, body.len() as i64);
        if close_after {
            out.extend_from_slice(b"\r\nConnection: close");
        }
        out.extend_from_slice(b"\r\n\r\n");
        out.extend_from_slice(body);
    }
}

pub fn build_http_error(out: &mut Vec<u8>, status: i32, close_after: bool, message: &str) {
    let mut body = Vec::with_capacity(32 + message.len());
    body.extend_from_slice(b"{\"errors\":{\"body\":[\"");
    body.extend_from_slice(message.as_bytes());
    body.extend_from_slice(b"\"]}}");
    build_http_response(out, status, close_after, &body);
}

#[inline]
fn put_text(body: &mut Vec<u8>, r: &mut Row<'_>) {
    let s = r.col().unwrap_or(&[]);
    put_json_string(body, s);
}

#[inline]
fn put_text_or_null(body: &mut Vec<u8>, r: &mut Row<'_>) {
    match r.col() {
        Some(s) => put_json_string(body, s),
        None => body.extend_from_slice(b"null"),
    }
}

#[inline]
fn put_bool(body: &mut Vec<u8>, r: &mut Row<'_>) {
    match r.col() {
        Some(s) if s.len() == 1 && s[0] != 0 => body.extend_from_slice(b"true"),
        _ => body.extend_from_slice(b"false"),
    }
}

#[inline]
fn put_time(body: &mut Vec<u8>, r: &mut Row<'_>) {
    let us = r.int();
    put_timestamp(body, us);
}

fn put_text_array(body: &mut Vec<u8>, r: &mut Row<'_>) {
    let col = r.col().unwrap_or(&[]);
    body.push(b'[');
    if col.len() >= 12 && be32(&col[..4]) == 1 {
        let count = be32(&col[12..16]);
        let mut i = 20usize;
        for k in 0..count {
            if i + 4 > col.len() {
                break;
            }
            let len = be32(&col[i..i + 4]);
            if k > 0 {
                body.push(b',');
            }
            if len >= 0 {
                let lu = len as usize;
                put_json_string(body, &col[i + 4..i + 4 + lu]);
                i += 4 + lu;
            } else {
                body.extend_from_slice(b"null");
                i += 4;
            }
        }
    }
    body.push(b']');
}

fn put_profile(body: &mut Vec<u8>, r: &mut Row<'_>) {
    body.extend_from_slice(b"{\"username\":");
    put_text(body, r);
    body.extend_from_slice(b",\"bio\":");
    put_text_or_null(body, r);
    body.extend_from_slice(b",\"image\":");
    put_text_or_null(body, r);
    body.extend_from_slice(b",\"following\":");
    put_bool(body, r);
    body.push(b'}');
}

fn put_article(body: &mut Vec<u8>, r: &mut Row<'_>, with_body: bool) {
    r.skip(); // id
    body.extend_from_slice(b"{\"slug\":");
    put_text(body, r);
    body.extend_from_slice(b",\"title\":");
    put_text(body, r);
    body.extend_from_slice(b",\"description\":");
    put_text(body, r);
    if with_body {
        body.extend_from_slice(b",\"body\":");
        put_text(body, r);
    }
    body.extend_from_slice(b",\"createdAt\":");
    put_time(body, r);
    body.extend_from_slice(b",\"updatedAt\":");
    put_time(body, r);
    body.extend_from_slice(b",\"tagList\":");
    put_text_array(body, r);
    body.extend_from_slice(b",\"favoritesCount\":");
    put_int(body, r.int());
    body.extend_from_slice(b",\"favorited\":");
    put_bool(body, r);
    body.extend_from_slice(b",\"author\":");
    put_profile(body, r);
    body.push(b'}');
}

fn put_comment(body: &mut Vec<u8>, r: &mut Row<'_>, with_following: bool) {
    body.extend_from_slice(b"{\"id\":");
    put_int(body, r.int());
    let bp = r.col().unwrap_or(&[]);
    body.extend_from_slice(b",\"createdAt\":");
    put_time(body, r);
    body.extend_from_slice(b",\"updatedAt\":");
    put_time(body, r);
    body.extend_from_slice(b",\"body\":");
    put_json_string(body, bp);
    body.extend_from_slice(b",\"author\":{\"username\":");
    put_text(body, r);
    body.extend_from_slice(b",\"bio\":");
    put_text_or_null(body, r);
    body.extend_from_slice(b",\"image\":");
    put_text_or_null(body, r);
    body.extend_from_slice(b",\"following\":");
    if with_following {
        put_bool(body, r);
    } else {
        body.extend_from_slice(b"false");
    }
    body.extend_from_slice(b"}}");
}

fn put_user(body: &mut Vec<u8>, token: &[u8], r: &mut Row<'_>) {
    r.skip(); // id
    let up = r.col().unwrap_or(&[]);
    body.extend_from_slice(b"{\"email\":");
    put_text(body, r);
    body.extend_from_slice(b",\"token\":");
    put_json_string(body, token);
    body.extend_from_slice(b",\"username\":");
    put_json_string(body, up);
    body.extend_from_slice(b",\"bio\":");
    put_text_or_null(body, r);
    body.extend_from_slice(b",\"image\":");
    put_text_or_null(body, r);
    body.push(b'}');
}

// ---------------------------------------------------------------------------
// UTF-8 & Parameter Validation (matching nelua-epoll-tbsvttr text_ok / params_ok)
// ---------------------------------------------------------------------------

pub fn text_ok(p: &[u8]) -> bool {
    if p.contains(&0) {
        return false;
    }
    std::str::from_utf8(p).is_ok()
}

pub fn params_ok(params: &[u8], nparams: u16) -> bool {
    let mut i = 0usize;
    for _ in 0..nparams {
        if i + 4 > params.len() {
            return false;
        }
        let len = be32(&params[i..i + 4]);
        i += 4;
        if len > 0 {
            let lu = len as usize;
            if i + lu > params.len() || !text_ok(&params[i..i + lu]) {
                return false;
            }
            i += lu;
        }
    }
    true
}

#[inline]
fn param_at(params: &[u8], j: usize) -> &[u8] {
    let mut i = 0usize;
    for _ in 0..j {
        let len = be32(&params[i..i + 4]);
        i += 4;
        if len > 0 {
            i += len as usize;
        }
    }
    let len = be32(&params[i..i + 4]);
    if len <= 0 {
        &[]
    } else {
        &params[i + 4..i + 4 + (len as usize)]
    }
}

#[inline]
fn parse_int(p: &[u8]) -> i64 {
    if p.is_empty() {
        return 0;
    }
    let mut v = 0i64;
    let mut i = 0usize;
    let neg = p[0] == b'-';
    if neg {
        i = 1;
    }
    while i < p.len() {
        v = v.wrapping_mul(10).wrapping_add((p[i] - b'0') as i64);
        i += 1;
    }
    if neg { -v } else { v }
}

#[inline]
fn pages_param(task: &DbTask, j: usize) -> (&[u8], i64) {
    let job = task.job;
    if j == 0 {
        return (&[], (job as i64) - (Job::ListGlobal as i64) + 1);
    }
    if j == 1 || ((j == 2 || j == 3) && job != Job::Article) {
        let p = param_at(&task.params, j - 1);
        return (p, parse_int(p));
    }
    if j < 4 {
        return (&[], 0);
    }
    if job == Job::Article {
        let p = param_at(&task.params, 1);
        return (p, 0);
    }
    if job == Job::ListGlobal || job == Job::Feed {
        return (&[], 0);
    }
    let p = param_at(&task.params, 3);
    (p, 0)
}

#[inline]
fn batch_types(job: Job) -> &'static [u8] {
    match job {
        Job::UserGet => b"i",
        Job::Login => b"t",
        Job::Profile | Job::Comments => b"it",
        Job::ListGlobal | Job::Feed => b"iiiit",
        _ => b"",
    }
}

// ---------------------------------------------------------------------------
// Pre-Formatted Batch Fragments for PAGES and COMMENTS
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Default)]
struct PreTag {
    rank: i64,
    name_start: u32,
    name_end: u32,
}

#[derive(Clone, Copy, Default)]
struct PreAuthor {
    start: u32,
    end: u32,
}

#[derive(Clone, Copy, Default)]
struct PreArticle {
    id: i64,
    author_id: i64,
    prefix: (u32, u32),
    body_part: (u32, u32),
    mid: (u32, u32),
    author_part: (u32, u32),
}

#[derive(Clone, Copy, Default)]
struct PreComment {
    author_id: i64,
    prefix: (u32, u32),
}

#[derive(Clone, Copy, Default)]
struct SharedPage {
    all_followed: bool,
    count: i64,
    ids_start: usize,
    ids_len: usize,
    resp_idx: u32,
}

// ---------------------------------------------------------------------------
// Database Coordinator (serve_db)
// ---------------------------------------------------------------------------

const INT8_OID: i32 = 20;
const TEXT_OID: i32 = 25;
const PIPELINE_DEPTH: i32 = 8;
const EXECUTE_MSG: &[u8] = b"E\x00\x00\x00\x09\x00\x00\x00\x00\x00";
const SYNC_MSG: &[u8] = b"S\x00\x00\x00\x04";
const PAGES_ID: usize = 4;

struct InflightQuery {
    tasks: Vec<DbTask>,
}

struct PgConn {
    fd: c_int,
    writes: bool,
    flushing: bool,
    watching_out: bool,
    inflight: i32,
    queue: std::collections::VecDeque<InflightQuery>,
    out: Vec<u8>,
    input: Vec<u8>,
    scanned: usize,
}

impl PgConn {
    fn new(writes: bool) -> Self {
        Self {
            fd: -1,
            writes,
            flushing: false,
            watching_out: false,
            inflight: 0,
            queue: std::collections::VecDeque::with_capacity(16),
            out: Vec::with_capacity(65536),
            input: Vec::with_capacity(262144),
            scanned: 0,
        }
    }
}

#[derive(Default)]
struct Batch {
    tasks: std::collections::VecDeque<DbTask>,
    inflight: i32,
    since: i64,
    sent: i64,
}

pub struct DbEngine {
    #[cfg(target_os = "linux")]
    epfd: c_int,
    db_url: DbUrl,
    statements: Vec<String>,
    jwt_key: JwtKey,
    now: i64,
    now_ms: i64,
    last_reconnect: i64,
    pgs: Vec<PgConn>,
    flush_list: Vec<usize>,
    batches: [Batch; N_STATEMENTS + 1],
    write_queue: std::collections::VecDeque<DbTask>,
    write_since: i64,
    batches_waiting: bool,
    batch_inflight: i32,
    batch_ms: i64,
    batch_slow_ms: i64,
    batch_max: usize,
    batch_us: u32,
    inbox: Arc<DbInbox>,
    workers: Arc<Vec<Arc<WorkerInbox>>>,
    worker_out: Vec<Vec<WorkerMsg>>,
    dirty_workers: u64,
    // Reusable scratch structures for zero-allocation batch assembly
    tag_table: IdTable<PreTag>,
    author_table: IdTable<PreAuthor>,
    article_table: IdTable<PreArticle>,
    comment_article_table: IdTable<(u32, u32)>,
    shared_single_table: IdTable<u32>,
    shared_resps: Vec<Arc<[u8]>>,
    shared_pages: Vec<SharedPage>,
    task_rows: Vec<(usize, usize)>,
    comments_vec: Vec<PreComment>,
    tag_refs: Vec<PreTag>,
    arena: Vec<u8>,
    body: Vec<u8>,
    resp_scratch: Vec<u8>,
    token_buf: Vec<u8>,
}

#[cfg(target_os = "linux")]
const TAG_WAKE: u64 = u64::MAX;

impl DbEngine {
    pub fn new(
        db_url: DbUrl,
        statements: Vec<String>,
        jwt_key: JwtKey,
        pool_size: usize,
        batch_inflight: i32,
        batch_ms: i64,
        batch_slow_ms: i64,
        batch_max: usize,
        batch_us: u32,
        inbox: Arc<DbInbox>,
        workers: Arc<Vec<Arc<WorkerInbox>>>,
    ) -> Self {
        let now = unix_now();
        let now_ms = clock_ms();
        let writers = (pool_size / 4).max(1);
        let mut pgs = Vec::with_capacity(pool_size);
        for i in 0..pool_size {
            pgs.push(PgConn::new(i >= pool_size - writers));
        }

        let mut worker_out = Vec::with_capacity(workers.len());
        for _ in 0..workers.len() {
            worker_out.push(Vec::with_capacity(512));
        }

        #[cfg(target_os = "linux")]
        let epfd = unsafe { epoll_create1(0) };

        let mut engine = Self {
            #[cfg(target_os = "linux")]
            epfd,
            db_url,
            statements,
            jwt_key,
            now,
            now_ms,
            last_reconnect: now,
            pgs,
            flush_list: Vec::with_capacity(pool_size),
            batches: std::array::from_fn(|_| Batch::default()),
            write_queue: std::collections::VecDeque::with_capacity(256),
            write_since: now_ms,
            batches_waiting: false,
            batch_inflight,
            batch_ms,
            batch_slow_ms,
            batch_max,
            batch_us,
            inbox,
            workers,
            worker_out,
            dirty_workers: 0,
            tag_table: IdTable::new(),
            author_table: IdTable::new(),
            article_table: IdTable::new(),
            comment_article_table: IdTable::new(),
            shared_single_table: IdTable::new(),
            shared_resps: Vec::with_capacity(128),
            shared_pages: Vec::with_capacity(128),
            task_rows: Vec::with_capacity(512),
            comments_vec: Vec::with_capacity(512),
            tag_refs: Vec::with_capacity(32),
            arena: Vec::with_capacity(524288),
            body: Vec::with_capacity(131072),
            resp_scratch: Vec::with_capacity(131072),
            token_buf: Vec::with_capacity(160),
        };

        #[cfg(target_os = "linux")]
        {
            engine.watch(engine.inbox.event_fd, EPOLL_CTL_ADD, EPOLLIN, TAG_WAKE);
            for i in 0..pool_size {
                if !engine.pg_connect(i) {
                    break;
                }
            }
        }
        engine
    }

    #[cfg(target_os = "linux")]
    #[inline]
    fn watch(&self, fd: c_int, op: c_int, events: u32, tag: u64) {
        let mut ev = epoll_event {
            events,
            u64_data: tag,
        };
        unsafe {
            let _ = epoll_ctl(self.epfd, op, fd, &mut ev);
        }
    }

    #[inline]
    fn send_to_worker(&mut self, worker_id: usize, msg: WorkerMsg) {
        self.worker_out[worker_id].push(msg);
        if worker_id < 64 {
            self.dirty_workers |= 1u64 << worker_id;
        } else {
            let w = &self.workers[worker_id];
            {
                let mut q = w.queue.lock().unwrap();
                q.append(&mut self.worker_out[worker_id]);
            }
            wake_eventfd(w.event_fd);
        }
    }

    fn flush_workers(&mut self) {
        let mut mask = self.dirty_workers;
        self.dirty_workers = 0;
        while mask != 0 {
            let wid = mask.trailing_zeros() as usize;
            mask &= mask - 1;
            let out = &mut self.worker_out[wid];
            if !out.is_empty() {
                let w = &self.workers[wid];
                let should_wake = {
                    let mut q = w.queue.lock().unwrap();
                    let was_empty = q.is_empty();
                    if was_empty {
                        std::mem::swap(&mut *q, out);
                    } else {
                        q.append(out);
                    }
                    was_empty
                };
                if should_wake {
                    wake_eventfd(w.event_fd);
                }
            }
        }
    }

    fn send_http(&mut self, task: &DbTask, status: i32, body: &[u8]) {
        let mut resp = Vec::with_capacity(128 + body.len());
        build_http_response(&mut resp, status, task.close_after, body);
        self.send_to_worker(
            task.worker_id,
            WorkerMsg::Http {
                client_tag: task.client_tag,
                response: HttpPayload::Owned(resp),
            },
        );
    }

    fn send_body(&mut self, task: &DbTask, status: i32) {
        let mut resp = Vec::with_capacity(128 + self.body.len());
        build_http_response(&mut resp, status, task.close_after, &self.body);
        self.send_to_worker(
            task.worker_id,
            WorkerMsg::Http {
                client_tag: task.client_tag,
                response: HttpPayload::Owned(resp),
            },
        );
    }

    #[inline]
    fn build_shared_body(&mut self, status: i32) -> Arc<[u8]> {
        build_http_response(&mut self.resp_scratch, status, false, &self.body);
        Arc::from(self.resp_scratch.as_slice())
    }

    #[inline]
    fn send_shared(&mut self, task: &DbTask, resp: Arc<[u8]>) {
        self.send_to_worker(
            task.worker_id,
            WorkerMsg::Http {
                client_tag: task.client_tag,
                response: HttpPayload::Shared(resp),
            },
        );
    }

    fn send_error(&mut self, task: &DbTask, status: i32, message: &str) {
        let mut resp = Vec::with_capacity(160 + message.len());
        build_http_error(&mut resp, status, task.close_after, message);
        self.send_to_worker(
            task.worker_id,
            WorkerMsg::Http {
                client_tag: task.client_tag,
                response: HttpPayload::Owned(resp),
            },
        );
    }

    fn fail_job(&mut self, task: &DbTask, unique_violation: bool) {
        if unique_violation {
            self.send_error(task, 422, "username or email is already taken");
        } else {
            self.send_error(task, 500, "internal server error");
        }
    }

    fn finish_job(&mut self, task: &DbTask, m: &[u8], batch_rows: bool) {
        let job = task.job;
        let mut first_row: Option<&[u8]> = None;
        let mut i = 0usize;
        while i < m.len() {
            let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
            let kind = m[i];
            if kind == b'E' {
                let unique = sqlstate_is(&m[i + 5..i + size], b"23505");
                self.fail_job(task, unique);
                return;
            } else if kind == b'D' && first_row.is_none() {
                first_row = Some(&m[i + 5..i + size]);
            }
            i += size;
        }

        self.body.clear();
        match job {
            Job::Tags => {
                self.body.extend_from_slice(b"{\"tags\":[");
                let mut first = true;
                i = 0;
                while i < m.len() {
                    let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
                    if m[i] == b'D' {
                        if !first {
                            self.body.push(b',');
                        }
                        first = false;
                        let mut r = Row::open(&m[i + 5..i + size], batch_rows);
                        put_text(&mut self.body, &mut r);
                    }
                    i += size;
                }
                self.body.extend_from_slice(b"]}");
                self.send_body(task, 200);
            }
            Job::UserGet | Job::UserUpdate => {
                let Some(row) = first_row else {
                    self.send_error(task, 401, "unknown user");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                self.body.extend_from_slice(b"{\"user\":");
                put_user(&mut self.body, &task.token, &mut r);
                self.body.push(b'}');
                self.send_body(task, 200);
            }
            Job::Login => {
                let Some(row) = first_row else {
                    self.send_error(task, 401, "email or password is invalid");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                let user_id = r.int();
                let username = r.col().unwrap_or(&[]);
                let email = r.col().unwrap_or(&[]);
                let bio = r.col();
                let image = r.col();
                let hp = r.col().unwrap_or(&[]);

                let mut user_prefix = Vec::with_capacity(32 + email.len());
                user_prefix.extend_from_slice(b"{\"user\":{\"email\":");
                put_json_string(&mut user_prefix, email);
                user_prefix.extend_from_slice(b",\"token\":\"");

                let mut user_suffix = Vec::with_capacity(64 + username.len());
                user_suffix.extend_from_slice(b"\",\"username\":");
                put_json_string(&mut user_suffix, username);
                user_suffix.extend_from_slice(b",\"bio\":");
                match bio {
                    Some(b) => put_json_string(&mut user_suffix, b),
                    None => user_suffix.extend_from_slice(b"null"),
                }
                user_suffix.extend_from_slice(b",\"image\":");
                match image {
                    Some(im) => put_json_string(&mut user_suffix, im),
                    None => user_suffix.extend_from_slice(b"null"),
                }
                user_suffix.extend_from_slice(b"}}");

                self.send_to_worker(
                    task.worker_id,
                    WorkerMsg::LoginRow {
                        client_tag: task.client_tag,
                        user_id,
                        password_hash: hp.to_vec(),
                        user_prefix,
                        user_suffix,
                    },
                );
            }
            Job::Register => {
                let Some(row) = first_row else {
                    self.send_error(task, 422, "username or email is already taken");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                let uid = r.int();
                self.token_buf.clear();
                self.jwt_key.sign(uid, self.now, &mut self.token_buf);
                let mut r2 = Row::open(row, batch_rows);
                self.body.extend_from_slice(b"{\"user\":");
                put_user(&mut self.body, &self.token_buf, &mut r2);
                self.body.push(b'}');
                self.send_body(task, 201);
            }
            Job::Profile | Job::Follow | Job::Unfollow => {
                let Some(row) = first_row else {
                    self.send_error(task, 404, "profile not found");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                self.body.extend_from_slice(b"{\"profile\":{\"username\":");
                put_text(&mut self.body, &mut r);
                self.body.extend_from_slice(b",\"bio\":");
                put_text_or_null(&mut self.body, &mut r);
                self.body.extend_from_slice(b",\"image\":");
                put_text_or_null(&mut self.body, &mut r);
                self.body.extend_from_slice(b",\"following\":");
                if job == Job::Profile {
                    put_bool(&mut self.body, &mut r);
                } else if job == Job::Follow {
                    self.body.extend_from_slice(b"true");
                } else {
                    self.body.extend_from_slice(b"false");
                }
                self.body.extend_from_slice(b"}}");
                self.send_body(task, 200);
            }
            Job::ListGlobal
            | Job::ListTag
            | Job::ListAuthor
            | Job::ListFavorited
            | Job::Feed => {
                self.send_http(task, 200, b"{\"articles\":[],\"articlesCount\":0}");
            }
            Job::Article | Job::Favorite | Job::Unfavorite | Job::ArticleCreate => {
                let Some(row) = first_row else {
                    if job == Job::ArticleCreate {
                        self.send_error(task, 500, "internal server error");
                    } else {
                        self.send_error(task, 404, "article not found");
                    }
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                self.body.extend_from_slice(b"{\"article\":");
                put_article(&mut self.body, &mut r, true);
                self.body.push(b'}');
                let status = if job == Job::ArticleCreate { 201 } else { 200 };
                self.send_body(task, status);
            }
            Job::ArticleUpdate => {
                let Some(row) = first_row else {
                    self.send_error(task, 404, "article not found");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                if r.int() != task.viewer {
                    self.send_error(task, 403, "only the author can edit this article");
                    return;
                }
                self.body.extend_from_slice(b"{\"article\":");
                put_article(&mut self.body, &mut r, true);
                self.body.push(b'}');
                self.send_body(task, 200);
            }
            Job::ArticleDelete | Job::CommentDelete => {
                let Some(row) = first_row else {
                    self.send_error(task, 404, "not found");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                if r.int() != task.viewer {
                    self.send_error(task, 403, "only the author can delete this");
                    return;
                }
                self.send_http(task, 204, &[]);
            }
            Job::Comments => {
                self.send_error(task, 404, "article not found");
            }
            Job::CommentAdd => {
                let Some(row) = first_row else {
                    self.send_error(task, 404, "article not found");
                    return;
                };
                let mut r = Row::open(row, batch_rows);
                self.body.extend_from_slice(b"{\"comment\":");
                put_comment(&mut self.body, &mut r, false);
                self.body.push(b'}');
                self.send_body(task, 201);
            }
            _ => {
                self.send_error(task, 500, "internal server error");
            }
        }
    }

    fn batch_fail(&mut self, tasks: &[DbTask]) {
        if tasks.is_empty() {
            return;
        }
        let bjob = tasks[0].job.batch_job() as usize;
        self.batches[bjob].inflight -= 1;
        self.batches_waiting = true;
        for task in tasks {
            self.fail_job(task, false);
        }
    }

    fn batch_finish(&mut self, tasks: &[DbTask], m: &[u8]) {
        let mut first_row = m.len();
        let mut i = 0usize;
        while i < m.len() {
            let kind = m[i];
            if kind == b'E' {
                self.batch_fail(tasks);
                return;
            }
            if kind == b'D' && first_row == m.len() {
                first_row = i;
            }
            i += 1 + (be32(&m[i + 1..i + 5]) as usize);
        }
        let job = tasks[0].job;
        self.batches[job as usize].inflight -= 1;
        self.batches_waiting = true;

        if job == Job::Tags {
            // Format TAGS once for the entire batch!
            self.body.clear();
            self.body.extend_from_slice(b"{\"tags\":[");
            let mut first = true;
            let mut j = first_row;
            while j < m.len() {
                let size = 1 + (be32(&m[j + 1..j + 5]) as usize);
                if m[j] == b'D' {
                    if !first {
                        self.body.push(b',');
                    }
                    first = false;
                    let mut r = Row::open(&m[j + 5..j + size], false);
                    put_text(&mut self.body, &mut r);
                }
                j += size;
            }
            self.body.extend_from_slice(b"]}");
            let shared = self.build_shared_body(200);
            for task in tasks {
                if !task.close_after {
                    self.send_shared(task, Arc::clone(&shared));
                } else {
                    self.send_body(task, 200);
                }
            }
            return;
        }

        i = first_row;
        for (idx, task) in tasks.iter().enumerate() {
            let k = (idx + 1) as i64;
            let start = i;
            while i < m.len() && m[i] == b'D' && be_int(&m[i + 11..i + 19]) == k {
                i += 1 + (be32(&m[i + 1..i + 5]) as usize);
            }
            self.finish_job(task, &m[start..i], true);
        }
    }

    #[inline]
    fn message_k(m: &[u8], i: usize) -> i64 {
        be_int(&m[i + 11..i + 19])
    }

    #[cfg(test)]
    pub fn test_pages_finish(&mut self, tasks: &[DbTask], m: &[u8]) {
        self.batches[Job::ListGlobal as usize].inflight += 1;
        self.pages_finish(tasks, m);
        self.flush_workers();
    }

    fn pages_finish(&mut self, tasks: &[DbTask], m: &[u8]) {
        let mut first_row = m.len();
        let mut tags = 0usize;
        let mut authors = 0usize;
        let mut articles = 0usize;
        let mut i = 0usize;
        while i < m.len() {
            let kind = m[i];
            if kind == b'E' {
                self.batch_fail(tasks);
                return;
            }
            if kind == b'D' {
                if first_row == m.len() {
                    first_row = i;
                }
                let k = Self::message_k(m, i);
                if k == -2 {
                    tags += 1;
                } else if k == -1 {
                    authors += 1;
                } else if k == 0 {
                    articles += 1;
                }
            }
            i += 1 + (be32(&m[i + 1..i + 5]) as usize);
        }

        let bjob = tasks[0].job.batch_job() as usize;
        self.batches[bjob].inflight -= 1;
        self.batches_waiting = true;

        self.tag_table.reset(tags);
        self.author_table.reset(authors);
        self.article_table.reset(articles);
        self.shared_single_table.reset(articles.max(1));
        self.shared_resps.clear();
        self.shared_pages.clear();
        self.arena.clear();

        i = first_row;
        while i < m.len() && m[i] == b'D' && Self::message_k(m, i) <= 0 {
            let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
            let row = &m[i + 5..i + size];
            let k = Self::message_k(m, i);
            let mut r = Row::open(row, true);

            if k == -2 {
                // Tag row: n = rank, skip 3 (ids, favs, fols), id, slug = tag_name
                let rank = r.int();
                r.skip();
                r.skip();
                r.skip();
                let id = r.int();
                let name = r.col().unwrap_or(&[]);
                let name_start = self.arena.len() as u32;
                put_json_string(&mut self.arena, name);
                let name_end = self.arena.len() as u32;
                self.tag_table.put(
                    id,
                    PreTag {
                        rank,
                        name_start,
                        name_end,
                    },
                );
            } else if k == -1 {
                // Author row: skip 4 (n, ids, favs, fols), id, skip 9 (slug..author_id), username, bio, image
                for _ in 0..PAGES_ID {
                    r.skip();
                }
                let id = r.int();
                for _ in 0..9 {
                    r.skip();
                }
                let start = self.arena.len() as u32;
                self.arena.extend_from_slice(b",\"author\":{\"username\":");
                put_text(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"bio\":");
                put_text_or_null(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"image\":");
                put_text_or_null(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"following\":");
                let end = self.arena.len() as u32;
                self.author_table.put(id, PreAuthor { start, end });
            } else {
                // Article row (k == 0): pre-format once per distinct article in the batch!
                for _ in 0..PAGES_ID {
                    r.skip();
                }
                let id = r.int();

                let p_start = self.arena.len() as u32;
                self.arena.extend_from_slice(b"{\"slug\":");
                put_text(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"title\":");
                put_text(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"description\":");
                put_text(&mut self.arena, &mut r);
                let p_end = self.arena.len() as u32;

                let b_start = self.arena.len() as u32;
                if let Some(body_bytes) = r.col() {
                    self.arena.extend_from_slice(b",\"body\":");
                    put_json_string(&mut self.arena, body_bytes);
                }
                let b_end = self.arena.len() as u32;

                let m_start = self.arena.len() as u32;
                self.arena.extend_from_slice(b",\"createdAt\":");
                put_time(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"updatedAt\":");
                put_time(&mut self.arena, &mut r);
                self.arena.extend_from_slice(b",\"tagList\":[");

                let tag_ids = Int8s::from_col(r.col());
                self.tag_refs.clear();
                for ti in 0..tag_ids.count {
                    if let Some(pt) = self.tag_table.get(tag_ids.at(ti)) {
                        // Insertion sort by rank
                        let mut pos = self.tag_refs.len();
                        self.tag_refs.push(pt);
                        while pos > 0 && self.tag_refs[pos - 1].rank > pt.rank {
                            self.tag_refs[pos] = self.tag_refs[pos - 1];
                            pos -= 1;
                        }
                        self.tag_refs[pos] = pt;
                    }
                }
                for (ti, pt) in self.tag_refs.iter().enumerate() {
                    if ti > 0 {
                        self.arena.push(b',');
                    }
                    // Copy pre-escaped tag string slice inside arena
                    let ns = pt.name_start as usize;
                    let ne = pt.name_end as usize;
                    self.arena.extend_from_within(ns..ne);
                }
                self.arena.extend_from_slice(b"],\"favoritesCount\":");
                put_int(&mut self.arena, r.int());
                self.arena.extend_from_slice(b",\"favorited\":");
                let m_end = self.arena.len() as u32;

                let author_id = r.int();
                let author_part = self
                    .author_table
                    .get(author_id)
                    .map(|a| (a.start, a.end))
                    .unwrap_or((0, 0));

                self.article_table.put(
                    id,
                    PreArticle {
                        id,
                        author_id,
                        prefix: (p_start, p_end),
                        body_part: (b_start, b_end),
                        mid: (m_start, m_end),
                        author_part,
                    },
                );
            }
            i += size;
        }

        self.task_rows.clear();
        self.task_rows.resize(tasks.len(), (0, 0));
        while i < m.len() {
            let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
            if m[i] == b'D' {
                let k = Self::message_k(m, i);
                if k >= 1 && (k as usize) <= tasks.len() {
                    self.task_rows[(k as usize) - 1] = (i + 5, i + size);
                }
            }
            i += size;
        }

        // Now assemble each request's response using pre-formatted slices
        for (idx, task) in tasks.iter().enumerate() {
            let (rs, re) = self.task_rows[idx];
            if rs == 0 {
                self.send_error(task, 500, "internal server error");
                continue;
            }
            let row = &m[rs..re];

            let mut r = Row::open(row, true);
            let count = r.int();
            let ids = Int8s::from_col(r.col());
            let favs = Int8s::from_col(r.col());
            let fols = Int8s::from_col(r.col());

            if task.job == Job::Article {
                let art_opt = if ids.count > 0 {
                    self.article_table.get(ids.at(0))
                } else {
                    None
                };
                let Some(art) = art_opt else {
                    self.send_error(task, 404, "article not found");
                    continue;
                };
                let can_share = !task.close_after && favs.count == 0 && fols.count == 0;
                if can_share {
                    if let Some(ridx) = self.shared_single_table.get(art.id) {
                        let arc = Arc::clone(&self.shared_resps[ridx as usize]);
                        self.send_shared(task, arc);
                        continue;
                    }
                }
                self.body.clear();
                self.body.extend_from_slice(b"{\"article\":");
                Self::emit_pre_article(&mut self.body, &self.arena, &art, true, &favs, &fols, false);
                self.body.push(b'}');
                if can_share {
                    let arc = self.build_shared_body(200);
                    let ridx = self.shared_resps.len() as u32;
                    self.shared_resps.push(Arc::clone(&arc));
                    self.shared_single_table.put(art.id, ridx);
                    self.send_shared(task, arc);
                } else {
                    self.send_body(task, 200);
                }
            } else {
                let all_followed = task.job == Job::Feed;
                let can_share = !task.close_after
                    && favs.count == 0
                    && (all_followed || fols.count == 0);
                let ids_bytes = &ids.p[..ids.count * 12];
                if can_share {
                    let mut hit: Option<Arc<[u8]>> = None;
                    for sp in &self.shared_pages {
                        if sp.all_followed == all_followed
                            && sp.count == count
                            && sp.ids_len == ids_bytes.len()
                            && &m[sp.ids_start..sp.ids_start + sp.ids_len] == ids_bytes
                        {
                            hit = Some(Arc::clone(&self.shared_resps[sp.resp_idx as usize]));
                            break;
                        }
                    }
                    if let Some(arc) = hit {
                        self.send_shared(task, arc);
                        continue;
                    }
                }
                self.body.clear();
                self.body.extend_from_slice(b"{\"articles\":[");
                let mut first = true;
                for ai in 0..ids.count {
                    if let Some(art) = self.article_table.get(ids.at(ai)) {
                        if !first {
                            self.body.push(b',');
                        }
                        first = false;
                        Self::emit_pre_article(
                            &mut self.body,
                            &self.arena,
                            &art,
                            false,
                            &favs,
                            &fols,
                            all_followed,
                        );
                    }
                }
                self.body.extend_from_slice(b"],\"articlesCount\":");
                put_int(&mut self.body, count);
                self.body.push(b'}');
                if can_share {
                    let arc = self.build_shared_body(200);
                    let resp_idx = self.shared_resps.len() as u32;
                    self.shared_resps.push(Arc::clone(&arc));
                    let ids_start = if ids_bytes.is_empty() {
                        0
                    } else {
                        (ids_bytes.as_ptr() as usize) - (m.as_ptr() as usize)
                    };
                    self.shared_pages.push(SharedPage {
                        all_followed,
                        count,
                        ids_start,
                        ids_len: ids_bytes.len(),
                        resp_idx,
                    });
                    self.send_shared(task, arc);
                } else {
                    self.send_body(task, 200);
                }
            }
        }
        self.shared_resps.clear();
        self.shared_pages.clear();
    }

    #[inline]
    fn emit_pre_article(
        body: &mut Vec<u8>,
        arena: &[u8],
        art: &PreArticle,
        with_body: bool,
        favs: &Int8s<'_>,
        fols: &Int8s<'_>,
        all_followed: bool,
    ) {
        body.extend_from_slice(&arena[art.prefix.0 as usize..art.prefix.1 as usize]);
        if with_body {
            body.extend_from_slice(&arena[art.body_part.0 as usize..art.body_part.1 as usize]);
        }
        body.extend_from_slice(&arena[art.mid.0 as usize..art.mid.1 as usize]);
        body.extend_from_slice(if favs.has(art.id) { b"true" } else { b"false" });
        body.extend_from_slice(&arena[art.author_part.0 as usize..art.author_part.1 as usize]);
        body.extend_from_slice(if all_followed || fols.has(art.author_id) {
            b"true}}"
        } else {
            b"false}}"
        });
    }

    #[inline]
    fn comment_article(m: &[u8], i: usize) -> i64 {
        be_int(&m[i + 23..i + 31])
    }

    fn comments_finish(&mut self, tasks: &[DbTask], m: &[u8]) {
        let mut first_row = m.len();
        let mut articles = 0usize;
        let mut last = 0i64;
        let mut i = 0usize;
        while i < m.len() {
            let kind = m[i];
            if kind == b'E' {
                self.batch_fail(tasks);
                return;
            }
            if kind == b'D' {
                if first_row == m.len() {
                    first_row = i;
                }
                if Self::message_k(m, i) == 0 {
                    let aid = Self::comment_article(m, i);
                    if aid != last {
                        last = aid;
                        articles += 1;
                    }
                }
            }
            i += 1 + (be32(&m[i + 1..i + 5]) as usize);
        }

        self.batches[Job::Comments as usize].inflight -= 1;
        self.batches_waiting = true;

        self.comment_article_table.reset(articles);
        self.shared_single_table.reset(articles.max(1));
        self.shared_resps.clear();
        self.comments_vec.clear();
        self.arena.clear();

        i = first_row;
        let mut cur_aid = 0i64;
        let mut cur_start = 0u32;
        while i < m.len() && m[i] == b'D' && Self::message_k(m, i) == 0 {
            let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
            let aid = Self::comment_article(m, i);
            if aid != cur_aid {
                if cur_aid != 0 {
                    self.comment_article_table
                        .put(cur_aid, (cur_start, self.comments_vec.len() as u32));
                }
                cur_aid = aid;
                cur_start = self.comments_vec.len() as u32;
            }
            let row = &m[i + 5..i + size];
            let mut r = Row::open(row, true);
            r.skip(); // aid
            r.skip(); // fols (NULL)
            let p_start = self.arena.len() as u32;
            self.arena.extend_from_slice(b"{\"id\":");
            put_int(&mut self.arena, r.int());
            let bp = r.col().unwrap_or(&[]);
            self.arena.extend_from_slice(b",\"createdAt\":");
            put_time(&mut self.arena, &mut r);
            self.arena.extend_from_slice(b",\"updatedAt\":");
            put_time(&mut self.arena, &mut r);
            self.arena.extend_from_slice(b",\"body\":");
            put_json_string(&mut self.arena, bp);
            let author_id = r.int();
            self.arena.extend_from_slice(b",\"author\":{\"username\":");
            put_text(&mut self.arena, &mut r);
            self.arena.extend_from_slice(b",\"bio\":");
            put_text_or_null(&mut self.arena, &mut r);
            self.arena.extend_from_slice(b",\"image\":");
            put_text_or_null(&mut self.arena, &mut r);
            self.arena.extend_from_slice(b",\"following\":");
            let p_end = self.arena.len() as u32;
            self.comments_vec.push(PreComment {
                author_id,
                prefix: (p_start, p_end),
            });
            i += size;
        }
        if cur_aid != 0 {
            self.comment_article_table
                .put(cur_aid, (cur_start, self.comments_vec.len() as u32));
        }

        for (idx, task) in tasks.iter().enumerate() {
            let k = (idx + 1) as i64;
            let mut row_opt: Option<&[u8]> = None;
            if i < m.len() && m[i] == b'D' && Self::message_k(m, i) == k {
                let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
                row_opt = Some(&m[i + 5..i + size]);
                i += size;
            }
            let Some(row) = row_opt else {
                self.send_error(task, 500, "internal server error");
                continue;
            };
            let mut r = Row::open(row, true);
            let article_missing = r.is_null();
            let aid = r.int();
            let fols = Int8s::from_col(r.col());
            if article_missing {
                self.send_error(task, 404, "article not found");
            } else {
                let can_share = !task.close_after && fols.count == 0 && aid > 0;
                if can_share {
                    if let Some(ridx) = self.shared_single_table.get(aid) {
                        let arc = Arc::clone(&self.shared_resps[ridx as usize]);
                        self.send_shared(task, arc);
                        continue;
                    }
                }
                self.body.clear();
                self.body.extend_from_slice(b"{\"comments\":[");
                if let Some((c_start, c_end)) = self.comment_article_table.get(aid) {
                    for (ci, cm) in self.comments_vec[c_start as usize..c_end as usize]
                        .iter()
                        .enumerate()
                    {
                        if ci > 0 {
                            self.body.push(b',');
                        }
                        self.body
                            .extend_from_slice(&self.arena[cm.prefix.0 as usize..cm.prefix.1 as usize]);
                        self.body.extend_from_slice(if fols.has(cm.author_id) {
                            b"true}}"
                        } else {
                            b"false}}"
                        });
                    }
                }
                self.body.extend_from_slice(b"]}");
                if can_share {
                    let arc = self.build_shared_body(200);
                    let ridx = self.shared_resps.len() as u32;
                    self.shared_resps.push(Arc::clone(&arc));
                    self.shared_single_table.put(aid, ridx);
                    self.send_shared(task, arc);
                } else {
                    self.send_body(task, 200);
                }
            }
        }
        self.shared_resps.clear();
    }

    #[cfg(target_os = "linux")]
    fn pg_connect(&mut self, idx: usize) -> bool {
        const SESSION_OPTS: &str =
            "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c work_mem=32MB";
        let stmt_refs: Vec<&str> = self.statements.iter().map(|s| s.as_str()).collect();
        match pg_connect_and_prepare(&self.db_url, SESSION_OPTS, &stmt_refs) {
            Ok(fd) => {
                let pc = &mut self.pgs[idx];
                pc.fd = fd;
                pc.inflight = 0;
                pc.queue.clear();
                pc.out.clear();
                pc.input.clear();
                pc.scanned = 0;
                pc.watching_out = false;
                pc.flushing = false;
                self.watch(fd, EPOLL_CTL_ADD, EPOLLIN, idx as u64);
                true
            }
            Err(e) => {
                eprintln!("conduit: Postgres connect failed: {e}");
                false
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn pg_reconnect(&mut self) {
        if self.now - self.last_reconnect < 1 {
            return;
        }
        self.last_reconnect = self.now;
        for i in 0..self.pgs.len() {
            if self.pgs[i].fd < 0 && !self.pg_connect(i) {
                return;
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn pg_down(&mut self, idx: usize) {
        let queries: Vec<InflightQuery> = {
            let pc = &mut self.pgs[idx];
            if pc.fd >= 0 {
                unsafe {
                    let _ = epoll_ctl(self.epfd, EPOLL_CTL_DEL, pc.fd, std::ptr::null_mut());
                    close(pc.fd);
                }
                pc.fd = -1;
            }
            pc.out.clear();
            pc.input.clear();
            pc.scanned = 0;
            pc.inflight = 0;
            pc.watching_out = false;
            pc.queue.drain(..).collect()
        };
        for q in queries {
            if q.tasks[0].job.is_write() {
                for task in &q.tasks {
                    self.fail_job(task, false);
                }
            } else {
                self.batch_fail(&q.tasks);
            }
        }
    }

    fn flush_later(&mut self, idx: usize) {
        if self.pgs[idx].flushing {
            return;
        }
        self.pgs[idx].flushing = true;
        self.flush_list.push(idx);
    }

    #[cfg(target_os = "linux")]
    fn pg_send_out(&mut self, idx: usize) {
        let fd = self.pgs[idx].fd;
        if fd < 0 {
            return;
        }
        if !self.pgs[idx].out.is_empty() {
            let w = unsafe {
                send(
                    fd,
                    self.pgs[idx].out.as_ptr().cast(),
                    self.pgs[idx].out.len(),
                    MSG_NOSIGNAL,
                )
            };
            if w < 0 {
                let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if err != EAGAIN && err != EINTR {
                    self.pg_down(idx);
                    return;
                }
            } else if w > 0 {
                self.pgs[idx].out.drain(..w as usize);
            }
        }
        let want_out = !self.pgs[idx].out.is_empty();
        if want_out != self.pgs[idx].watching_out {
            self.pgs[idx].watching_out = want_out;
            let events = if want_out {
                EPOLLIN | EPOLLOUT
            } else {
                EPOLLIN
            };
            self.watch(fd, EPOLL_CTL_MOD, events, idx as u64);
        }
    }

    #[cfg(target_os = "linux")]
    fn pg_flush_all(&mut self) {
        let mut i = 0usize;
        while i < self.flush_list.len() {
            let idx = self.flush_list[i];
            self.pgs[idx].flushing = false;
            if self.pgs[idx].fd >= 0 && !self.pgs[idx].watching_out {
                self.pg_send_out(idx);
            }
            i += 1;
        }
        self.flush_list.clear();
    }

    fn pg_complete(&mut self, idx: usize, m: &[u8]) {
        let Some(q) = self.pgs[idx].queue.pop_front() else {
            return;
        };
        self.pgs[idx].inflight -= 1;
        let first_job = q.tasks[0].job;
        let bjob = first_job.batch_job();
        if bjob == Job::ListGlobal || bjob == Job::Feed {
            self.pages_finish(&q.tasks, m);
        } else if first_job == Job::Comments {
            self.comments_finish(&q.tasks, m);
        } else if !first_job.is_write() {
            self.batch_finish(&q.tasks, m);
        } else if q.tasks.len() == 1 {
            self.finish_job(&q.tasks[0], m, false);
        } else {
            // Group-commit write batch: check if any statement threw an ErrorResponse ('E').
            // If so, Postgres rolled back the implicit transaction for the entire group,
            // so retry each task individually in its own Sync transaction.
            let mut has_error = false;
            let mut i = 0usize;
            while i < m.len() {
                if m[i] == b'E' {
                    has_error = true;
                    break;
                }
                i += 1 + (be32(&m[i + 1..i + 5]) as usize);
            }
            if has_error {
                for task in q.tasks {
                    let target = if self.pgs[idx].fd >= 0 {
                        Some(idx)
                    } else {
                        self.pg_pick(true).or_else(|| self.pg_pick(false))
                    };
                    if let Some(t_idx) = target {
                        self.pg_queue_write(t_idx, task);
                    } else {
                        self.fail_job(&task, false);
                    }
                }
                self.batches_waiting = true;
                return;
            }
            // All statements in the group succeeded: split by CommandComplete ('C')
            let mut seg_start = 0usize;
            let mut task_idx = 0usize;
            i = 0;
            while i < m.len() && task_idx < q.tasks.len() {
                let size = 1 + (be32(&m[i + 1..i + 5]) as usize);
                let kind = m[i];
                i += size;
                if kind == b'C' {
                    self.finish_job(&q.tasks[task_idx], &m[seg_start..i], false);
                    task_idx += 1;
                    seg_start = i;
                }
            }
            while task_idx < q.tasks.len() {
                self.fail_job(&q.tasks[task_idx], false);
                task_idx += 1;
            }
            self.batches_waiting = true;
        }
    }

    #[cfg(target_os = "linux")]
    fn pg_read(&mut self, idx: usize) {
        let fd = self.pgs[idx].fd;
        if fd < 0 {
            return;
        }
        let mut buf = [0u8; 65536];
        let mut read_any = false;
        loop {
            let n = unsafe { recv(fd, buf.as_mut_ptr().cast(), buf.len(), 0) };
            if n <= 0 {
                if n < 0 {
                    let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                    if err == EAGAIN || err == EINTR {
                        if err == EINTR {
                            continue;
                        }
                        break;
                    }
                }
                self.pg_down(idx);
                return;
            }
            read_any = true;
            self.pgs[idx].input.extend_from_slice(&buf[..n as usize]);
            if (n as usize) < buf.len() {
                break;
            }
        }
        if !read_any {
            return;
        }

        let mut input = std::mem::take(&mut self.pgs[idx].input);
        let mut start = 0usize;
        let mut i = self.pgs[idx].scanned;
        while input.len() - i >= 5 {
            let size = 1 + (be32(&input[i + 1..i + 5]) as usize);
            if input.len() - i < size {
                break;
            }
            let kind = input[i];
            i += size;
            if kind == b'Z' {
                self.pg_complete(idx, &input[start..i]);
                start = i;
            }
        }
        if start > 0 {
            input.drain(..start);
        }
        self.pgs[idx].scanned = i - start;
        self.pgs[idx].input = input;
    }

    fn pg_pick(&self, writes: bool) -> Option<usize> {
        let mut least: Option<usize> = None;
        for (i, pc) in self.pgs.iter().enumerate() {
            if pc.fd >= 0 && pc.writes == writes {
                if writes && pc.inflight < PIPELINE_DEPTH {
                    return Some(i);
                }
                if least.map_or(true, |l| pc.inflight < self.pgs[l].inflight) {
                    least = Some(i);
                }
            }
        }
        least
    }

    fn pg_enqueue(&mut self, idx: usize, tasks: Vec<DbTask>) {
        self.pgs[idx].queue.push_back(InflightQuery { tasks });
        self.pgs[idx].inflight += 1;
        self.flush_later(idx);
    }

    #[inline]
    fn encode_write_bind_exec(o: &mut Vec<u8>, task: &DbTask) {
        o.push(b'B');
        let at = length_slot(o);
        o.push(0); // unnamed portal
        let name = statement_name((task.job as usize) - 1);
        o.extend_from_slice(&name);
        o.extend_from_slice(b"\x00\x00"); // param formats: all text
        o.push((task.nparams >> 8) as u8);
        o.push((task.nparams & 0xFF) as u8);
        o.extend_from_slice(&task.params);
        o.extend_from_slice(b"\x00\x01\x00\x01"); // result formats: binary for all columns
        let len = (o.len() - at) as i32;
        set32(o, at, len);
        o.extend_from_slice(EXECUTE_MSG);
    }

    fn pg_queue_write(&mut self, idx: usize, task: DbTask) {
        let o = &mut self.pgs[idx].out;
        Self::encode_write_bind_exec(o, &task);
        o.extend_from_slice(SYNC_MSG);
        self.pg_enqueue(idx, vec![task]);
    }

    fn pg_queue_write_group(&mut self, idx: usize, tasks: Vec<DbTask>) {
        let o = &mut self.pgs[idx].out;
        for task in &tasks {
            Self::encode_write_bind_exec(o, task);
        }
        o.extend_from_slice(SYNC_MSG);
        self.pg_enqueue(idx, tasks);
    }

    fn batch_queue(&mut self, idx: usize, bjob: Job) {
        let b = &mut self.batches[bjob as usize];
        let count = b.tasks.len().min(self.batch_max);
        let tasks: Vec<DbTask> = b.tasks.drain(..count).collect();
        b.inflight += 1;
        b.since = self.now_ms;
        b.sent = self.now_ms;

        let types = batch_types(bjob);
        let o = &mut self.pgs[idx].out;
        o.push(b'B');
        let at = length_slot(o);
        o.push(0); // unnamed portal
        let name = statement_name((bjob as usize) - 1);
        o.extend_from_slice(&name);
        if !types.is_empty() {
            o.extend_from_slice(b"\x00\x01\x00\x01"); // parameter formats: binary
        } else {
            o.extend_from_slice(b"\x00\x00");
        }
        o.push(0);
        o.push(types.len() as u8);

        for (j, &ty) in types.iter().enumerate() {
            let is_text = ty == b't';
            let array_at = length_slot(o);
            put32(o, 1); // dimensions
            put32(o, 0); // no NULLs
            put32(o, if is_text { TEXT_OID } else { INT8_OID });
            put32(o, count as i32);
            put32(o, 1); // lower bound

            for task in &tasks {
                let (p, v) = if bjob == Job::ListGlobal || bjob == Job::Feed {
                    pages_param(task, j)
                } else {
                    let s = param_at(&task.params, j);
                    let iv = if is_text { 0 } else { parse_int(s) };
                    (s, iv)
                };
                if is_text {
                    put32(o, p.len() as i32);
                    o.extend_from_slice(p);
                } else {
                    put32(o, 8);
                    put64(o, v);
                }
            }
            let arr_len = (o.len() - array_at - 4) as i32;
            set32(o, array_at, arr_len);
        }

        o.extend_from_slice(b"\x00\x01\x00\x01"); // result formats: binary for all columns
        let len = (o.len() - at) as i32;
        set32(o, at, len);
        o.extend_from_slice(EXECUTE_MSG);
        o.extend_from_slice(SYNC_MSG);
        self.pg_enqueue(idx, tasks);
    }

    #[inline]
    fn batch_room(&self, b: &Batch) -> bool {
        b.inflight == 0
            || (b.inflight < self.batch_inflight && self.now_ms - b.sent >= self.batch_slow_ms)
    }

    #[cfg(target_os = "linux")]
    fn batch_send_all(&mut self) {
        if !self.batches_waiting {
            return;
        }
        self.batches_waiting = false;
        for j in 1..=N_STATEMENTS {
            let can_send = {
                let b = &self.batches[j];
                !b.tasks.is_empty()
                    && self.batch_room(b)
                    && (self.now_ms - b.since >= self.batch_ms || b.tasks.len() >= self.batch_max)
            };
            if can_send {
                self.pg_reconnect();
                let pc_idx = self.pg_pick(false).or_else(|| self.pg_pick(true));
                if let Some(idx) = pc_idx {
                    self.batch_queue(idx, Job::from_u8(j as u8));
                } else {
                    let tasks: Vec<DbTask> = self.batches[j].tasks.drain(..).collect();
                    self.batches[j].inflight += 1;
                    self.batch_fail(&tasks);
                }
            }
            if !self.batches[j].tasks.is_empty() {
                self.batches_waiting = true;
            }
        }
        const WRITE_GROUP_MAX: usize = 16;
        while !self.write_queue.is_empty() {
            self.pg_reconnect();
            let pc_idx = self.pg_pick(true).or_else(|| self.pg_pick(false));
            let count = self.write_queue.len().min(WRITE_GROUP_MAX);
            let mut group: Vec<DbTask> = self.write_queue.drain(..count).collect();
            if let Some(idx) = pc_idx {
                if group.len() == 1 {
                    self.pg_queue_write(idx, group.pop().unwrap());
                } else {
                    self.pg_queue_write_group(idx, group);
                }
            } else {
                for task in &group {
                    self.fail_job(task, false);
                }
            }
        }
    }

    fn batch_timeout(&self) -> c_int {
        if !self.batches_waiting {
            return -1;
        }
        let mut due: i64 = -1;
        for j in 1..=N_STATEMENTS {
            let b = &self.batches[j];
            if !b.tasks.is_empty() && b.inflight < self.batch_inflight {
                let mut at = b.since + self.batch_ms;
                if b.inflight > 0 && b.sent + self.batch_slow_ms > at {
                    at = b.sent + self.batch_slow_ms;
                }
                if due < 0 || at < due {
                    due = at;
                }
            }
        }
        if due < 0 {
            -1
        } else if due <= self.now_ms {
            0
        } else {
            (due - self.now_ms) as c_int
        }
    }

    #[cfg(target_os = "linux")]
    fn start_task(&mut self, task: DbTask) {
        let job = task.job;
        if !job.is_write() {
            if !params_ok(&task.params, task.nparams) {
                self.finish_job(&task, &[], false);
                return;
            }
            let bjob = job.batch_job() as usize;
            let b = &mut self.batches[bjob];
            if b.tasks.is_empty() {
                b.since = self.now_ms;
            }
            b.tasks.push_back(task);
            self.batches_waiting = true;
            return;
        }
        self.pg_reconnect();
        let pc_idx = self.pg_pick(true).or_else(|| self.pg_pick(false));
        if let Some(idx) = pc_idx {
            self.pg_queue_write(idx, task);
        } else {
            self.fail_job(&task, false);
        }
    }

    #[cfg(target_os = "linux")]
    pub fn run(&mut self) {
        let mut events = [epoll_event::default(); 1024];
        let mut incoming = Vec::with_capacity(1024);

        loop {
            let timeout = self.batch_timeout();
            let k = unsafe { epoll_wait(self.epfd, events.as_mut_ptr(), 1024, timeout) };
            self.now = unix_now();
            self.now_ms = clock_ms();
            let mut link_busy = false;

            if k > 0 {
                for ev in &events[..k as usize] {
                    let tag = ev.u64_data;
                    let mask = ev.events;
                    if tag == TAG_WAKE {
                        link_busy = true;
                        drain_eventfd(self.inbox.event_fd);
                        {
                            let mut q = self.inbox.queue.lock().unwrap();
                            std::mem::swap(&mut *q, &mut incoming);
                        }
                        for task in incoming.drain(..) {
                            self.start_task(task);
                        }
                    } else {
                        let idx = tag as usize;
                        if mask & EPOLLOUT != 0 {
                            self.pg_send_out(idx);
                        }
                        if self.pgs[idx].fd >= 0 && (mask & !EPOLLOUT) != 0 {
                            self.pg_read(idx);
                        }
                    }
                }
            }

            self.batch_send_all();
            self.pg_flush_all();
            self.flush_workers();

            if k > 0 && k < 32 && self.batch_us > 0 && !link_busy {
                let ts = timespec {
                    tv_sec: 0,
                    tv_nsec: (self.batch_us as i64 * 1000) as _,
                };
                unsafe {
                    let _ = nanosleep(&ts, std::ptr::null_mut());
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// HTTP/1.1 Keep-Alive Worker (serve_worker)
// ---------------------------------------------------------------------------

const CONTINUE_RESP: &[u8] = b"HTTP/1.1 100 Continue\r\n\r\n";

#[inline]
fn lower(c: u8) -> u8 {
    if c.is_ascii_uppercase() { c + 32 } else { c }
}

#[inline]
fn ieq(p: &[u8], s: &[u8]) -> bool {
    if p.len() != s.len() {
        return false;
    }
    for i in 0..p.len() {
        if lower(p[i]) != s[i] {
            return false;
        }
    }
    true
}

#[inline]
fn contains_subslice(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[inline]
fn hex_digit(c: u8) -> i32 {
    match c {
        b'0'..=b'9' => (c - b'0') as i32,
        b'a'..=b'f' => (c - b'a' + 10) as i32,
        b'A'..=b'F' => (c - b'A' + 10) as i32,
        _ => -1,
    }
}

pub fn url_decode(p: &[u8], plus_space: bool, out: &mut Vec<u8>) {
    out.clear();
    let mut i = 0usize;
    while i < p.len() {
        let ch = p[i];
        if ch == b'%' && i + 2 < p.len() {
            let h1 = hex_digit(p[i + 1]);
            let h2 = hex_digit(p[i + 2]);
            if h1 >= 0 && h2 >= 0 {
                out.push((h1 * 16 + h2) as u8);
                i += 3;
                continue;
            }
        }
        if ch == b'+' && plus_space {
            out.push(b' ');
        } else {
            out.push(ch);
        }
        i += 1;
    }
}

#[derive(Clone, Copy)]
struct QueryParams<'a> {
    limit: i64,
    offset: i64,
    ok: bool,
    filter: i32,
    value: &'a [u8],
}

fn parse_count(p: &[u8]) -> i64 {
    if p.is_empty() || p.len() > 12 {
        return -1;
    }
    let mut v = 0i64;
    for &b in p {
        if !b.is_ascii_digit() {
            return -1;
        }
        v = v * 10 + ((b - b'0') as i64);
    }
    v
}

fn parse_query<'a>(q: &'a [u8], scratch: &mut Vec<u8>) -> QueryParams<'a> {
    let mut res = QueryParams {
        limit: 20,
        offset: 0,
        ok: true,
        filter: 0,
        value: &[],
    };
    let mut found = [false; 4];
    let mut fval: [&'a [u8]; 4] = [&[]; 4];
    let mut i = 0usize;
    while i < q.len() {
        let start = i;
        while i < q.len() && q[i] != b'&' {
            i += 1;
        }
        let mut eqi = start;
        while eqi < i && q[eqi] != b'=' {
            eqi += 1;
        }
        let key = &q[start..eqi];
        let val = if eqi < i { &q[eqi + 1..i] } else { &[] };
        if key == b"limit" {
            url_decode(val, true, scratch);
            res.limit = parse_count(scratch);
            if res.limit < 1 || res.limit > 100 {
                res.ok = false;
            }
        } else if key == b"offset" {
            url_decode(val, true, scratch);
            res.offset = parse_count(scratch);
            if res.offset < 0 {
                res.ok = false;
            }
        } else {
            let f = if key == b"tag" {
                1
            } else if key == b"author" {
                2
            } else if key == b"favorited" {
                3
            } else {
                0
            };
            if f > 0 && !found[f] && !val.is_empty() {
                found[f] = true;
                fval[f] = val;
            }
        }
        i += 1;
    }
    for f in 1..=3 {
        if found[f] {
            res.filter = f as i32;
            res.value = fval[f];
            break;
        }
    }
    res
}

fn parse_length(p: &[u8]) -> isize {
    if p.is_empty() || p.len() > 9 {
        return -1;
    }
    let mut v = 0isize;
    for &b in p {
        if !b.is_ascii_digit() {
            return -1;
        }
        v = v * 10 + ((b - b'0') as isize);
    }
    v
}

#[inline]
fn header_end(p: &[u8]) -> Option<usize> {
    if p.len() < 4 {
        return None;
    }
    for i in 3..p.len() {
        if p[i] == b'\n' && p[i - 1] == b'\r' && p[i - 2] == b'\n' && p[i - 3] == b'\r' {
            return Some(i + 1);
        }
    }
    None
}

struct Client {
    fd: c_int,
    generation: u32,
    job: Job,
    close_after: bool,
    closed: bool,
    continue_sent: bool,
    watching_out: bool,
    nparams: u16,
    viewer: i64,
    recv_ms: i64,
    next_free: Option<u32>,
    input: Vec<u8>,
    output: Vec<u8>,
    params: Vec<u8>,
    token: Vec<u8>,
    stash: Vec<u8>,
    login_prefix: Vec<u8>,
    login_suffix: Vec<u8>,
}

impl Client {
    fn new() -> Self {
        Self {
            fd: -1,
            generation: 1,
            job: Job::None,
            close_after: false,
            closed: true,
            continue_sent: false,
            watching_out: false,
            nparams: 0,
            viewer: 0,
            recv_ms: 0,
            next_free: None,
            input: Vec::new(),
            output: Vec::new(),
            params: Vec::new(),
            token: Vec::new(),
            stash: Vec::new(),
            login_prefix: Vec::new(),
            login_suffix: Vec::new(),
        }
    }

    #[inline]
    fn params_reset(&mut self) {
        self.params.clear();
        self.nparams = 0;
    }

    #[inline]
    fn param_text(&mut self, s: &[u8]) {
        put32(&mut self.params, s.len() as i32);
        self.params.extend_from_slice(s);
        self.nparams += 1;
    }

    #[inline]
    fn param_null(&mut self) {
        put32(&mut self.params, -1);
        self.nparams += 1;
    }

    #[inline]
    fn param_int(&mut self, v: i64) {
        let at = length_slot(&mut self.params);
        let start = self.params.len();
        put_int(&mut self.params, v);
        let len = (self.params.len() - start) as i32;
        set32(&mut self.params, at, len);
        self.nparams += 1;
    }
}

#[cfg(target_os = "linux")]
const TAG_LISTEN_A: u64 = u64::MAX - 1;
#[cfg(target_os = "linux")]
const TAG_LISTEN_B: u64 = u64::MAX - 2;

pub struct Worker {
    pub worker_id: usize,
    #[cfg(target_os = "linux")]
    epfd: c_int,
    fd_a: c_int,
    fd_b: c_int,
    jwt_key: JwtKey,
    now: i64,
    now_ms: i64,
    quickack_ms: i64,
    batch_us: u32,
    inbox: Arc<WorkerInbox>,
    db_inbox: Arc<DbInbox>,
    bcrypt_pool: Arc<BcryptPool>,
    pending_db_tasks: Vec<DbTask>,
    clients: Vec<Client>,
    free_head: Option<u32>,
    cur_token: Vec<u8>,
    out_buf: Vec<u8>,
    scratch: Vec<u8>,
    scratch2: Vec<u8>,
    slug_buf: Vec<u8>,
    f1: Vec<u8>,
    f2: Vec<u8>,
    f3: Vec<u8>,
    f4: Vec<u8>,
    f5: Vec<u8>,
}

impl Worker {
    pub fn new(
        worker_id: usize,
        fd_a: c_int,
        fd_b: c_int,
        jwt_key: JwtKey,
        quickack_ms: i64,
        batch_us: u32,
        inbox: Arc<WorkerInbox>,
        db_inbox: Arc<DbInbox>,
        bcrypt_pool: Arc<BcryptPool>,
    ) -> Self {
        #[cfg(target_os = "linux")]
        let epfd = unsafe { epoll_create1(0) };

        let w = Self {
            worker_id,
            #[cfg(target_os = "linux")]
            epfd,
            fd_a,
            fd_b,
            jwt_key,
            now: unix_now(),
            now_ms: clock_ms(),
            quickack_ms,
            batch_us,
            inbox,
            db_inbox,
            bcrypt_pool,
            pending_db_tasks: Vec::with_capacity(512),
            clients: Vec::with_capacity(131072),
            free_head: None,
            cur_token: Vec::with_capacity(256),
            out_buf: Vec::with_capacity(4096),
            scratch: Vec::with_capacity(256),
            scratch2: Vec::with_capacity(256),
            slug_buf: Vec::with_capacity(256),
            f1: Vec::with_capacity(256),
            f2: Vec::with_capacity(256),
            f3: Vec::with_capacity(1024),
            f4: Vec::with_capacity(256),
            f5: Vec::with_capacity(256),
        };

        #[cfg(target_os = "linux")]
        {
            w.watch(w.inbox.event_fd, EPOLL_CTL_ADD, EPOLLIN, TAG_WAKE);
            w.watch(w.fd_a, EPOLL_CTL_ADD, EPOLLIN, TAG_LISTEN_A);
            if w.fd_b >= 0 {
                w.watch(w.fd_b, EPOLL_CTL_ADD, EPOLLIN, TAG_LISTEN_B);
            }
        }
        w
    }

    #[cfg(target_os = "linux")]
    #[inline]
    fn watch(&self, fd: c_int, op: c_int, events: u32, tag: u64) {
        let mut ev = epoll_event {
            events,
            u64_data: tag,
        };
        unsafe {
            let _ = epoll_ctl(self.epfd, op, fd, &mut ev);
        }
    }

    #[inline]
    fn client_tag(&self, idx: u32) -> u64 {
        ((self.clients[idx as usize].generation as u64) << 32) | (idx as u64)
    }

    #[inline]
    fn resolve_tag(&self, tag: u64) -> Option<u32> {
        let idx = (tag & 0xFFFF_FFFF) as usize;
        let generation = (tag >> 32) as u32;
        if idx < self.clients.len() && self.clients[idx].generation == generation {
            Some(idx as u32)
        } else {
            None
        }
    }

    fn alloc_client(&mut self, fd: c_int) -> u32 {
        let idx = if let Some(free_idx) = self.free_head {
            let c = &mut self.clients[free_idx as usize];
            self.free_head = c.next_free;
            c.next_free = None;
            free_idx
        } else {
            let new_idx = self.clients.len() as u32;
            self.clients.push(Client::new());
            new_idx
        };
        let c = &mut self.clients[idx as usize];
        c.fd = fd;
        c.job = Job::None;
        c.close_after = false;
        c.closed = false;
        c.continue_sent = false;
        c.watching_out = false;
        c.nparams = 0;
        c.viewer = 0;
        c.recv_ms = self.now_ms;
        c.input.clear();
        c.output.clear();
        c.params.clear();
        c.token.clear();
        c.stash.clear();
        idx
    }

    fn client_close(&mut self, idx: u32) {
        let c = &mut self.clients[idx as usize];
        if c.closed {
            return;
        }
        if c.fd >= 0 {
            unsafe {
                close(c.fd);
            }
            c.fd = -1;
        }
        c.closed = true;
    }

    fn client_release(&mut self, idx: u32) {
        let c = &mut self.clients[idx as usize];
        if c.closed && c.job == Job::None {
            c.generation = c.generation.wrapping_add(1).max(1);
            c.input.clear();
            c.output.clear();
            c.params.clear();
            c.token.clear();
            c.stash.clear();
            c.next_free = self.free_head;
            self.free_head = Some(idx);
        }
    }

    fn client_send(&mut self, idx: u32, mut data: &[u8]) {
        if self.clients[idx as usize].closed {
            return;
        }
        if self.clients[idx as usize].output.is_empty() {
            let fd = self.clients[idx as usize].fd;
            let w = unsafe { send(fd, data.as_ptr().cast(), data.len(), MSG_NOSIGNAL) };
            if w == data.len() as isize {
                return;
            }
            if w < 0 {
                let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if err != EAGAIN && err != EINTR {
                    self.client_close(idx);
                    return;
                }
            } else if w > 0 {
                data = &data[w as usize..];
            }
        }
        self.clients[idx as usize].output.extend_from_slice(data);
        #[cfg(target_os = "linux")]
        if !self.clients[idx as usize].watching_out {
            self.clients[idx as usize].watching_out = true;
            let fd = self.clients[idx as usize].fd;
            let tag = self.client_tag(idx);
            self.watch(fd, EPOLL_CTL_MOD, EPOLLIN | EPOLLOUT, tag);
        }
    }

    fn finish_send_check(&mut self, idx: u32) {
        let c = &self.clients[idx as usize];
        if c.close_after && c.output.is_empty() {
            self.client_close(idx);
        } else if self.quickack_ms > 0
            && self.now_ms - c.recv_ms > self.quickack_ms
            && !c.closed
        {
            disable_quickack(c.fd);
        }
    }

    fn respond_error(&mut self, idx: u32, status: i32, message: &str) {
        let close_after = self.clients[idx as usize].close_after;
        let mut resp = std::mem::take(&mut self.out_buf);
        build_http_error(&mut resp, status, close_after, message);
        self.client_send(idx, &resp);
        self.out_buf = resp;
        self.finish_send_check(idx);
    }

    fn start_job(&mut self, idx: u32, job: Job) {
        let tag = self.client_tag(idx);
        let c = &mut self.clients[idx as usize];
        c.job = job;
        let token = if job == Job::UserGet {
            self.cur_token.clone()
        } else if job == Job::UserUpdate {
            if c.token.is_empty() {
                self.cur_token.clone()
            } else {
                std::mem::take(&mut c.token)
            }
        } else {
            Vec::new()
        };
        let task = DbTask {
            worker_id: self.worker_id,
            client_tag: tag,
            job,
            close_after: c.close_after,
            viewer: c.viewer,
            nparams: c.nparams,
            params: std::mem::take(&mut c.params),
            token,
        };
        self.pending_db_tasks.push(task);
    }

    fn bcrypt_request(&mut self, idx: u32, verify: bool, password: &[u8], hash: &[u8]) {
        let tag = self.client_tag(idx);
        let c = &mut self.clients[idx as usize];
        if verify {
            c.job = Job::BcLogin;
        } else if c.job == Job::None {
            c.job = Job::BcRegister;
        }
        let mut pw = [0u8; 72];
        let plen = password.len().min(72);
        pw[..plen].copy_from_slice(&password[..plen]);

        let mut hbuf = [0u8; 64];
        let hlen = hash.len().min(64);
        hbuf[..hlen].copy_from_slice(&hash[..hlen]);

        self.bcrypt_pool.submit(BcryptTask {
            worker_id: self.worker_id,
            client_tag: tag,
            verify,
            password: pw,
            password_len: plen,
            hash: hbuf,
            hash_len: hlen,
        });
    }

    fn viewer_of(&mut self, _idx: u32, auth: Option<&[u8]>) -> i64 {
        let Some(a) = auth else {
            return 0;
        };
        if !a.starts_with(b"Token ") {
            return -1;
        }
        let tok = &a[6..];
        let id = self.jwt_key.verify(tok, self.now);
        if id <= 0 {
            return -1;
        }
        self.cur_token.clear();
        self.cur_token.extend_from_slice(tok);
        id
    }

    fn register(&mut self, idx: u32, body: &[u8]) {
        let Some(obj) = json::body_object(body, b"user") else {
            self.respond_error(idx, 422, "username, email and password are required");
            return;
        };
        if !json::required(obj, b"username", &mut self.f1)
            || !json::required(obj, b"email", &mut self.f2)
            || !json::required(obj, b"password", &mut self.f3)
        {
            self.respond_error(idx, 422, "username, email and password are required");
            return;
        }
        if self.f3.len() > 72 {
            self.respond_error(idx, 422, "password must be at most 72 bytes");
            return;
        }
        let c = &mut self.clients[idx as usize];
        c.params_reset();
        c.param_text(&self.f1);
        c.param_text(&self.f2);
        c.job = Job::BcRegister;
        let pw = self.f3.clone();
        self.bcrypt_request(idx, false, &pw, &[]);
    }

    fn login(&mut self, idx: u32, body: &[u8]) {
        let Some(obj) = json::body_object(body, b"user") else {
            self.respond_error(idx, 422, "email and password are required");
            return;
        };
        if !json::required(obj, b"email", &mut self.f1)
            || !json::required(obj, b"password", &mut self.f2)
        {
            self.respond_error(idx, 422, "email and password are required");
            return;
        }
        let c = &mut self.clients[idx as usize];
        c.stash.clear();
        c.stash.extend_from_slice(&self.f2);
        c.params_reset();
        c.param_text(&self.f1);
        self.start_job(idx, Job::Login);
    }

    fn update_user(&mut self, idx: u32, body: &[u8]) {
        let Some(obj) = json::body_object(body, b"user") else {
            self.respond_error(idx, 422, "user is required");
            return;
        };
        let email = json::obj_field(obj, b"email", &mut self.f1);
        let username = json::obj_field(obj, b"username", &mut self.f2);
        let bio = json::obj_field(obj, b"bio", &mut self.f3);
        let image = json::obj_field(obj, b"image", &mut self.f4);
        let password = json::obj_field(obj, b"password", &mut self.f5);
        if email < 0
            || username < 0
            || bio < 0
            || image < 0
            || password < 0
            || (email == 1 && self.f1.is_empty())
            || (username == 1 && self.f2.is_empty())
            || (password == 1 && (self.f5.is_empty() || self.f5.len() > 72))
        {
            self.respond_error(idx, 422, "invalid user fields");
            return;
        }
        let c = &mut self.clients[idx as usize];
        let viewer = c.viewer;
        c.params_reset();
        c.param_int(viewer);
        if email == 1 {
            c.param_text(&self.f1);
        } else {
            c.param_null();
        }
        if username == 1 {
            c.param_text(&self.f2);
        } else {
            c.param_null();
        }
        if bio == 1 {
            c.param_text(&self.f3);
        } else {
            c.param_null();
        }
        if image == 1 {
            c.param_text(&self.f4);
        } else {
            c.param_null();
        }
        if password == 1 {
            c.token.clear();
            c.token.extend_from_slice(&self.cur_token);
            c.job = Job::BcUpdate;
            let pw = self.f5.clone();
            self.bcrypt_request(idx, false, &pw, &[]);
        } else {
            c.param_null();
            self.start_job(idx, Job::UserUpdate);
        }
    }

    fn create_article(&mut self, idx: u32, body: &[u8]) {
        let Some(obj) = json::body_object(body, b"article") else {
            self.respond_error(idx, 422, "title, description and body are required");
            return;
        };
        if !json::required(obj, b"title", &mut self.f1)
            || !json::required(obj, b"description", &mut self.f2)
            || !json::required(obj, b"body", &mut self.f3)
        {
            self.respond_error(idx, 422, "title, description and body are required");
            return;
        }
        self.f4.clear();
        self.f4.push(b'[');
        if let Some((ts, te)) = json::find(obj, b"tagList") {
            if obj[ts] != b'n' {
                if obj[ts] != b'[' {
                    self.respond_error(idx, 422, "tagList must be an array of strings");
                    return;
                }
                let mut i = ts + 1;
                let mut first = true;
                while let Some((es, ee)) = json::next_element(obj, i, te) {
                    self.f5.clear();
                    if json::decode_string(obj, es, ee, &mut self.f5) != Some(ee)
                        || self.f5.is_empty()
                    {
                        self.respond_error(
                            idx,
                            422,
                            "tagList must be an array of non-empty strings",
                        );
                        return;
                    }
                    if !first {
                        self.f4.push(b',');
                    }
                    first = false;
                    put_json_string(&mut self.f4, &self.f5);
                    i = ee;
                }
            }
        }
        self.f4.push(b']');
        let c = &mut self.clients[idx as usize];
        let viewer = c.viewer;
        c.params_reset();
        c.param_int(viewer);
        c.param_text(&self.f1);
        c.param_text(&self.f2);
        c.param_text(&self.f3);
        c.param_text(&self.f4);
        self.start_job(idx, Job::ArticleCreate);
    }

    fn update_article(&mut self, idx: u32, body: &[u8]) {
        let Some(obj) = json::body_object(body, b"article") else {
            self.respond_error(idx, 422, "article is required");
            return;
        };
        let title = json::obj_field(obj, b"title", &mut self.f1);
        let description = json::obj_field(obj, b"description", &mut self.f2);
        let text = json::obj_field(obj, b"body", &mut self.f3);
        if title < 0
            || description < 0
            || text < 0
            || (title == 1 && self.f1.is_empty())
            || (description == 1 && self.f2.is_empty())
            || (text == 1 && self.f3.is_empty())
        {
            self.respond_error(idx, 422, "invalid article fields");
            return;
        }
        let c = &mut self.clients[idx as usize];
        let viewer = c.viewer;
        c.params_reset();
        c.param_text(&self.slug_buf);
        if title == 1 {
            c.param_text(&self.f1);
        } else {
            c.param_null();
        }
        if description == 1 {
            c.param_text(&self.f2);
        } else {
            c.param_null();
        }
        if text == 1 {
            c.param_text(&self.f3);
        } else {
            c.param_null();
        }
        c.param_int(viewer);
        self.start_job(idx, Job::ArticleUpdate);
    }

    fn add_comment(&mut self, idx: u32, body: &[u8]) {
        let Some(obj) = json::body_object(body, b"comment") else {
            self.respond_error(idx, 422, "body is required");
            return;
        };
        if !json::required(obj, b"body", &mut self.f1) {
            self.respond_error(idx, 422, "body is required");
            return;
        }
        let c = &mut self.clients[idx as usize];
        let viewer = c.viewer;
        c.params_reset();
        c.param_text(&self.slug_buf);
        c.param_int(viewer);
        c.param_text(&self.f1);
        self.start_job(idx, Job::CommentAdd);
    }

    fn list_articles(&mut self, idx: u32, query: &[u8], feed: bool) {
        let q = parse_query(query, &mut self.scratch2);
        if !q.ok {
            self.respond_error(idx, 422, "limit must be 1-100 and offset at least 0");
            return;
        }
        let c = &mut self.clients[idx as usize];
        let viewer = c.viewer;
        c.params_reset();
        c.param_int(viewer);
        c.param_int(q.limit);
        c.param_int(q.offset);
        if feed {
            self.start_job(idx, Job::Feed);
        } else if q.filter == 0 {
            self.start_job(idx, Job::ListGlobal);
        } else {
            url_decode(q.value, true, &mut self.scratch);
            self.clients[idx as usize].param_text(&self.scratch);
            let job = match q.filter {
                1 => Job::ListTag,
                2 => Job::ListAuthor,
                _ => Job::ListFavorited,
            };
            self.start_job(idx, job);
        }
    }

    fn route(
        &mut self,
        idx: u32,
        method: &[u8],
        path: &[u8],
        query: &[u8],
        auth: Option<&[u8]>,
        req_body: &[u8],
    ) {
        let get = method == b"GET";
        let post = method == b"POST";
        let put = method == b"PUT";
        let delete = method == b"DELETE";
        let Some(rest) = path.strip_prefix(b"/api/") else {
            self.respond_error(idx, 404, "not found");
            return;
        };

        if rest == b"tags" && get {
            self.clients[idx as usize].params_reset();
            self.start_job(idx, Job::Tags);
            return;
        } else if rest == b"users" && post {
            self.register(idx, req_body);
            return;
        } else if rest == b"users/login" && post {
            self.login(idx, req_body);
            return;
        }

        let viewer = self.viewer_of(idx, auth);
        if viewer < 0 {
            self.respond_error(idx, 401, "invalid token");
            return;
        }
        self.clients[idx as usize].viewer = viewer;

        if rest == b"user" && (get || put) {
            if viewer == 0 {
                self.respond_error(idx, 401, "token required");
                return;
            }
            if get {
                let c = &mut self.clients[idx as usize];
                c.params_reset();
                c.param_int(viewer);
                self.start_job(idx, Job::UserGet);
            } else {
                self.update_user(idx, req_body);
            }
            return;
        }

        if let Some(seg) = rest.strip_prefix(b"profiles/") {
            let mut slash = 0usize;
            while slash < seg.len() && seg[slash] != b'/' {
                slash += 1;
            }
            let mut follow = false;
            if slash < seg.len() {
                if &seg[slash..] != b"/follow" {
                    self.respond_error(idx, 404, "not found");
                    return;
                }
                follow = true;
            }
            if slash == 0 {
                self.respond_error(idx, 404, "not found");
                return;
            }
            url_decode(&seg[..slash], false, &mut self.scratch);
            if !follow && get {
                let c = &mut self.clients[idx as usize];
                c.params_reset();
                c.param_int(viewer);
                c.param_text(&self.scratch);
                self.start_job(idx, Job::Profile);
                return;
            } else if follow && (post || delete) {
                if viewer == 0 {
                    self.respond_error(idx, 401, "token required");
                    return;
                }
                let c = &mut self.clients[idx as usize];
                c.params_reset();
                c.param_int(viewer);
                c.param_text(&self.scratch);
                self.start_job(idx, if post { Job::Follow } else { Job::Unfollow });
                return;
            }
            self.respond_error(idx, 404, "not found");
            return;
        }

        if rest == b"articles" {
            if get {
                self.list_articles(idx, query, false);
                return;
            } else if post {
                if viewer == 0 {
                    self.respond_error(idx, 401, "token required");
                    return;
                }
                self.create_article(idx, req_body);
                return;
            }
        } else if rest == b"articles/feed" && get {
            if viewer == 0 {
                self.respond_error(idx, 401, "token required");
                return;
            }
            self.list_articles(idx, query, true);
            return;
        } else if let Some(seg) = rest.strip_prefix(b"articles/") {
            let mut slash = 0usize;
            while slash < seg.len() && seg[slash] != b'/' {
                slash += 1;
            }
            if slash == 0 {
                self.respond_error(idx, 404, "not found");
                return;
            }
            url_decode(&seg[..slash], false, &mut self.slug_buf);
            let tail = &seg[slash..];
            if tail.is_empty() {
                if get {
                    let c = &mut self.clients[idx as usize];
                    c.params_reset();
                    c.param_int(viewer);
                    c.param_text(&self.slug_buf);
                    self.start_job(idx, Job::Article);
                    return;
                } else if put || delete {
                    if viewer == 0 {
                        self.respond_error(idx, 401, "token required");
                        return;
                    }
                    if put {
                        self.update_article(idx, req_body);
                    } else {
                        let c = &mut self.clients[idx as usize];
                        c.params_reset();
                        c.param_text(&self.slug_buf);
                        c.param_int(viewer);
                        self.start_job(idx, Job::ArticleDelete);
                    }
                    return;
                }
            } else if tail == b"/favorite" && (post || delete) {
                if viewer == 0 {
                    self.respond_error(idx, 401, "token required");
                    return;
                }
                let c = &mut self.clients[idx as usize];
                c.params_reset();
                c.param_int(viewer);
                c.param_text(&self.slug_buf);
                self.start_job(idx, if post { Job::Favorite } else { Job::Unfavorite });
                return;
            } else if tail == b"/comments" && (get || post) {
                if get {
                    let c = &mut self.clients[idx as usize];
                    c.params_reset();
                    c.param_int(viewer);
                    c.param_text(&self.slug_buf);
                    self.start_job(idx, Job::Comments);
                } else {
                    if viewer == 0 {
                        self.respond_error(idx, 401, "token required");
                        return;
                    }
                    self.add_comment(idx, req_body);
                }
                return;
            } else if let Some(cid_bytes) = tail.strip_prefix(b"/comments/") {
                if delete {
                    if viewer == 0 {
                        self.respond_error(idx, 401, "token required");
                        return;
                    }
                    let id = parse_id(cid_bytes);
                    if id < 0 {
                        self.respond_error(idx, 404, "comment not found");
                        return;
                    }
                    let c = &mut self.clients[idx as usize];
                    c.params_reset();
                    c.param_int(id);
                    c.param_text(&self.slug_buf);
                    c.param_int(viewer);
                    self.start_job(idx, Job::CommentDelete);
                    return;
                }
            }
        }
        self.respond_error(idx, 404, "not found");
    }

    fn handle_request(&mut self, idx: u32, p: &[u8]) -> usize {
        let Some(head) = header_end(p) else {
            if p.len() > 65536 {
                self.client_close(idx);
            }
            return 0;
        };

        let mut i = 0usize;
        while i < head && p[i] != b' ' && p[i] != b'\r' {
            i += 1;
        }
        let method = &p[..i];
        let path_start = (i + 1).min(head);
        i = path_start;
        while i < head && p[i] != b' ' && p[i] != b'?' && p[i] != b'\r' {
            i += 1;
        }
        let path = &p[path_start..i];
        let mut query: &[u8] = &[];
        if i < head && p[i] == b'?' {
            let q_start = i + 1;
            i = q_start;
            while i < head && p[i] != b' ' && p[i] != b'\r' {
                i += 1;
            }
            query = &p[q_start..i];
        }
        let http10 = i < head && p[i] == b' ' && p[i + 1..head].starts_with(b"HTTP/1.0");
        while i < head && p[i] != b'\n' {
            i += 1;
        }
        i += 1;

        let mut content_length: isize = 0;
        let mut auth: Option<&[u8]> = None;
        let mut close_requested = false;
        let mut keep_alive = false;
        let mut expect_continue = false;

        while i + 2 <= head {
            let line = i;
            while i < head && p[i] != b'\r' {
                i += 1;
            }
            let line_stop = i;
            i += 2;
            let mut colon = line;
            while colon < line_stop && p[colon] != b':' {
                colon += 1;
            }
            if colon < line_stop {
                let name = &p[line..colon];
                let mut v = colon + 1;
                while v < line_stop && (p[v] == b' ' || p[v] == b'\t') {
                    v += 1;
                }
                let mut v_stop = line_stop;
                while v_stop > v && (p[v_stop - 1] == b' ' || p[v_stop - 1] == b'\t') {
                    v_stop -= 1;
                }
                let value = &p[v..v_stop];
                if ieq(name, b"content-length") {
                    content_length = parse_length(value);
                } else if ieq(name, b"authorization") {
                    auth = Some(value);
                } else if ieq(name, b"connection") {
                    close_requested = contains_subslice(value, b"close");
                    keep_alive = contains_subslice(value, b"keep-alive");
                } else if ieq(name, b"expect") {
                    expect_continue = ieq(value, b"100-continue");
                } else if ieq(name, b"transfer-encoding") {
                    content_length = -1;
                }
            }
        }

        if content_length < 0 || content_length > 1_048_576 {
            self.clients[idx as usize].close_after = true;
            self.respond_error(idx, 422, "bad request");
            return p.len();
        }
        let total = head + (content_length as usize);
        if p.len() < total {
            if expect_continue && !self.clients[idx as usize].continue_sent {
                self.clients[idx as usize].continue_sent = true;
                self.client_send(idx, CONTINUE_RESP);
            }
            return 0;
        }
        self.clients[idx as usize].continue_sent = false;
        self.clients[idx as usize].close_after = close_requested || (http10 && !keep_alive);
        self.route(idx, method, path, query, auth, &p[head..total]);
        if self.clients[idx as usize].job == Job::None {
            self.clients[idx as usize].stash.clear();
        }
        total
    }

    fn handle_requests(&mut self, idx: u32, p: &[u8]) -> usize {
        let mut used = 0usize;
        while used < p.len() {
            let c = &self.clients[idx as usize];
            if c.closed || c.job != Job::None || !c.output.is_empty() {
                break;
            }
            let r = self.handle_request(idx, &p[used..]);
            if r == 0 {
                break;
            }
            used += r;
        }
        used
    }

    fn client_resume(&mut self, idx: u32) {
        let c = &self.clients[idx as usize];
        if c.closed || c.job != Job::None || !c.output.is_empty() || c.input.is_empty() {
            return;
        }
        let input = std::mem::take(&mut self.clients[idx as usize].input);
        let used = self.handle_requests(idx, &input);
        if !self.clients[idx as usize].closed && used < input.len() {
            self.clients[idx as usize]
                .input
                .extend_from_slice(&input[used..]);
        }
    }

    fn client_readable(&mut self, idx: u32, readbuf: &mut [u8; 65536]) {
        let fd = self.clients[idx as usize].fd;
        if fd < 0 {
            return;
        }
        let n = unsafe { recv(fd, readbuf.as_mut_ptr().cast(), readbuf.len(), 0) };
        if n <= 0 {
            if n < 0 {
                let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if err == EAGAIN || err == EINTR {
                    return;
                }
            }
            self.client_close(idx);
            return;
        }
        let got = n as usize;
        self.clients[idx as usize].recv_ms = self.now_ms;

        if self.clients[idx as usize].input.is_empty()
            && self.clients[idx as usize].job == Job::None
            && self.clients[idx as usize].output.is_empty()
        {
            let used = self.handle_requests(idx, &readbuf[..got]);
            if !self.clients[idx as usize].closed && used < got {
                self.clients[idx as usize]
                    .input
                    .extend_from_slice(&readbuf[used..got]);
            }
        } else if self.clients[idx as usize].input.len() + got > 2 * 1_048_576 {
            self.client_close(idx);
        } else {
            self.clients[idx as usize]
                .input
                .extend_from_slice(&readbuf[..got]);
            self.client_resume(idx);
        }
    }

    fn client_writable(&mut self, idx: u32) {
        if !self.clients[idx as usize].output.is_empty() {
            let fd = self.clients[idx as usize].fd;
            let w = unsafe {
                send(
                    fd,
                    self.clients[idx as usize].output.as_ptr().cast(),
                    self.clients[idx as usize].output.len(),
                    MSG_NOSIGNAL,
                )
            };
            if w < 0 {
                let err = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                if err != EAGAIN && err != EINTR {
                    self.client_close(idx);
                }
                return;
            }
            if w > 0 {
                self.clients[idx as usize].output.drain(..w as usize);
            }
            if !self.clients[idx as usize].output.is_empty() {
                return;
            }
        }
        #[cfg(target_os = "linux")]
        if self.clients[idx as usize].watching_out {
            self.clients[idx as usize].watching_out = false;
            let fd = self.clients[idx as usize].fd;
            let tag = self.client_tag(idx);
            self.watch(fd, EPOLL_CTL_MOD, EPOLLIN, tag);
        }
        if self.clients[idx as usize].close_after && self.clients[idx as usize].job == Job::None {
            self.client_close(idx);
        } else {
            self.client_resume(idx);
        }
    }

    #[cfg(target_os = "linux")]
    fn accept_clients(&mut self, listener_fd: c_int) {
        loop {
            let fd = unsafe {
                accept4(
                    listener_fd,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    SOCK_NONBLOCK | SOCK_CLOEXEC,
                )
            };
            if fd < 0 {
                return;
            }
            set_tcp_nodelay(fd);
            let idx = self.alloc_client(fd);
            let tag = self.client_tag(idx);
            self.watch(fd, EPOLL_CTL_ADD, EPOLLIN, tag);
        }
    }

    fn handle_inbox_msg(&mut self, msg: WorkerMsg) {
        match msg {
            WorkerMsg::Http {
                client_tag,
                response,
            } => {
                let Some(idx) = self.resolve_tag(client_tag) else {
                    return;
                };
                self.clients[idx as usize].job = Job::None;
                self.clients[idx as usize].stash.clear();
                if !self.clients[idx as usize].closed {
                    self.client_send(idx, &response);
                    self.finish_send_check(idx);
                }
                self.client_resume(idx);
                self.client_release(idx);
            }
            WorkerMsg::LoginRow {
                client_tag,
                user_id,
                password_hash,
                user_prefix,
                user_suffix,
            } => {
                let Some(idx) = self.resolve_tag(client_tag) else {
                    return;
                };
                let c = &mut self.clients[idx as usize];
                if c.closed {
                    c.job = Job::None;
                    c.stash.clear();
                    self.client_release(idx);
                    return;
                }
                c.viewer = user_id;
                c.login_prefix = user_prefix;
                c.login_suffix = user_suffix;
                let pw = c.stash.clone();
                self.bcrypt_request(idx, true, &pw, &password_hash);
            }
            WorkerMsg::BcryptDone {
                client_tag,
                ok,
                hash,
            } => {
                let Some(idx) = self.resolve_tag(client_tag) else {
                    return;
                };
                let job = self.clients[idx as usize].job;
                self.clients[idx as usize].job = Job::None;
                if self.clients[idx as usize].closed {
                    self.clients[idx as usize].stash.clear();
                    self.client_release(idx);
                    return;
                }
                if job == Job::BcLogin {
                    self.clients[idx as usize].stash.clear();
                    if !ok {
                        self.respond_error(idx, 401, "email or password is invalid");
                    } else {
                        let viewer = self.clients[idx as usize].viewer;
                        let close_after = self.clients[idx as usize].close_after;
                        let mut tok = Vec::with_capacity(160);
                        self.jwt_key.sign(viewer, self.now, &mut tok);
                        let mut body = Vec::with_capacity(
                            self.clients[idx as usize].login_prefix.len()
                                + tok.len()
                                + self.clients[idx as usize].login_suffix.len(),
                        );
                        body.extend_from_slice(&self.clients[idx as usize].login_prefix);
                        body.extend_from_slice(&tok);
                        body.extend_from_slice(&self.clients[idx as usize].login_suffix);
                        let mut resp = std::mem::take(&mut self.out_buf);
                        build_http_response(&mut resp, 200, close_after, &body);
                        self.client_send(idx, &resp);
                        self.out_buf = resp;
                        self.finish_send_check(idx);
                    }
                } else if job == Job::BcRegister || job == Job::BcUpdate {
                    self.clients[idx as usize].stash.clear();
                    if !ok {
                        self.respond_error(idx, 500, "internal server error");
                    } else {
                        self.clients[idx as usize].param_text(&hash);
                        let next_job = if job == Job::BcRegister {
                            Job::Register
                        } else {
                            Job::UserUpdate
                        };
                        self.start_job(idx, next_job);
                        return;
                    }
                }
                self.client_resume(idx);
                self.client_release(idx);
            }
        }
    }

    #[cfg(target_os = "linux")]
    pub fn run(&mut self) {
        let mut events = [epoll_event::default(); 1024];
        let mut readbuf = [0u8; 65536];
        let mut msgs = Vec::with_capacity(256);

        loop {
            let k = unsafe { epoll_wait(self.epfd, events.as_mut_ptr(), 1024, -1) };
            self.now = unix_now();
            self.now_ms = clock_ms();
            let mut link_busy = false;

            if k > 0 {
                for ev in &events[..k as usize] {
                    let tag = ev.u64_data;
                    let mask = ev.events;
                    if tag == TAG_LISTEN_A {
                        self.accept_clients(self.fd_a);
                    } else if tag == TAG_LISTEN_B {
                        self.accept_clients(self.fd_b);
                    } else if tag == TAG_WAKE {
                        link_busy = true;
                        drain_eventfd(self.inbox.event_fd);
                        {
                            let mut q = self.inbox.queue.lock().unwrap();
                            std::mem::swap(&mut *q, &mut msgs);
                        }
                        for msg in msgs.drain(..) {
                            self.handle_inbox_msg(msg);
                        }
                    } else if let Some(idx) = self.resolve_tag(tag) {
                        if !self.clients[idx as usize].closed {
                            if mask & EPOLLOUT != 0 {
                                self.client_writable(idx);
                            }
                            if !self.clients[idx as usize].closed && (mask & !EPOLLOUT) != 0 {
                                self.client_readable(idx, &mut readbuf);
                            }
                            self.client_release(idx);
                        }
                    }
                }
            }

            if !self.pending_db_tasks.is_empty() {
                let should_wake = {
                    let mut q = self.db_inbox.queue.lock().unwrap();
                    let was_empty = q.is_empty();
                    if was_empty {
                        std::mem::swap(&mut *q, &mut self.pending_db_tasks);
                    } else {
                        q.append(&mut self.pending_db_tasks);
                    }
                    was_empty
                };
                if should_wake {
                    wake_eventfd(self.db_inbox.event_fd);
                }
            }

            if k > 0 && k < 32 && self.batch_us > 0 && !link_busy {
                let ts = timespec {
                    tv_sec: 0,
                    tv_nsec: (self.batch_us as i64 * 1000) as _,
                };
                unsafe {
                    let _ = nanosleep(&ts, std::ptr::null_mut());
                }
            }
        }
    }
}
