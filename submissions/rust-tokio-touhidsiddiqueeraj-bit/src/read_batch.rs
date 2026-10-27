//! One execution for compatible concurrent reads, with no data retained afterward.
use bytes::{Bytes, BytesMut};
use tokio_postgres::{Statement, types::Type};

use crate::{db::Stmts, sql};

pub struct Batch {
    pub original: Statement,
    pub statement: Statement,
    pub shared: Option<Statement>,
    pub broadcast: bool,
}

pub async fn prepare(
    client: &tokio_postgres::Client,
    st: &Stmts,
) -> Result<Vec<Batch>, tokio_postgres::Error> {
    let mut batches = Vec::new();
    let mut entries: Vec<(&Statement, &'static str, bool)> = vec![
        (&st.list_all, sql::LIST_ALL, true),
        (&st.list_tag, sql::LIST_TAG, true),
        (&st.list_author, sql::LIST_AUTHOR, true),
        (&st.list_favorited, sql::LIST_FAVORITED, true),
        (&st.list_feed, sql::LIST_FEED, true),
        (&st.article_by_slug, sql::ARTICLE_BY_SLUG, false),
        (&st.article_by_id, sql::ARTICLE_BY_ID, false),
        (&st.profile, sql::PROFILE, false),
        (&st.user_by_id, sql::USER_BY_ID, false),
        (&st.user_by_email, sql::USER_BY_EMAIL, false),
    ];
    // Candidate-only: batch concurrent comments reads (the leader read them one at a time).
    if std::env::var("READ_COMMENT_SET").ok().as_deref() == Some("1") {
        entries.push((&st.comments_list, sql::COMMENTS_LIST_SET, false));
    } else {
        entries.push((&st.comments_list, sql::COMMENTS_LIST, false));
    }

    for (original, text, ordered) in entries {
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
        } else if text == sql::COMMENTS_LIST || text == sql::COMMENTS_LIST_SET {
            query.push_str(" ORDER BY r.ord, q.com_at DESC, q.com_id DESC");
        }
        // Feed pages depend on the viewer, so equal pagination cannot establish
        // overlap. Keep their existing batched query.
        let shared = if text == sql::LIST_FEED {
            None
        } else if let Some(shared) = shared_list(text, &args, &names) {
            Some(client.prepare_typed(&shared, &types).await?)
        } else if let Some(shared) = shared_article_or_comments(text, &args, &names) {
            Some(client.prepare_typed(&shared, &types).await?)
        } else {
            None
        };
        batches.push(Batch {
            original: original.clone(),
            statement: client.prepare_typed(&query, &types).await?,
            shared,
            broadcast: false,
        });
    }
    // Only this argument-free, viewer-independent read may broadcast rows.
    // All recipients are already waiting in the same drained actor batch.
    if std::env::var("READ_TAG_BATCH").ok().as_deref() != Some("0") {
        batches.push(Batch {
            original: st.tags.clone(),
            statement: st.tags.clone(),
            shared: None,
            broadcast: true,
        });
    }
    Ok(batches)
}

/// Use sharing only when at least half the requests have duplicate non-viewer
/// arguments. Otherwise preserve the existing query without materialization.
pub fn statement<'a>(batch: &'a Batch, frames: &[&Bytes]) -> &'a Statement {
    match &batch.shared {
        Some(shared) if should_share(frames) => shared,
        _ => &batch.statement,
    }
}

fn should_share(frames: &[&Bytes]) -> bool {
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
    unique <= frames.len() / 2
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

/// Shared (deduplicated) reads for the two hottest single-target families. Many concurrent
/// requests for the same article resolve its rows once per drain batch; viewer flags stay per
/// request, computed inside the same SQL execution. No data is retained between requests.
pub fn shared_article_or_comments(text: &str, args: &[String], names: &[String]) -> Option<String> {
    if text == sql::ARTICLE_BY_SLUG {
        Some(format!(
            "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, a.id, a.author_id FROM requests r
         JOIN articles a ON a.slug = r.p2),
         ids AS (SELECT DISTINCT pages.id, pages.author_id FROM pages),
         enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id)
         SELECT e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at,
         COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = pages.viewer),
         e.username, e.bio, e.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = pages.viewer AND fo.followee_id = e.author_id),
         pages.ord::bigint AS __request_id
         FROM pages LEFT JOIN enriched e ON e.id = pages.id
         ORDER BY pages.ord",
        args.join(","),
        names.join(","),
    ))
    } else if text == sql::COMMENTS_LIST_SET || text == sql::COMMENTS_LIST {
        // One row per request even when the article has no comments: the comment
        // LATERAL is LEFT-joined per distinct article, and empty pages keep only the
        // article row with NULL comment columns (the caller skips them).
        Some(format!(
            "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         arts AS MATERIALIZED (
         SELECT DISTINCT r.p2 AS slug, a.id AS aid, a.author_id AS article_author FROM requests r
         JOIN articles a ON a.slug = r.p2),
         page AS MATERIALIZED (
         SELECT pg.slug, pg.aid, c.id, c.body, c.created_at, c.updated_at, c.author_id AS com_author
         FROM arts pg LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
         FROM comments c WHERE c.article_id = pg.aid ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true),
         enriched AS MATERIALIZED (
         SELECT pg.*, u.username, u.bio, u.image FROM page pg LEFT JOIN users u ON u.id = pg.com_author)
         SELECT e.aid, e.id, e.body, e.created_at, e.updated_at, e.username, e.bio, e.image,
         COALESCE(e.com_author IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1), false),
         r.ord::bigint AS __request_id
         FROM requests r JOIN enriched e ON e.slug = r.p2
         ORDER BY r.ord, e.created_at DESC NULLS LAST, e.id DESC NULLS LAST",
        args.join(","),
        names.join(","),
    ))
    } else {
        None
    }
}

/// Enrich each distinct article once within this execution. Every request still
/// reads PostgreSQL while it is being served; no result is retained by the app.
fn shared_list(text: &str, args: &[String], names: &[String]) -> Option<String> {
    let (count, page) = if text == sql::LIST_ALL {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s",
            "SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2",
        )
    } else if text == sql::LIST_TAG {
        (
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) LIMIT 1000) s) END AS n",
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_AUTHOR {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) LIMIT 1000) s",
            "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_FAVORITED {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) LIMIT 1000) s",
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_FEED {
        (
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)) ORDER BY a3.author_id, a3.id DESC LIMIT 1000) s",
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT r.p4) x WHERE fo.follower_id = r.p1 ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else {
        return None;
    };
    Some(format!(
        "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL ({count}) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL ({page}) p ON true),
         article_ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),
         enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id)
         SELECT p.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
         COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = p.viewer),
         e.username, e.bio, e.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = p.viewer AND fo.followee_id = e.author_id),
         p.ord::bigint AS __request_id
         FROM pages p LEFT JOIN enriched e ON e.id = p.id ORDER BY p.ord, e.id DESC",
        args.join(","),
        names.join(","),
    ))
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
        assert!(should_share(&[&a, &b]));
        assert!(!should_share(&[&a, &page]));
        assert!(!should_share(&[&a, &filter]));
        assert!(!should_share(&[&a]));
        assert!(!should_share(&[&a, &a.slice(..8)]));
    }

    #[test]
    fn malformed_bind_is_rejected() {
        for n in 0..100 {
            assert!(arrays(&[&Bytes::from(vec![0; n])], &[Type::INT8]).is_none());
        }
    }
}
