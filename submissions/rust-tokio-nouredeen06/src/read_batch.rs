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
    for (original, text, ordered) in [
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
    ] {
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
        // Feed pages depend on the viewer, so equal pagination cannot establish
        // overlap. Keep their existing batched query.
        let shared = if text == sql::LIST_FEED {
            None
        } else if let Some(shared) = shared_list(text, &args, &names) {
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
    if std::env::var("READ_COMMENTS_BATCH").ok().as_deref() != Some("0") {
        batches.push(crate::comment_batch::prepare(client, &st.comments_list).await?);
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

/// Share when at least half the requests reuse a page, list filter or comment
/// slug. Filtered lists can share their count even with different pagination.
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
    let max_unique = frames.len() / 2;
    // Default cohorts contain at most 32 requests. Keep their distinct borrowed
    // keys on the stack and decode each Bind frame only once. Larger configured
    // cohorts use a temporary vector, never a cache spanning executions.
    let mut inline: [&[u8]; 16] = [&[]; 16];
    let mut overflow = Vec::new();
    let keys = if max_unique <= inline.len() {
        &mut inline[..max_unique]
    } else {
        overflow.resize(max_unique, &[][..]);
        overflow.as_mut_slice()
    };
    let mut unique = 0;
    for frame in frames {
        let Some(key) = non_viewer_key(frame) else {
            return false;
        };
        if !keys[..unique].contains(&key) {
            // Once this limit is exceeded, later duplicates cannot make the
            // cohort eligible. Avoid parsing the remaining frames in that case.
            if unique == max_unique {
                return false;
            }
            keys[unique] = key;
            unique += 1;
        }
    }
    true
}

// Bind frames already passed arrays() validation; keep bounds checks here too.
// Global lists use the complete page key; filtered lists use the filter because
// their capped count is shared across pages. Two-parameter comment reads use slug.
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
    if count == 4 {
        for _ in 0..2 {
            if frame.get(at..at + 4)? != 8i32.to_be_bytes() {
                return None;
            }
            at = at.checked_add(12)?;
        }
    }
    frame.get(at..end)
}

/// Resolve and count each filter once, fetch each page once, and enrich each
/// article once within this execution. Viewers and response ordinals are joined
/// back only after these shared reads. Nothing survives this SQL execution.
fn shared_list(text: &str, args: &[String], names: &[String]) -> Option<String> {
    if text == sql::LIST_ALL {
        return shared_global(args, names);
    }
    let (lookup, count, page) = if text == sql::LIST_TAG {
        (
            Some("SELECT id FROM tags WHERE name = k.p4"),
            "SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = f.filter_id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = f.filter_id LIMIT 1000) s) END AS n",
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = f.filter_id ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_AUTHOR {
        (
            Some("SELECT id FROM users WHERE username = k.p4"),
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles WHERE author_id = f.filter_id LIMIT 1000) s",
            "SELECT a2.id FROM articles a2 WHERE a2.author_id = f.filter_id ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_FAVORITED {
        (
            Some("SELECT id FROM users WHERE username = k.p4"),
            "SELECT count(*) AS n FROM (SELECT 1 FROM favorites fav WHERE fav.user_id = f.filter_id LIMIT 1000) s",
            "SELECT fav.article_id AS id FROM favorites fav WHERE fav.user_id = f.filter_id ORDER BY fav.article_id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else {
        return None;
    };
    let (keys, counts, page_source, count_join, page_join) = if let Some(lookup) = lookup {
        (
            "p2, p3, p4",
            format!(
                "filters AS MATERIALIZED (SELECT k.p4, ({lookup}) AS filter_id
                 FROM (SELECT DISTINCT p4 FROM requests) k),
                 counted AS MATERIALIZED (SELECT f.p4, c.n FROM filters f
                 CROSS JOIN LATERAL ({count}) c)"
            ),
            "page_keys r JOIN filters f USING (p4)",
            "JOIN counted c ON c.p4 = r.p4",
            "p.p2 = r.p2 AND p.p3 = r.p3 AND p.p4 = r.p4",
        )
    } else {
        (
            "p2, p3",
            format!("counted AS MATERIALIZED ({count})"),
            "page_keys r",
            "CROSS JOIN counted c",
            "p.p2 = r.p2 AND p.p3 = r.p3",
        )
    };
    Some(format!(
        "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         {counts},
         page_keys AS (SELECT DISTINCT {keys} FROM requests),
         pages AS MATERIALIZED (
         SELECT r.*, p.id FROM {page_source}
         LEFT JOIN LATERAL ({page}) p ON true),
         article_ids AS (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),
         enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
               FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id)
         SELECT c.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
         COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = r.p1),
         e.username, e.bio, e.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.p1 AND fo.followee_id = e.author_id),
         r.ord::bigint AS __request_id
         FROM requests r {count_join} JOIN pages p ON {page_join}
         LEFT JOIN enriched e ON e.id = p.id ORDER BY r.ord, e.id DESC",
        args.join(","),
        names.join(","),
    ))
}

// Keep the simpler global-feed page query: distinct page keys added overhead
// for the common small batches. Prove the exact count cap using the 1,000th row.
fn shared_global(args: &[String], names: &[String]) -> Option<String> {
    Some(format!(
        "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) END AS n) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL (SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2) p ON true),
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
    let count = i32::try_from(frames.len()).ok()?.to_be_bytes();
    let mut columns: Vec<_> = types
        .iter()
        .map(|ty| {
            // An int8 array needs a 20-byte header and at most 12 bytes per
            // element (length + value). Reserve once instead of growing it as
            // each request is transposed. Text lengths remain variable.
            let mut b = if *ty == Type::INT8 {
                BytesMut::with_capacity(frames.len().checked_mul(12)?.checked_add(20)?)
            } else {
                BytesMut::new()
            };
            b.extend_from_slice(&1i32.to_be_bytes());
            b.extend_from_slice(&1i32.to_be_bytes()); // nulls permitted
            b.extend_from_slice(&ty.oid().to_be_bytes());
            b.extend_from_slice(&count);
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
    fn shared_selection_reuses_filters_across_different_pages() {
        let one = 1i64.to_be_bytes();
        let two = 2i64.to_be_bytes();
        let ten = 10i64.to_be_bytes();
        let zero = 0i64.to_be_bytes();
        let a = bind(&[Some(&one), Some(&ten), Some(&zero), Some(b"rust")]);
        let b = bind(&[Some(&two), Some(&ten), Some(&zero), Some(b"rust")]);
        let page = bind(&[Some(&two), Some(&ten), Some(&ten), Some(b"rust")]);
        let filter = bind(&[Some(&two), Some(&ten), Some(&zero), Some(b"other")]);
        assert!(should_share(&[&a, &b]));
        assert!(should_share(&[&a, &page]));
        assert!(!should_share(&[&a, &filter]));
        assert!(!should_share(&[&a]));
        assert!(!should_share(&[&a, &a.slice(..8)]));
        let global = bind(&[Some(&one), Some(&ten), Some(&zero)]);
        let global_next = bind(&[Some(&two), Some(&ten), Some(&ten)]);
        assert!(!should_share(&[&global, &global_next]));
        let comments = bind(&[Some(&one), Some(b"article-slug")]);
        let comments_viewer = bind(&[Some(&two), Some(b"article-slug")]);
        assert!(should_share(&[&comments, &comments_viewer]));
    }

    #[test]
    fn shared_selection_thresholds_and_large_cohorts() {
        // Exercise the exact half-distinct boundary, odd cohort sizes and the
        // heap fallback above 32 requests. The expected value comes from the
        // generated distinct slug count, independently of Bind parsing.
        for count in [0usize, 1, 2, 3, 31, 32, 33, 64, 65, 128] {
            for distinct in [1, 2, count / 2, count / 2 + 1, count]
                .into_iter()
                .filter(|&n| n > 0)
            {
                let frames: Vec<_> = (0..count)
                    .map(|i| {
                        let viewer = (i as i64 + 1).to_be_bytes();
                        let slug = format!("thread-{}", i % distinct);
                        bind(&[Some(&viewer), Some(slug.as_bytes())])
                    })
                    .collect();
                let refs: Vec<_> = frames.iter().collect();
                assert_eq!(
                    should_share(&refs),
                    count >= 2 && distinct.min(count) <= count / 2,
                    "{count} requests with {distinct} possible slugs"
                );
            }
        }
        let valid = bind(&[Some(&1i64.to_be_bytes()), Some(b"same-thread")]);
        let invalid = valid.slice(..8);
        let mut refs = vec![&valid; 64];
        refs.push(&invalid);
        assert!(!should_share(&refs));
    }

    #[test]
    fn malformed_bind_is_rejected() {
        for n in 0..100 {
            assert!(arrays(&[&Bytes::from(vec![0; n])], &[Type::INT8]).is_none());
        }
    }
}
