//! One execution for compatible concurrent reads, with no data retained afterward.
use bytes::{Bytes, BytesMut};
use tokio_postgres::{Statement, types::Type};

use crate::{db::Stmts, sql};

pub struct Batch {
    pub original: Statement,
    pub statement: Statement,
    pub shared: Option<Statement>,
    pub feed: bool,
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
        (
            &st.comments_list,
            if std::env::var("READ_COMMENT_SET").ok().as_deref() == Some("1") {
                sql::COMMENTS_LIST_SET
            } else {
                sql::COMMENTS_LIST
            },
            false,
        ),
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
        } else if text == sql::COMMENTS_LIST || text == sql::COMMENTS_LIST_SET {
            // the article and comment ids need distinct names for the outer ordering
            query.push_str("(article_id, comment_id, body, created_at, updated_at, username, bio, image, following) ORDER BY r.ord, q.created_at DESC, q.comment_id DESC");
        }
        let shared = match shared_list(text, &args, &names) {
            Some(shared) => Some(client.prepare_typed(&sql::prepared(&shared), &types).await?),
            None => None,
        };
        batches.push(Batch {
            original: original.clone(),
            statement: client.prepare_typed(&sql::prepared(&query), &types).await?,
            shared,
            feed: text == sql::LIST_FEED,
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
            feed: false,
            broadcast: true,
        });
    }
    Ok(batches)
}

/// Lists share enrichment when at least half the requests have duplicate non-viewer arguments. Feed pages
/// depend on the viewer, but concurrent feeds overlap on popular authors, so their enrichment is shared from
/// three requests. Otherwise the plain batched query runs without materialization.
pub fn statement<'a>(batch: &'a Batch, frames: &[&Bytes]) -> &'a Statement {
    let share = if batch.feed {
        frames.len() >= 3
    } else {
        should_share(frames)
    };
    match &batch.shared {
        Some(shared) if share => shared,
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
    if count < 3 || frame.get(at + 2..at + 6)? != 8i32.to_be_bytes() {
        return None;
    }
    at += 14; // parameter count, first value length and its eight-byte viewer.
    frame.get(at..end)
}

/// `min(count, 1000)`: step to the 1000th row, and only count when there are fewer. Same form as sql.rs.
fn capped(rows: &str) -> String {
    format!(
        "SELECT CASE WHEN EXISTS ({rows} OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM ({rows} LIMIT 1000) s) END AS n"
    )
}

/// `min(count, 1000)` in one pass, for authors and favourites. Same form as sql.rs.
fn single(rows: &str) -> String {
    format!("SELECT count(*) AS n FROM ({rows} LIMIT 1000) s")
}

/// Enrich each distinct article once within this execution. Every request still
/// reads PostgreSQL while it is being served; no result is retained by the app.
/// Counts are computed once per distinct filter and pages once per distinct page key, except feeds, whose
/// pages and counts depend on the viewer. Each viewer's followee set and favourites among its page are read
/// once instead of probed per row.
fn shared_list(text: &str, args: &[String], names: &[String]) -> Option<String> {
    let (count, page) = if text == sql::LIST_ALL {
        (
            capped("SELECT 1 FROM articles ORDER BY id"),
            "SELECT id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.p3) bounded ORDER BY id DESC LIMIT r.p2",
        )
    } else if text == sql::LIST_TAG {
        (
            capped("SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4)"),
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.p4) ORDER BY at.article_id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_AUTHOR {
        (
            single("SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.p4)"),
            "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = r.p4) ORDER BY a2.id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_FAVORITED {
        (
            single("SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4)"),
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.p4) ORDER BY f.article_id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else if text == sql::LIST_FEED {
        (
            capped("SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.p1)) ORDER BY a3.author_id, a3.id DESC"),
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT r.p4) x WHERE fo.follower_id = r.p1 ORDER BY x.id DESC LIMIT r.p2 OFFSET r.p3",
        )
    } else {
        return None;
    };
    let feed = text == sql::LIST_FEED;
    let pages = if feed {
        format!(
            "counted AS MATERIALIZED (
         SELECT r.*, c.n FROM requests r CROSS JOIN LATERAL ({count}) c),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, r.n, p.id FROM counted r
         LEFT JOIN LATERAL ({page}) p ON true),"
        )
    } else {
        // page keys are limit, offset and any filter. counts depend on the filter alone
        let keys = names[1..].join(",");
        let (counted, join_count) = match names.get(3) {
            Some(filter) => (
                format!(
                    "filters AS MATERIALIZED (SELECT DISTINCT {filter} FROM requests),
         counted AS MATERIALIZED (SELECT r.*, c.n FROM filters r CROSS JOIN LATERAL ({count}) c),"
                ),
                format!("JOIN counted c USING ({filter})"),
            ),
            None => (
                format!("counted AS MATERIALIZED ({count}),"),
                "CROSS JOIN counted c".to_string(),
            ),
        };
        format!(
            "{counted}
         page_keys AS MATERIALIZED (SELECT DISTINCT {keys} FROM requests),
         keyed_pages AS MATERIALIZED (
         SELECT r.*, p.id FROM page_keys r LEFT JOIN LATERAL ({page}) p ON true),
         pages AS MATERIALIZED (
         SELECT r.ord, r.p1 AS viewer, c.n, k.id FROM requests r {join_count}
         JOIN keyed_pages k USING ({keys})),"
        )
    };
    // a feed page only holds followed authors
    let (follows, following) = if feed {
        ("", "true")
    } else {
        (
            ",
         followed AS MATERIALIZED (
         SELECT v.viewer, fo.followee_id FROM viewer_pages v JOIN follows fo ON fo.follower_id = v.viewer)",
            "fl.viewer IS NOT NULL",
        )
    };
    let follow_join = if feed {
        ""
    } else {
        "LEFT JOIN followed fl ON fl.viewer = p.viewer AND fl.followee_id = e.author_id"
    };
    Some(format!(
        "WITH requests AS MATERIALIZED (
         SELECT * FROM unnest({}) WITH ORDINALITY AS r({},ord)),
         {pages}
         article_ids AS MATERIALIZED (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL),
         page_tags AS MATERIALIZED (
         SELECT at.article_id AS id, array_agg(t.name ORDER BY t.name) AS tags
         FROM article_ids i JOIN article_tags at ON at.article_id = i.id JOIN tags t ON t.id = at.tag_id
         GROUP BY at.article_id),
         enriched AS MATERIALIZED (
         SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         pt.tags,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
         u.username, u.bio, u.image
         FROM article_ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id
         LEFT JOIN page_tags pt ON pt.id = a.id),
         viewer_pages AS MATERIALIZED (
         SELECT viewer, array_agg(id) AS ids FROM pages WHERE id IS NOT NULL GROUP BY viewer),
         favorited AS MATERIALIZED (
         SELECT v.viewer, f.article_id FROM viewer_pages v
         CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = v.viewer AND f.article_id = ANY(v.ids)) f){follows}
         SELECT p.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at,
         COALESCE(e.tags, ARRAY[]::text[]), COALESCE(e.fc, 0::bigint),
         fv.viewer IS NOT NULL,
         e.username, e.bio, e.image,
         {following},
         p.ord::bigint AS __request_id
         FROM pages p LEFT JOIN enriched e ON e.id = p.id
         LEFT JOIN favorited fv ON fv.viewer = p.viewer AND fv.article_id = e.id
         {follow_join}
         ORDER BY p.ord, e.id DESC",
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

    #[tokio::test]
    #[ignore = "requires TEST_DATABASE_URL pointing at an unchanged challenge seed"]
    async fn batched_reads_match_individual_queries() {
        use tokio_postgres::{NoTls, Row, types::ToSql};

        // compare binary values without adding a second implementation of response JSON
        #[derive(Debug, PartialEq)]
        struct Raw(Vec<u8>);
        impl<'a> FromSql<'a> for Raw {
            fn from_sql(
                ty: &Type,
                raw: &'a [u8],
            ) -> Result<Self, Box<dyn std::error::Error + Sync + Send>> {
                // under a byte-order collation tag arrays come unsorted and the response sorts them
                if *ty == Type::TEXT_ARRAY
                    && crate::json::SORT_TAGS.load(std::sync::atomic::Ordering::Relaxed)
                {
                    let mut tags = Vec::<String>::from_sql(ty, raw)?;
                    tags.sort_unstable();
                    return Ok(Self(tags.join("\0").into_bytes()));
                }
                Ok(Self(raw.to_vec()))
            }
            fn accepts(_: &Type) -> bool {
                true
            }
        }
        fn values(row: &Row, columns: usize) -> Vec<Option<Raw>> {
            (0..columns).map(|i| row.get(i)).collect()
        }

        let url = std::env::var("TEST_DATABASE_URL").expect("TEST_DATABASE_URL");
        let db = crate::db::Db::connect(&url, 1, 1).await.unwrap();
        let lease = db.read(crate::db::ReadKind::All);
        let (client, connection) = tokio_postgres::connect(&url, NoTls).await.unwrap();
        tokio::spawn(async move {
            connection.await.unwrap();
        });
        let batches = prepare(&client, &lease.st).await.unwrap();
        let author: String = client.query_one("SELECT u.username FROM users u JOIN articles a ON a.author_id=u.id ORDER BY a.id DESC LIMIT 1", &[]).await.unwrap().get(0);
        let tag: String = client
            .query_one("SELECT name FROM tags ORDER BY name LIMIT 1", &[])
            .await
            .unwrap()
            .get(0);
        let slug: String = client
            .query_one("SELECT slug FROM articles ORDER BY id DESC LIMIT 1", &[])
            .await
            .unwrap()
            .get(0);
        let comments = if std::env::var("READ_COMMENT_SET").ok().as_deref() == Some("1") {
            sql::COMMENTS_LIST_SET
        } else {
            sql::COMMENTS_LIST
        };
        // anonymous, heavy followers, and users who favourited the newest articles, so flags are exercised
        let mut viewers = vec![0i64];
        for q in [
            "SELECT follower_id FROM follows GROUP BY 1 ORDER BY count(*) DESC LIMIT 3",
            "SELECT user_id FROM favorites WHERE article_id IN (SELECT id FROM articles ORDER BY id DESC LIMIT 50) GROUP BY 1 ORDER BY count(*) DESC LIMIT 4",
        ] {
            for row in client.query(q, &[]).await.unwrap() {
                viewers.push(row.get(0));
            }
        }
        while viewers.len() < 8 {
            viewers.push(viewers.len() as i64);
        }
        for (st, text, filter) in [
            (&lease.st.list_all, sql::LIST_ALL, None),
            (&lease.st.list_feed, sql::LIST_FEED, None),
            (&lease.st.list_tag, sql::LIST_TAG, Some(tag.as_str())),
            (
                &lease.st.list_author,
                sql::LIST_AUTHOR,
                Some(author.as_str()),
            ),
            (
                &lease.st.list_favorited,
                sql::LIST_FAVORITED,
                Some(author.as_str()),
            ),
            (&lease.st.comments_list, comments, Some(slug.as_str())),
        ] {
            let batch = batches.iter().find(|b| same(&b.original, st)).unwrap();
            let original = client.prepare_typed(text, st.params()).await.unwrap();
            for missing in [false, true] {
                let mut frames = Vec::new();
                let mut expected = Vec::new();
                for i in 0..8i64 {
                    let viewer = viewers[i as usize];
                    let limit = if i % 4 == 0 { 1i64 } else { 10 };
                    let offset = if i % 4 == 0 { 10i64 } else { 0 };
                    let filter = if missing {
                        "missing-filter"
                    } else {
                        filter.unwrap_or("")
                    };
                    let depth = limit + offset;
                    let params: Vec<&(dyn ToSql + Sync)> = if text == comments {
                        vec![&viewer, &filter]
                    } else if text == sql::LIST_FEED {
                        vec![&viewer, &limit, &offset, &depth]
                    } else if st.params().len() == 4 {
                        vec![&viewer, &limit, &offset, &filter]
                    } else {
                        vec![&viewer, &limit, &offset]
                    };
                    expected.push(client.query(&original, &params).await.unwrap());
                    frames.push(
                        tokio_postgres::Client::encode_group_query(&original, &params).unwrap(),
                    );
                }
                let refs: Vec<_> = frames.iter().collect();
                let encoded = arrays(&refs, original.params()).unwrap();
                // Bytes encodes bytea, so transposed arrays need their own wire types
                struct ArrayParam<'a>(&'a Bytes);
                impl ToSql for ArrayParam<'_> {
                    fn to_sql(
                        &self,
                        _: &Type,
                        out: &mut BytesMut,
                    ) -> Result<postgres_types::IsNull, Box<dyn std::error::Error + Sync + Send>>
                    {
                        out.extend_from_slice(self.0);
                        Ok(postgres_types::IsNull::No)
                    }
                    fn accepts(_: &Type) -> bool {
                        true
                    }
                    postgres_types::to_sql_checked!();
                }
                impl std::fmt::Debug for ArrayParam<'_> {
                    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                        f.write_str("ArrayParam")
                    }
                }
                let params: Vec<_> = encoded.iter().map(ArrayParam).collect();
                let params: Vec<&(dyn ToSql + Sync)> =
                    params.iter().map(|p| p as &(dyn ToSql + Sync)).collect();
                let mut statements = vec![&batch.statement];
                if let Some(shared) = &batch.shared {
                    statements.push(shared);
                }
                for statement in statements {
                    let rows = client.query(statement, &params).await.unwrap();
                    for (i, expected) in expected.iter().enumerate() {
                        let actual: Vec<_> = rows
                            .iter()
                            .filter(|r| r.get::<_, i64>(r.len() - 1) == i as i64 + 1)
                            .collect();
                        assert_eq!(actual.len(), expected.len());
                        for (actual, expected) in actual.into_iter().zip(expected) {
                            assert_eq!(
                                values(actual, expected.len()),
                                values(expected, expected.len())
                            );
                        }
                    }
                }
            }
        }
    }
}
