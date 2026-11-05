//! One execution for compatible concurrent reads, with no data retained afterward.
use bytes::{Bytes, BytesMut};
use tokio_postgres::{Row, Statement, types::Type};

use std::collections::HashMap;

use crate::{db::Stmts, sql, writer::Error};

pub struct Batch {
    pub original: Statement,
    pub statement: Statement,
    pub shared: Option<Statement>,
    pub broadcast: bool,
    /// Largest percentage of distinct non-viewer keys at which a batch still uses `shared`.
    pub share_pct: usize,
    /// Order the app restores within each request's rows; the batched SQL then has no final ORDER BY.
    pub sort: RowSort,
    /// Row shape of `shared`.
    pub pack: Pack,
}

/// Result shape of a shared statement. Packed results carry each distinct article (or comment) once, routed with
/// `__request_id` 0, plus one header row per request with its count, its page ids in order and the viewer's flag
/// ids; `demux` hands each request its header followed by its own rows, so nothing is sent twice by Postgres.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Pack {
    /// One full row per (request, article): every column of the original statement.
    No,
    /// `LIST_PACKED_COLS` columns: article rows, then headers (n, ..., ids, favorited ids, followed ids).
    List,
    /// `COMMENTS_PACKED_COLS` columns: comment rows, then headers (article id, ..., followed ids).
    Comments,
    /// `ARTICLE_PACKED_COLS` columns: article rows, then headers (article id, ..., favorited, ..., following).
    Article,
}

/// Columns of a packed list result: n, the 13 article columns (flags NULL), author_id, ids, favs, fols, request id.
pub const LIST_PACKED_COLS: usize = 19;
/// Columns of a packed comments result: aid, 8 comment columns (flag NULL), author_id, fols, request id.
pub const COMMENTS_PACKED_COLS: usize = 12;
/// Columns of a packed article result: the 14 article columns (flags NULL), author_id, request id.
pub const ARTICLE_PACKED_COLS: usize = 16;

/// Within-request row order of a batched read. A final ORDER BY over a whole batch sorts every wide
/// row (bodies, bios, tag arrays) in Postgres; the rows already arrive grouped by request, and each
/// request has at most 100 rows, so the app sorts them by key instead (`READ_APP_SORT=0` keeps SQL order).
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum RowSort {
    /// The batched SQL orders its rows.
    Sql,
    /// Lists: article id (column 1) descending.
    IdDesc,
    /// Comments: created_at (column 3) then comment id (column 1), both descending.
    CommentsDesc,
}

/// An int8 or timestamptz column (NULL = None) as its raw 8-byte value: both order as signed integers.
fn key(r: &Row, i: usize) -> Result<Option<i64>, Error> {
    if i >= r.len() {
        return Err(Error::Rows);
    }
    match r.raw(i) {
        None => Ok(None),
        Some(raw) => Ok(Some(i64::from_be_bytes(
            raw.try_into().map_err(|_| Error::Rows)?,
        ))),
    }
}

/// A non-NULL int8 column.
fn int(r: &Row, i: usize) -> Result<i64, Error> {
    key(r, i)?.ok_or(Error::Rows)
}

impl RowSort {
    pub fn apply(self, rows: &mut [Row]) -> Result<(), Error> {
        if rows.len() < 2 {
            return Ok(());
        }
        let mut keyed = Vec::with_capacity(rows.len());
        for (i, r) in rows.iter().enumerate() {
            let k = match self {
                RowSort::Sql => return Ok(()),
                RowSort::IdDesc => (key(r, 1)?, None),
                RowSort::CommentsDesc => (key(r, 3)?, key(r, 1)?),
            };
            keyed.push((std::cmp::Reverse(k), i));
        }
        if keyed.is_sorted() {
            return Ok(());
        }
        keyed.sort_unstable();
        permute(rows, keyed.into_iter().map(|(_, i)| i).collect());
        Ok(())
    }
}

/// Reorders `v` so that `v[k]` becomes the old `v[order[k]]`, in place by following cycles.
fn permute<T>(v: &mut [T], mut order: Vec<usize>) {
    for start in 0..order.len() {
        let mut at = start;
        while order[at] != start {
            let next = order[at];
            v.swap(at, next);
            order[at] = at;
            at = next;
        }
        order[at] = at;
    }
}

/// READ_PACK=0 keeps one full row per (request, article) in shared lists and comments.
fn packed() -> bool {
    std::env::var("READ_PACK").ok().as_deref() != Some("0")
}

fn app_sort() -> bool {
    std::env::var("READ_APP_SORT").ok().as_deref() != Some("0")
}

/// Batched forms of each read family, in `Stmts::reads()` order (None = executed one request at a time).
pub async fn prepare(
    client: &tokio_postgres::Client,
    st: &Stmts,
) -> Result<Vec<Option<Batch>>, tokio_postgres::Error> {
    let mut batches = Vec::new();
    for (i, original) in st.reads().into_iter().enumerate() {
        let (text, ordered) = match i {
            0 => (sql::LIST_ALL, true),
            1 => (sql::LIST_TAG, true),
            2 => (sql::LIST_AUTHOR, true),
            3 => (sql::LIST_FAVORITED, true),
            4 => (sql::LIST_FEED, true),
            5 => (sql::ARTICLE_BY_SLUG, false),
            6 => (sql::ARTICLE_BY_ID, false),
            7 => (sql::PROFILE, false),
            8 => (sql::USER_BY_ID, false),
            9 => (sql::USER_BY_EMAIL, false),
            10 => (sql::COMMENTS_LIST_SET, false),
            11 => {
                // Only this argument-free, viewer-independent read may broadcast rows.
                // All recipients are already waiting in the same drained batch.
                batches.push(
                    (std::env::var("READ_TAG_BATCH").ok().as_deref() != Some("0")).then(|| Batch {
                        original: original.clone(),
                        statement: original.clone(),
                        shared: None,
                        broadcast: true,
                        share_pct: 0,
                        sort: RowSort::Sql,
                        pack: Pack::No,
                    }),
                );
                continue;
            }
            _ => {
                batches.push(None);
                continue;
            }
        };
        let mut types = Vec::new();
        let mut args = Vec::new();
        let mut names = Vec::new();
        for (i, ty) in original.params().iter().enumerate() {
            let (array, cast) = match *ty {
                Type::INT8 => (Type::INT8_ARRAY, "bigint[]"),
                Type::TEXT => (Type::TEXT_ARRAY, "text[]"),
                _ => unreachable!("only homogeneous scalar parameters"),
            };
            types.push(array);
            args.push(format!("${}::{cast}", i + 1));
            names.push(format!("p{}", i + 1));
        }
        // Replace complete parameter tokens, never substrings such as $1 in $10.
        let mut replaced = String::new();
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '$' {
                let mut digits = String::new();
                while chars.peek().is_some_and(char::is_ascii_digit) {
                    digits.push(chars.next().unwrap());
                }
                assert!(!digits.is_empty());
                replaced.push_str("r.p");
                replaced.push_str(&digits);
            } else {
                replaced.push(c);
            }
        }
        let mut query = format!(
            "SELECT q.*, r.ord::bigint AS __request_id FROM unnest({}) WITH ORDINALITY AS r({},ord) CROSS JOIN LATERAL ({replaced}) q",
            args.join(","),
            names.join(","),
        );
        // Explicitly preserve each original list's order after result demultiplexing.
        if ordered {
            query.push_str(" ORDER BY r.ord, q.id DESC");
        }
        match i {
            4 if feed_big() => query = FEED_BATCH_BIG.to_string(),
            4 => query = FEED_BATCH.to_string(),
            10 if followee_list() => query = COMMENTS_BATCH.to_string(),
            10 => query = COMMENTS_BATCH_EXISTS.to_string(),
            _ => {}
        }
        let sort = match i {
            _ if !app_sort() => RowSort::Sql,
            0..=4 => RowSort::IdDesc,
            10 => RowSort::CommentsDesc,
            _ => RowSort::Sql,
        };
        let pack = match i {
            _ if !packed() => Pack::No,
            0..=4 => Pack::List,
            5 => Pack::Article,
            10 => Pack::Comments,
            _ => Pack::No,
        };
        // Feed pages depend on the viewer, so equal pagination cannot establish overlap: only the packed
        // form (each article once) is shared, and then always.
        let shared = if text == sql::LIST_FEED {
            match pack {
                Pack::List if feed_big() => {
                    Some(client.prepare_typed(FEED_PACKED_BIG, &types).await?)
                }
                Pack::List => Some(client.prepare_typed(FEED_PACKED, &types).await?),
                _ => None,
            }
        } else if let Some(shared) = shared_list(text, &args, &names, pack)
            .or_else(|| shared_slug(text, &args, &names, pack))
        {
            // One article row per request needs no order: rows are routed by __request_id.
            let unordered =
                (sort != RowSort::Sql || text == sql::ARTICLE_BY_SLUG) && pack == Pack::No;
            let shared = if unordered {
                without_order(&shared)
            } else {
                shared
            };
            Some(client.prepare_typed(&shared, &types).await?)
        } else {
            None
        };
        if sort != RowSort::Sql {
            query = without_order(&query);
        }
        batches.push(Some(Batch {
            original: original.clone(),
            statement: client.prepare_typed(&query, &types).await?,
            shared,
            broadcast: false,
            // Lists share counts and article enrichment even across different pages, which beats
            // per-request evaluation at any duplicate rate; slug reads only share whole articles.
            share_pct: if i <= 4 {
                env_pct("READ_SHARE_LIST_PCT", 100)
            } else {
                env_pct("READ_SHARE_UNIQUE_PCT", 50)
            },
            sort,
            pack,
        }));
    }
    Ok(batches)
}

/// `query` without its final top-level ORDER BY clause.
fn without_order(query: &str) -> String {
    let (head, tail) = query.rsplit_once("ORDER BY").expect("ordered batch");
    assert!(!tail.contains(')'), "ORDER BY is not the final clause");
    head.trim_end().to_string()
}

/// Use sharing only when at least half the requests have duplicate non-viewer
/// arguments. Otherwise preserve the existing query without materialization.
pub fn statement<'a>(batch: &'a Batch, frames: &[&Bytes]) -> &'a Statement {
    match &batch.shared {
        Some(shared) if should_share(frames, batch.share_pct) => shared,
        _ => &batch.statement,
    }
}

/// Counting distinct keys by sorting them once, not by rescanning earlier frames for each frame (quadratic: a
/// 256-request batch parsed ~33k Bind frames on the database thread). At 100% every batch with valid frames
/// shares, so only the frames are checked.
fn should_share(frames: &[&Bytes], pct: usize) -> bool {
    if frames.len() < 2 {
        return false;
    }
    if pct >= 100 {
        return frames.iter().all(|f| non_viewer_key(f).is_some());
    }
    let mut keys = Vec::with_capacity(frames.len());
    for frame in frames {
        let Some(key) = non_viewer_key(frame) else {
            return false;
        };
        keys.push(key);
    }
    keys.sort_unstable();
    keys.dedup();
    keys.len() * 100 <= frames.len() * pct
}

/// A sharing threshold in percent of distinct keys from `var` (100 = always share).
fn env_pct(var: &str, default: usize) -> usize {
    std::env::var(var)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

// Bind frames already passed arrays() validation; keep bounds checks here too.
// Include limit, offset and any filter, excluding only the first (viewer) value.
fn non_viewer_key(frame: &[u8]) -> Option<&[u8]> {
    if frame.first() != Some(&b'B') {
        return None;
    }
    let end = 1usize.checked_add(u32::from_be_bytes(frame.get(1..5)?.try_into().ok()?) as usize)?;
    let mut at = 5;
    for _ in 0..2 {
        at += frame.get(at..end)?.iter().position(|b| *b == 0)? + 1;
    }
    let formats = u16::from_be_bytes(frame.get(at..at + 2)?.try_into().ok()?) as usize;
    at = at.checked_add(2 + formats * 2)?;
    let count = u16::from_be_bytes(frame.get(at..at + 2)?.try_into().ok()?);
    if count < 2 || frame.get(at + 2..at + 6)? != 8i32.to_be_bytes() {
        return None;
    }
    at += 14; // parameter count, first value length and its eight-byte viewer.
    frame.get(at..end)
}

/// Shared forms. Each distinct count, page and article is computed once per execution; the per-viewer flags are
/// still computed per request. Every request still reads PostgreSQL while it is being served (one statement, one
/// snapshot); no result is retained by the app.
fn shared_list(text: &str, args: &[String], names: &[String], pack: Pack) -> Option<String> {
    // (count over keys `r`, page over page keys `r`, filter column present)
    let (count, page, filtered) = if text == sql::LIST_ALL {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s",
            "SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2",
            false,
        )
    } else if text == sql::LIST_TAG {
        (
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) LIMIT 1000) s) END AS n",
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3",
            true,
        )
    } else if text == sql::LIST_AUTHOR && author_key() {
        // `r.uid` is the author's id, read once per key in `keys` (below) along with the author's profile.
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = r.uid LIMIT 1000) s",
            "SELECT a2.id FROM articles a2 WHERE a2.author_id = r.uid ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3",
            true,
        )
    } else if text == sql::LIST_AUTHOR {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) LIMIT 1000) s",
            "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3",
            true,
        )
    } else if text == sql::LIST_FAVORITED {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s",
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT r.p2 OFFSET r.p3",
            true,
        )
    } else {
        return None;
    };
    let author_key = text == sql::LIST_AUTHOR && author_key();
    let (keys, counted, join_count, page_cols, page_join) = if author_key {
        // Each distinct author is looked up by name once, with the profile its articles are shown with.
        (
            "keys AS MATERIALIZED (SELECT k.p4, u.id AS uid, u.username, u.bio, u.image
         FROM (SELECT DISTINCT p4 FROM requests) k LEFT JOIN users u ON u.username = k.p4),",
            format!(
                "counted AS MATERIALIZED (SELECT r.p4, c.n FROM keys r CROSS JOIN LATERAL ({count}) c),"
            ),
            "JOIN counted c ON c.p4 = q.p4",
            "r.p2, r.p3, r.p4, k.uid FROM (SELECT DISTINCT p2, p3, p4 FROM requests) r JOIN keys k ON k.p4 = r.p4",
            "p.p2 = q.p2 AND p.p3 = q.p3 AND p.p4 = q.p4",
        )
    } else if filtered {
        (
            "keys AS MATERIALIZED (SELECT DISTINCT p4 FROM requests),",
            format!(
                "counted AS MATERIALIZED (SELECT r.p4, c.n FROM keys r CROSS JOIN LATERAL ({count}) c),"
            ),
            "JOIN counted c ON c.p4 = q.p4",
            "DISTINCT p2, p3, p4 FROM requests",
            "p.p2 = q.p2 AND p.p3 = q.p3 AND p.p4 = q.p4",
        )
    } else {
        (
            "",
            format!("counted AS MATERIALIZED ({count}),"),
            "CROSS JOIN counted c",
            "DISTINCT p2, p3 FROM requests",
            "p.p2 = q.p2 AND p.p3 = q.p3",
        )
    };
    // The global list shares one id window, so each viewer's flags are two index range reads into arrays
    // (favorites by the pkey within the window, all followees) instead of a probe per (request, article).
    let select = if pack == Pack::List {
        // Per request: its page ids in order and the favorited / followed ones among them. The global list's
        // pages share one id window, so its flags are two index range reads per viewer (favorites within the
        // window, followees among the batch's authors); filtered lists spread over many ids and authors and
        // probe each (request, article) instead. The app tests each article against these short arrays.
        let flags = if text == sql::LIST_ALL {
            "array_agg(p.id ORDER BY p.id DESC) FILTER (WHERE p.id IS NOT NULL) AS ids,
         (SELECT ARRAY(SELECT f.article_id FROM favorites f, bounds b WHERE f.user_id = q.p1 AND f.article_id BETWEEN b.lo AND b.hi)) AS favs,
         (SELECT ARRAY(SELECT fo.followee_id FROM follows fo, bounds b WHERE fo.follower_id = q.p1 AND fo.followee_id = ANY(b.au))) AS fols"
        } else {
            "array_agg(p.id ORDER BY p.id DESC) FILTER (WHERE p.id IS NOT NULL) AS ids,
         array_agg(p.id) FILTER (WHERE EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = q.p1)) AS favs,
         array_agg(e.author_id) FILTER (WHERE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = e.author_id)) AS fols"
        };
        let fl = if text == sql::LIST_ALL && list_flags() {
            // Each page's ids are aggregated once, and each viewer's flags are read once for the whole batch
            // (one range read per distinct viewer, not per request).
            "pa AS MATERIALIZED (
         SELECT p2, p3, array_agg(id ORDER BY id DESC) FILTER (WHERE id IS NOT NULL) AS ids FROM pages GROUP BY p2, p3),
         vf AS MATERIALIZED (
         SELECT f.user_id, array_agg(f.article_id) AS ids FROM favorites f
         WHERE f.user_id = ANY(ARRAY(SELECT p1 FROM requests))
           AND f.article_id BETWEEN (SELECT lo FROM bounds) AND (SELECT hi FROM bounds) GROUP BY 1),
         vo AS MATERIALIZED (
         SELECT fo.follower_id, array_agg(fo.followee_id) AS ids FROM follows fo
         WHERE fo.follower_id = ANY(ARRAY(SELECT p1 FROM requests))
           AND fo.followee_id = ANY((SELECT au FROM bounds)::bigint[]) GROUP BY 1),
         fl AS MATERIALIZED (
         SELECT q.ord, pa.ids, vf.ids AS favs, vo.ids AS fols
         FROM requests q JOIN pa ON pa.p2 = q.p2 AND pa.p3 = q.p3
         LEFT JOIN vf ON vf.user_id = q.p1 LEFT JOIN vo ON vo.follower_id = q.p1)"
                .to_string()
        } else if text == sql::LIST_TAG && list_flags() {
            // One `= ANY(page ids)` / `= ANY(page authors)` index read per request instead of a probe per article.
            "fl0 AS MATERIALIZED (
         SELECT q.ord, q.p1, array_agg(p.id ORDER BY p.id DESC) FILTER (WHERE p.id IS NOT NULL) AS ids,
         array_agg(DISTINCT e.author_id) FILTER (WHERE e.author_id IS NOT NULL) AS au
         FROM requests q JOIN pages p ON p.p2 = q.p2 AND p.p3 = q.p3 AND p.p4 = q.p4
         LEFT JOIN enriched e ON e.id = p.id GROUP BY q.ord, q.p1),
         fl AS MATERIALIZED (
         SELECT ord, ids,
         ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = fl0.p1 AND f.article_id = ANY(fl0.ids)) AS favs,
         ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = fl0.p1 AND fo.followee_id = ANY(fl0.au)) AS fols
         FROM fl0)"
                .to_string()
        } else {
            format!(
                "fl AS MATERIALIZED (
         SELECT q.ord, {flags}
         FROM requests q JOIN pages p ON {page_join} LEFT JOIN enriched e ON e.id = p.id GROUP BY q.ord, q.p1)"
            )
        };
        format!(
            ",
         bounds AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi, array_agg(DISTINCT author_id) AS au FROM enriched),
         {fl}
         SELECT NULL::bigint AS n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,
         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id,
         NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id
         FROM enriched e
         UNION ALL
         SELECT c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         COALESCE(fl.ids, '{{}}'), COALESCE(fl.favs, '{{}}'), COALESCE(fl.fols, '{{}}'), q.ord::bigint
         FROM requests q {join_count} JOIN fl ON fl.ord = q.ord"
        )
    } else {
        String::new()
    };
    let (flags, flags_join, fav, fol) = if text == sql::LIST_ALL && flag_arrays() {
        (
            ",
         bounds AS MATERIALIZED (SELECT min(id) AS lo, max(id) AS hi FROM article_ids),
         flags AS MATERIALIZED (
         SELECT q.ord,
         ARRAY(SELECT f.article_id FROM favorites f, bounds b WHERE f.user_id = q.p1 AND f.article_id BETWEEN b.lo AND b.hi) AS fav,
         ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.p1) AS fol
         FROM requests q)",
            " JOIN flags fl ON fl.ord = q.ord",
            "CASE WHEN e.id IS NULL THEN NULL ELSE e.id = ANY(fl.fav) END",
            "CASE WHEN e.id IS NULL THEN NULL ELSE e.author_id = ANY(fl.fol) END",
        )
    } else {
        (
            "",
            "",
            "CASE WHEN e.id IS NULL THEN NULL ELSE EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = q.p1) END",
            "CASE WHEN e.id IS NULL THEN NULL ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = e.author_id) END",
        )
    };
    Some(format!(
        "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({args}) WITH ORDINALITY AS r({names},ord)),
         {keys}
         {counted}
         page_keys AS MATERIALIZED (SELECT {page_cols}),
         pages AS MATERIALIZED (
         SELECT r.*, p.id FROM page_keys r LEFT JOIN LATERAL ({page}) p ON true),
         article_ids AS (SELECT DISTINCT id{key_col} FROM pages WHERE id IS NOT NULL),
         {enriched}{tail}",
        key_col = if author_key { ", p4" } else { "" },
        enriched = if enrich_set(text) {
            // Tag names and favorite counts for all the batch's articles in one index scan each.
            "tg AS MATERIALIZED (
         SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id
         WHERE at.article_id = ANY(ARRAY(SELECT id FROM article_ids)) GROUP BY 1),
         fc AS MATERIALIZED (
         SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY(ARRAY(SELECT id FROM article_ids)) GROUP BY 1),
         enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         COALESCE(tg.tags, '{}') AS tags, COALESCE(fc.n, 0) AS fc,
         u.username, u.bio, u.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id
         LEFT JOIN tg ON tg.article_id = a.id LEFT JOIN fc ON fc.article_id = a.id)"
        } else if author_key {
            // Every article of a key has that key's author.
            "enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         k.username, k.bio, k.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN keys k ON k.p4 = i.p4)"
        } else {
            "enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id)"
        },
        args = args.join(","),
        names = names.join(","),
        tail = if pack == Pack::List {
            select
        } else {
            format!(
                "{flags}
         SELECT c.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
         e.tags, e.fc,
         {fav},
         e.username, e.bio, e.image,
         {fol},
         q.ord::bigint AS __request_id
         FROM requests q {join_count} JOIN pages p ON {page_join} LEFT JOIN enriched e ON e.id = p.id{flags_join}
         ORDER BY q.ord, e.id DESC"
            )
        },
    ))
}

/// Article by slug and comments by slug, with each distinct slug's rows read once.
fn shared_slug(text: &str, args: &[String], names: &[String], pack: Pack) -> Option<String> {
    let body = if text == sql::ARTICLE_BY_SLUG && pack == Pack::Article {
        "e AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug IN (SELECT DISTINCT p2 FROM requests))
         SELECT e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tags, e.fc,
         NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id, 0::bigint AS __request_id
         FROM e
         UNION ALL
         SELECT e.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = q.p1),
         NULL, NULL, NULL,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = e.author_id),
         NULL, q.ord::bigint
         FROM requests q JOIN e ON e.slug = q.p2"
            .to_string()
    } else if text == sql::ARTICLE_BY_SLUG {
        "e AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug IN (SELECT DISTINCT p2 FROM requests))
         SELECT e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tags, e.fc,
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = q.p1),
         e.username, e.bio, e.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = q.p1 AND fo.followee_id = e.author_id),
         q.ord::bigint AS __request_id
         FROM requests q JOIN e ON e.slug = q.p2 ORDER BY q.ord"
            .to_string()
    } else if (text == sql::COMMENTS_LIST || text == sql::COMMENTS_LIST_SET)
        && pack == Pack::Comments
    {
        // Each comment once; a header per request names its article (NULL: no such slug) and the viewer's
        // followees among the batch's comment authors.
        "e AS MATERIALIZED (
         SELECT a.slug, a.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
         FROM articles a
         LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                            ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
         LEFT JOIN users u ON u.id = c.author_id
         WHERE a.slug IN (SELECT DISTINCT p2 FROM requests)),
         au AS MATERIALIZED (SELECT array_agg(DISTINCT author_id) AS au FROM e),
         arts AS MATERIALIZED (SELECT DISTINCT slug, aid FROM e)
         SELECT e.aid, e.id, e.body, e.created_at, e.updated_at, e.username, e.bio, e.image, NULL::boolean, e.author_id,
         NULL::bigint[], 0::bigint AS __request_id
         FROM e WHERE e.id IS NOT NULL
         UNION ALL
         SELECT arts.aid, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
         ARRAY(SELECT fo.followee_id FROM follows fo, au WHERE fo.follower_id = q.p1 AND fo.followee_id = ANY(au.au)),
         q.ord::bigint
         FROM requests q LEFT JOIN arts ON arts.slug = q.p2"
            .to_string()
    } else if text == sql::COMMENTS_LIST || text == sql::COMMENTS_LIST_SET {
        "e AS MATERIALIZED (
         SELECT a.slug, a.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
         FROM articles a
         LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                            ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
         LEFT JOIN users u ON u.id = c.author_id
         WHERE a.slug IN (SELECT DISTINCT p2 FROM requests)),
         fl AS MATERIALIZED (SELECT q.ord, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.p1) AS fol FROM requests q)
         SELECT e.aid, e.id, e.body, e.created_at, e.updated_at, e.username, e.bio, e.image,
         CASE WHEN e.id IS NULL THEN false ELSE e.author_id = ANY(fl.fol) END,
         q.ord::bigint AS __request_id
         FROM requests q JOIN fl ON fl.ord = q.ord JOIN e ON e.slug = q.p2 ORDER BY q.ord, e.created_at DESC, e.id DESC"
            .to_string()
    } else {
        return None;
    };
    Some(format!(
        "WITH requests AS MATERIALIZED (SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         {body}",
        args.join(","),
        names.join(","),
    ))
}

/// A followed author's Nth newest article proves at least N feed candidates at/above that ID.
/// N is the largest requested limit+offset among its viewers, so their pages cannot need older IDs.
/// This proof and every cutoff are recomputed inside the same SQL statement.
/// The feed's count, page and enrichment CTEs. Each request's followee ids are read once (in `r`) for both its
/// count and its page; a viewer with 1000 or more followed articles is capped by an EXISTS on the 1000th instead
/// of counting them.
macro_rules! feed_ctes {
    ($cnt:expr) => {
        concat!("WITH r AS MATERIALIZED (
 SELECT r.*, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1) AS fl
 FROM unnest($1::bigint[], $2::bigint[], $3::bigint[], $4::bigint[]) WITH ORDINALITY AS r(p1,p2,p3,p4,ord)),", $cnt, "
 bounds AS MATERIALIZED (
 SELECT b.author_id, (SELECT a.id FROM articles a WHERE a.author_id=b.author_id
   ORDER BY a.id DESC OFFSET b.take-1 LIMIT 1) AS cutoff
 FROM (SELECT f.author_id, max(GREATEST(r.p4,1)) AS take FROM r, unnest(r.fl) f(author_id)
   GROUP BY f.author_id HAVING count(*)>=2 ORDER BY count(*) DESC,f.author_id LIMIT 8) b),
 page AS MATERIALIZED (
 SELECT r.ord, p.id FROM r
 CROSS JOIN LATERAL (SELECT max(b.cutoff) AS cutoff FROM bounds b WHERE b.author_id=ANY(r.fl)) bound
 CROSS JOIN LATERAL (
   SELECT x.id FROM unnest(r.fl) AS fo(followee_id) CROSS JOIN LATERAL (
     SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id
       AND a3.id >= COALESCE(bound.cutoff, '-9223372036854775808'::bigint)
       ORDER BY a3.id DESC LIMIT r.p4) x
   ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3) p),
 ids AS MATERIALIZED (SELECT DISTINCT id FROM page),
 tg AS MATERIALIZED (
 SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags at JOIN tags t ON t.id = at.tag_id
 WHERE at.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY 1),
 fc AS MATERIALIZED (
 SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY 1),
 e AS MATERIALIZED (
 SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, u.username, u.bio, u.image,
   COALESCE(tg.tags, '{}') AS tags, COALESCE(fc.n, 0) AS fc
 FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id
 LEFT JOIN tg ON tg.article_id = a.id LEFT JOIN fc ON fc.article_id = a.id)")
    };
}

/// Each request's capped feed count: an EXISTS on its 1000th followed article, else the exact count.
macro_rules! feed_cnt {
    () => {
        "
 cnt AS MATERIALIZED (
 SELECT r.ord, CASE WHEN EXISTS (SELECT a3.author_id, a3.id FROM articles a3 WHERE a3.author_id = ANY(r.fl)
                                 ORDER BY a3.author_id, a3.id DESC OFFSET 999 LIMIT 1) THEN 1000::bigint
   ELSE (SELECT count(*) FROM articles a3 WHERE a3.author_id = ANY(r.fl)) END AS n FROM r),"
    };
}

/// `feed_cnt!` with a batch-level shortcut: the followees shared by two or more requests in the batch (the 8 most shared)
/// are checked once for a 1000th article of their own, and any request following one of them is capped at 1000
/// without walking its followed articles.
macro_rules! feed_cnt_big {
    () => {
        "
 big AS MATERIALIZED (
 SELECT ARRAY(SELECT b.f FROM (SELECT f FROM r, unnest(r.fl) AS f GROUP BY f HAVING count(*) >= 2
                               ORDER BY count(*) DESC, f LIMIT 8) b
   WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = b.f ORDER BY a3.id DESC OFFSET 999 LIMIT 1)) AS fids),
 cnt AS MATERIALIZED (
 SELECT r.ord, CASE WHEN r.fl && (SELECT fids FROM big) THEN 1000::bigint
   WHEN EXISTS (SELECT a3.author_id, a3.id FROM articles a3 WHERE a3.author_id = ANY(r.fl)
                ORDER BY a3.author_id, a3.id DESC OFFSET 999 LIMIT 1) THEN 1000::bigint
   ELSE (SELECT count(*) FROM articles a3 WHERE a3.author_id = ANY(r.fl)) END AS n FROM r),"
    };
}

/// Comments in one execution, explicitly ordered (two columns are named `id`, so `q.*` can't be ordered by name).
/// Feed batches in two phases: every request's count and page ids first, then each distinct article enriched
/// once with set joins (tag names hash-joined to the 200-row tags table, favorite counts grouped), and only the
/// favorited flag per (request, article). Every page article's author is one of the viewer's followees in this
/// snapshot, so `following` is true exactly when there is an article. Rows equal LIST_FEED's per request, in the
/// same order; an empty page still yields its count with empty tags, zero favorites and false flags.
macro_rules! feed_batch {
    ($cnt:expr) => {
        concat!(
            feed_ctes!($cnt),
            "
SELECT c.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, COALESCE(e.tags, '{}'), COALESCE(e.fc, 0),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = r.p1),
 e.username, e.bio, e.image, e.id IS NOT NULL,
 r.ord::bigint AS __request_id
FROM r JOIN cnt c ON c.ord = r.ord LEFT JOIN page p ON p.ord = r.ord LEFT JOIN e ON e.id = p.id
ORDER BY r.ord, e.id DESC"
        )
    };
}
pub const FEED_BATCH: &str = feed_batch!(feed_cnt!());
pub const FEED_BATCH_BIG: &str = feed_batch!(feed_cnt_big!());

/// `FEED_BATCH` packed like the shared lists (`Pack::List`): each distinct article once, then per request its count,
/// page ids, favorited ids and followed authors (every page article's author).
macro_rules! feed_packed {
    ($cnt:expr) => {
        concat!(
            feed_ctes!($cnt),
            ",
 pg AS MATERIALIZED (
 SELECT p.ord, array_agg(p.id ORDER BY p.id DESC) AS ids,
   array_agg(p.id) FILTER (WHERE EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = p.id AND f.user_id = r.p1)) AS favs,
   array_agg(e.author_id) AS fols
 FROM page p JOIN r ON r.ord = p.ord JOIN e ON e.id = p.id GROUP BY p.ord)
SELECT NULL::bigint AS n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tags, e.fc,
 NULL::boolean, e.username, e.bio, e.image, NULL::boolean, e.author_id,
 NULL::bigint[], NULL::bigint[], NULL::bigint[], 0::bigint AS __request_id
FROM e
UNION ALL
SELECT c.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
 COALESCE(pg.ids, '{}'), COALESCE(pg.favs, '{}'), COALESCE(pg.fols, '{}'), r.ord::bigint
FROM r JOIN cnt c ON c.ord = r.ord LEFT JOIN pg ON pg.ord = r.ord"
        )
    };
}
pub const FEED_PACKED: &str = feed_packed!(feed_cnt!());
pub const FEED_PACKED_BIG: &str = feed_packed!(feed_cnt_big!());

pub const COMMENTS_BATCH: &str = "SELECT q.aid, q.cid, q.body, q.created_at, q.updated_at, q.username, q.bio, q.image, q.following,
 r.ord::bigint AS __request_id
FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(p1,p2,ord)
CROSS JOIN LATERAL (
 SELECT a.id AS aid, c.id AS cid, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 CASE WHEN c.id IS NULL THEN false ELSE c.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)) END AS following
 FROM articles a
 LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                    ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
 LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = r.p2 OFFSET 0) q
ORDER BY r.ord, q.created_at DESC, q.cid DESC";

/// The per-comment-probe form of `COMMENTS_BATCH`.
pub const COMMENTS_BATCH_EXISTS: &str = "SELECT q.aid, q.cid, q.body, q.created_at, q.updated_at, q.username, q.bio, q.image, q.following,
 r.ord::bigint AS __request_id
FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(p1,p2,ord)
CROSS JOIN LATERAL (
 SELECT a.id AS aid, c.id AS cid, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 CASE WHEN c.id IS NULL THEN false ELSE EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = c.author_id) END AS following
 FROM articles a
 LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                    ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
 LEFT JOIN users u ON u.id = c.author_id
 WHERE a.slug = r.p2) q
ORDER BY r.ord, q.created_at DESC, q.cid DESC";

/// Comment `following` flags come from the viewer's followee ids, read once per request that has comments,
/// instead of one `follows` probe per comment. `OFFSET 0` keeps the subquery from being pulled up, so the ARRAY
/// is an InitPlan rerun only when the request changes (pulled up, it ran once per comment row: 2x slower on the
/// test box). `READ_FOLLOWEE_LIST=0` keeps the per-comment probes.
/// READ_FLAG_ARRAYS=0 restores per-row EXISTS flags in the shared global list.
fn flag_arrays() -> bool {
    std::env::var("READ_FLAG_ARRAYS").ok().as_deref() != Some("0")
}

/// Packed global lists aggregate each page's ids once and read each distinct viewer's favorites / followees
/// once per batch (2.43 -> 1.36 ms for 96-request batches on the bench box, 1.14 -> 0.83 ms for 32); packed tag
/// lists read each request's flags with one `= ANY(page)` index read instead of a probe per article (3.16 ->
/// 2.98 ms, 20 requests). READ_LIST_FLAGS=0 keeps the per-(request, article) flags.
fn list_flags() -> bool {
    std::env::var("READ_LIST_FLAGS").ok().as_deref() != Some("0")
}

/// Shared author lists resolve each distinct author name once (with the profile shown on their articles) and
/// page and count by id, instead of joining `users` by name per page/count and by id per article: 7-10%
/// faster on 26-request batches (2.66 -> 2.49, 3.03 -> 2.74 ms). READ_AUTHOR_KEY=0 restores the per-key joins.
fn author_key() -> bool {
    std::env::var("READ_AUTHOR_KEY").ok().as_deref() != Some("0")
}

/// The global and tag lists read tags and favorite counts with one grouped scan per batch (as the feed does)
/// instead of a correlated subquery per article: 14% faster for tag-list batches and 5% for global ones on a
/// database aged by 15 minutes of load. Author lists stay per article (2% slower grouped). READ_ENRICH_SET=0
/// keeps per-article subqueries everywhere, =1 groups the author and favorited lists too.
fn enrich_set(text: &str) -> bool {
    match std::env::var("READ_ENRICH_SET").ok().as_deref() {
        Some("0") => false,
        Some("1") => true,
        _ => text == sql::LIST_ALL || text == sql::LIST_TAG,
    }
}

/// Feed counts are capped through the batch's shared followees first (`feed_cnt_big!`); READ_FEED_BIG=0 walks
/// every request's followed articles.
fn feed_big() -> bool {
    std::env::var("READ_FEED_BIG").ok().as_deref() != Some("0")
}

fn followee_list() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var("READ_FOLLOWEE_LIST").ok().as_deref() != Some("0"))
}

/// Splits one coalesced execution of `n` requests into each request's rows. Rows carry their 1-based request
/// number in the last column. In a packed result, request 0 marks a shared row, which is given (as a cheap
/// handle clone of the same row buffer) to each request whose header lists it, right after that header.
pub fn demux(rows: Vec<Row>, n: usize, sort: RowSort, pack: Pack) -> Result<Vec<Vec<Row>>, Error> {
    let mut out: Vec<Vec<Row>> = (0..n).map(|_| Vec::new()).collect();
    let route = |row: &Row| -> Result<Option<usize>, Error> {
        let id = int(row, row.len() - 1)?;
        if id == 0 && pack != Pack::No {
            return Ok(None);
        }
        let pos = usize::try_from(id)
            .ok()
            .and_then(|i| i.checked_sub(1))
            .filter(|&i| i < n)
            .ok_or(Error::Rows)?;
        Ok(Some(pos))
    };
    if pack == Pack::No {
        for row in rows {
            let pos = route(&row)?.ok_or(Error::Rows)?;
            out[pos].push(row);
        }
        for rows in &mut out {
            sort.apply(rows)?;
        }
        return Ok(out);
    }
    let mut headers = Vec::with_capacity(n);
    let shared_rows = rows.len().saturating_sub(n);
    // Lists key shared rows by article id (column 1), comments and articles by article id (column 0).
    let key_col = if pack == Pack::List { 1 } else { 0 };
    if pack == Pack::Comments {
        let mut shared: IdMap<Vec<Row>> =
            IdMap::with_capacity_and_hasher(shared_rows, Default::default());
        for row in rows {
            match route(&row)? {
                Some(pos) => headers.push((pos, row)),
                None => shared.entry(int(&row, key_col)?).or_default().push(row),
            }
        }
        if headers.len() != n {
            return Err(Error::Rows);
        }
        for comments in shared.values_mut() {
            sort.apply(comments)?;
        }
        for (pos, header) in headers {
            let article = key(&header, 0)?;
            let rows = &mut out[pos];
            if !rows.is_empty() {
                return Err(Error::Rows);
            }
            let comments = article.and_then(|a| shared.get(&a));
            rows.reserve(1 + comments.map_or(0, Vec::len));
            rows.push(header);
            if let Some(comments) = comments {
                rows.extend(comments.iter().cloned());
            }
        }
        return Ok(out);
    }
    // Lists and single articles: each shared row appears exactly once.
    let mut shared: IdMap<Row> = IdMap::with_capacity_and_hasher(shared_rows, Default::default());
    for row in rows {
        match route(&row)? {
            Some(pos) => headers.push((pos, row)),
            None => {
                if shared.insert(int(&row, key_col)?, row).is_some() {
                    return Err(Error::Rows);
                }
            }
        }
    }
    if pack == Pack::List && headers.len() != n {
        return Err(Error::Rows);
    }
    for (pos, header) in headers {
        let rows = &mut out[pos];
        if !rows.is_empty() {
            return Err(Error::Rows);
        }
        if pack == Pack::List {
            let ids = (header.len() > 15)
                .then(|| header.raw(15))
                .flatten()
                .and_then(Ids::parse)
                .ok_or(Error::Rows)?;
            rows.reserve(ids.len() + 1);
            for id in ids.iter() {
                rows.push(shared.get(&id).ok_or(Error::Rows)?.clone());
            }
            // The header goes first.
            rows.push(header);
            rows.rotate_right(1);
        } else {
            // A request for a missing slug has no header and gets no rows.
            let id = int(&header, 0)?;
            let article = shared.get(&id).ok_or(Error::Rows)?.clone();
            rows.extend([header, article]);
        }
    }
    Ok(out)
}

/// Article ids hashed with one multiply instead of SipHash: the keys are database ids of this batch's own rows.
type IdMap<V> = HashMap<i64, V, std::hash::BuildHasherDefault<IdHasher>>;

#[derive(Default)]
struct IdHasher(u64);

impl std::hash::Hasher for IdHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.0 =
                (self.0.rotate_left(5) ^ u64::from(*b)).wrapping_mul(0x51_7c_c1_b7_27_22_0a_95);
        }
    }
    fn write_i64(&mut self, v: i64) {
        // Fibonacci hashing; hashbrown takes the top 7 bits as the tag and the low bits as the bucket.
        let h = (v as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15);
        self.0 = h ^ (h >> 32);
    }
}

/// A borrowed binary int8[] without NULL elements (an id list in a packed header), read in place instead of
/// collected into a Vec. Rejects what `Vec<i64>` would: more than one dimension, another element type, NULLs.
pub struct Ids<'a>(&'a [u8]);

impl<'a> Ids<'a> {
    pub fn parse(raw: &'a [u8]) -> Option<Self> {
        let int = |at: usize| -> Option<i32> {
            Some(i32::from_be_bytes(raw.get(at..at + 4)?.try_into().ok()?))
        };
        let dims = int(0)?;
        if int(8)? as u32 != Type::INT8.oid() {
            return None;
        }
        let elements = match dims {
            0 => &raw[12..],
            1 => raw.get(20..)?,
            _ => return None,
        };
        let n = if dims == 0 { 0 } else { int(12)? };
        if n < 0 || elements.len() != n as usize * 12 {
            return None;
        }
        if elements
            .chunks_exact(12)
            .any(|e| e[..4] != 8i32.to_be_bytes())
        {
            return None;
        }
        Some(Ids(elements))
    }

    /// Column `k` of `row`, which must be a non-NULL int8[] without NULLs.
    #[track_caller]
    pub fn of(row: &'a Row, k: usize) -> Self {
        row.raw(k)
            .and_then(Self::parse)
            .unwrap_or_else(|| panic!("error retrieving column {k}: not an int8[] of ids"))
    }

    pub fn len(&self) -> usize {
        self.0.len() / 12
    }
    pub fn iter(&self) -> impl Iterator<Item = i64> + '_ {
        self.0
            .chunks_exact(12)
            .map(|e| i64::from_be_bytes(e[4..].try_into().expect("8-byte element")))
    }
    pub fn contains(&self, v: i64) -> bool {
        self.iter().any(|x| x == v)
    }
}

pub fn same(a: &Statement, b: &Statement) -> bool {
    std::ptr::eq(a.columns(), b.columns())
}

/// Reuse the existing binary Bind values instead of re-encoding each parameter.
/// This accepts only frames produced by this client's encoder; all reads are checked.
pub fn arrays(frames: &[&Bytes], types: &[Type]) -> Option<Vec<Bytes>> {
    let mut columns: Vec<_> = types
        .iter()
        .map(|ty| {
            let mut b = BytesMut::new();
            b.extend_from_slice(&1i32.to_be_bytes());
            b.extend_from_slice(&1i32.to_be_bytes()); // nulls permitted
            b.extend_from_slice(&ty.oid().to_be_bytes());
            b.extend_from_slice(&i32::try_from(frames.len()).ok()?.to_be_bytes());
            b.extend_from_slice(&1i32.to_be_bytes());
            Some(b)
        })
        .collect::<Option<_>>()?;
    for frame in frames {
        if frame.first() != Some(&b'B') {
            return None;
        }
        let msglen = u32::from_be_bytes(frame.get(1..5)?.try_into().ok()?) as usize;
        let bind_end = 1usize.checked_add(msglen)?;
        let mut at = 5;
        for _ in 0..2 {
            at += frame.get(at..bind_end)?.iter().position(|b| *b == 0)? + 1;
        }
        let formats = u16::from_be_bytes(frame.get(at..at + 2)?.try_into().ok()?) as usize;
        at += 2;
        if formats != types.len() {
            return None;
        }
        for _ in 0..formats {
            if frame.get(at..at + 2)? != 1i16.to_be_bytes() {
                return None;
            }
            at += 2;
        }
        let count = u16::from_be_bytes(frame.get(at..at + 2)?.try_into().ok()?) as usize;
        at += 2;
        if count != types.len() {
            return None;
        }
        for col in &mut columns {
            let raw = frame.get(at..at + 4)?;
            let n = i32::from_be_bytes(raw.try_into().ok()?);
            at += 4;
            col.extend_from_slice(raw);
            if n >= 0 {
                let end = at.checked_add(n as usize)?;
                col.extend_from_slice(frame.get(at..end)?);
                at = end;
            } else if n != -1 {
                return None;
            }
        }
        if at.checked_add(4)? != bind_end || frame.get(at..bind_end)? != [0, 1, 0, 1] {
            return None;
        }
    }
    Some(columns.into_iter().map(BytesMut::freeze).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use postgres_types::FromSql;

    #[test]
    fn permute_gathers_by_index() {
        for order in [
            vec![2, 0, 1],
            vec![1, 0, 3, 2],
            vec![0, 1, 2],
            vec![3, 2, 1, 0],
            vec![4, 0, 3, 1, 2],
        ] {
            let mut v: Vec<usize> = (0..order.len()).map(|i| i * 10).collect();
            permute(&mut v, order.clone());
            assert_eq!(v, order.iter().map(|i| i * 10).collect::<Vec<_>>());
        }
    }

    /// `cargo test --release print_shared_sql -- --ignored --nocapture` dumps the shared SQL for offline checks.
    #[test]
    #[ignore]
    fn print_shared_sql() {
        let args = ["$1::bigint[]", "$2::bigint[]", "$3::bigint[]"].map(String::from);
        let names = ["p1", "p2", "p3"].map(String::from);
        println!(
            "{};",
            shared_list(sql::LIST_ALL, &args, &names, Pack::List).unwrap()
        );
        let args4 =
            ["$1::bigint[]", "$2::bigint[]", "$3::bigint[]", "$4::text[]"].map(String::from);
        let names4 = ["p1", "p2", "p3", "p4"].map(String::from);
        for t in [sql::LIST_TAG, sql::LIST_AUTHOR] {
            println!(
                "--next\n{};",
                shared_list(t, &args4, &names4, Pack::List).unwrap()
            );
        }
        for q in [FEED_PACKED, FEED_PACKED_BIG] {
            println!("--next\n{q};");
        }
    }

    fn bind(values: &[Option<&[u8]>]) -> Bytes {
        let mut b = vec![b'B', 0, 0, 0, 0, 0, b's', 0];
        b.extend_from_slice(&(values.len() as u16).to_be_bytes());
        for _ in values {
            b.extend_from_slice(&1i16.to_be_bytes());
        }
        b.extend_from_slice(&(values.len() as u16).to_be_bytes());
        for v in values {
            match v {
                Some(v) => {
                    b.extend_from_slice(&(v.len() as i32).to_be_bytes());
                    b.extend_from_slice(v);
                }
                None => b.extend_from_slice(&(-1i32).to_be_bytes()),
            }
        }
        b.extend_from_slice(&[0, 1, 0, 1]);
        let n = (b.len() - 1) as u32;
        b[1..5].copy_from_slice(&n.to_be_bytes());
        b.extend_from_slice(&[b'E', 0, 0, 0, 9, 0, 0, 0, 0, 0]);
        Bytes::from(b)
    }

    #[test]
    fn transpose_preserves_nulls_utf8_and_integer_boundaries() {
        let a = bind(&[Some(&i64::MAX.to_be_bytes()), Some("één 🙂".as_bytes())]);
        let b = bind(&[Some(&i64::MIN.to_be_bytes()), None]);
        let c = bind(&[None, Some(b"")]);
        let result = arrays(&[&a, &b, &c], &[Type::INT8, Type::TEXT]).unwrap();
        assert_eq!(
            Vec::<Option<i64>>::from_sql(&Type::INT8_ARRAY, &result[0]).unwrap(),
            vec![Some(i64::MAX), Some(i64::MIN), None]
        );
        assert_eq!(
            Vec::<Option<String>>::from_sql(&Type::TEXT_ARRAY, &result[1]).unwrap(),
            vec![Some("één 🙂".into()), None, Some(String::new())]
        );
        for n in 0..a.len() - 10 {
            assert!(arrays(&[&a.slice(..n)], &[Type::INT8, Type::TEXT]).is_none());
        }
    }

    #[test]
    fn shared_selection_requires_duplicate_pages_and_filters() {
        let one = 1i64.to_be_bytes();
        let two = 2i64.to_be_bytes();
        let ten = 10i64.to_be_bytes();
        let zero = 0i64.to_be_bytes();
        let a = bind(&[Some(&one), Some(&ten), Some(&zero), Some(b"rust")]);
        let b = bind(&[Some(&two), Some(&ten), Some(&zero), Some(b"rust")]);
        let page = bind(&[Some(&two), Some(&ten), Some(&ten), Some(b"rust")]);
        let filter = bind(&[Some(&two), Some(&ten), Some(&zero), Some(b"other")]);
        assert!(should_share(&[&a, &b], 50));
        assert!(!should_share(&[&a, &page], 50));
        assert!(!should_share(&[&a, &filter], 50));
        assert!(!should_share(&[&a], 50));
        assert!(should_share(&[&a, &page], 100));
        assert!(!should_share(&[&a], 100));
        assert!(!should_share(&[&a, &a.slice(..8)], 100));
    }

    #[test]
    fn sorted_share_count_matches_the_pairwise_count() {
        // The previous rule: for each frame, rescan the earlier frames for its key.
        fn pairwise(frames: &[&Bytes], pct: usize) -> bool {
            if frames.len() < 2 {
                return false;
            }
            let mut unique = 0;
            for (i, frame) in frames.iter().enumerate() {
                let Some(key) = non_viewer_key(frame) else {
                    return false;
                };
                if !frames[..i].iter().any(|f| non_viewer_key(f) == Some(key)) {
                    unique += 1;
                }
            }
            unique * 100 <= frames.len() * pct
        }
        let mut seed = 9u64;
        let mut next = move |n: u64| {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (seed >> 33) % n
        };
        for _ in 0..2000 {
            let len = next(40) as usize;
            let kinds = 1 + next(12);
            let frames: Vec<Bytes> = (0..len)
                .map(|_| {
                    let viewer = (next(5) as i64).to_be_bytes();
                    let offset = (next(kinds) as i64 * 10).to_be_bytes();
                    match next(60) {
                        0 => bind(&[Some(&viewer)]),
                        1 => bind(&[Some(&viewer), Some(&offset)]).slice(..12),
                        _ => bind(&[Some(&viewer), Some(&10i64.to_be_bytes()), Some(&offset)]),
                    }
                })
                .collect();
            let refs: Vec<&Bytes> = frames.iter().collect();
            for pct in [0, 25, 50, 75, 99, 100, 150] {
                assert_eq!(should_share(&refs, pct), pairwise(&refs, pct), "{pct}");
            }
        }
    }

    #[test]
    fn malformed_bind_is_rejected() {
        for n in 0..100 {
            assert!(arrays(&[&Bytes::from(vec![0; n])], &[Type::INT8]).is_none());
        }
    }
}
