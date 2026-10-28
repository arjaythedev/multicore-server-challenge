//! The reference answers of SPEC.md: the specification's own SQL, one request at a time, rendered with the same
//! `render.rs` functions the lanes use. Tests compare the lanes' bytes against these; the benchmark uses it as the
//! unbatched baseline.

use crate::app::jobs::{ListKind, ReadKind};
use crate::json::JsonWriter;
use crate::pg::{Connection, INT8, Param, PgError, Results, Row, Stmt, TEXT};
use crate::render::{self, Profile};

/// A request in test terms (owned strings instead of ranges into a buffer).
#[derive(Clone, Debug)]
pub struct Req {
    pub kind: ReadKind,
    pub viewer: i64,
    pub key: String,
    pub limit: i64,
    pub offset: i64,
}

impl Req {
    pub fn list(kind: ListKind, viewer: i64, key: &str, limit: i64, offset: i64) -> Req {
        Req {
            kind: ReadKind::List(kind),
            viewer,
            key: key.to_owned(),
            limit,
            offset,
        }
    }

    pub fn keyed(kind: ReadKind, viewer: i64, key: &str) -> Req {
        Req {
            kind,
            viewer,
            key: key.to_owned(),
            limit: 0,
            offset: 0,
        }
    }
}

/// What a request answers: status and body.
#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Answer {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Answer {
    fn ok(body: Vec<u8>) -> Answer {
        Answer { status: 200, body }
    }
    fn status_only(status: u16) -> Answer {
        Answer {
            status,
            body: Vec::new(),
        }
    }
}

const FAVORITED_BY_VIEWER: &str =
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)";
const FOLLOWED_BY_VIEWER: &str =
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)";

/// ARTICLE_LIST_SELECT (or ARTICLE_FULL_SELECT with the body) of SPEC.md.
fn article_select(with_body: bool) -> String {
    format!(
        "SELECT a.id, a.slug, a.title, a.description, {body} a.created_at, a.updated_at, \
         ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
         {FAVORITED_BY_VIEWER} AS favorited, u.username, u.bio, u.image, {FOLLOWED_BY_VIEWER} AS following \
         FROM articles a JOIN users u ON u.id = a.author_id ",
        body = if with_body { "a.body," } else { "" }
    )
}

const LIST_PARAMS: &[u32] = &[INT8, INT8, INT8, TEXT];
const COUNT_CAP: &str = "SELECT count(*) FROM (SELECT 1 FROM ";

/// Prepared reference statements of one connection.
pub struct Reference {
    page: [Stmt; 5],
    count: [Stmt; 5],
    article: Stmt,
    article_id: Stmt,
    comments: Stmt,
    profile: Stmt,
    current_user: Stmt,
    tags: Stmt,
}

const LISTS: [ListKind; 5] = [
    ListKind::All,
    ListKind::Tag,
    ListKind::Author,
    ListKind::Favorited,
    ListKind::Feed,
];

fn list_slot(kind: ListKind) -> usize {
    LISTS.iter().position(|k| *k == kind).unwrap_or(0)
}

impl Reference {
    pub fn prepare(conn: &mut Connection) -> Result<Reference, PgError> {
        let list = article_select(false);
        let pages = [
            format!("{list} ORDER BY a.id DESC LIMIT $2 OFFSET $3"),
            format!(
                "{list} WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
            ),
            format!(
                "{list} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3"
            ),
            format!(
                "{list} WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
            ),
            format!(
                "{list} WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
            ),
        ];
        let counts = [
            (format!("{COUNT_CAP}articles a LIMIT 1000) s"), &[][..]),
            (
                format!(
                    "{COUNT_CAP}article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"
                ),
                &[TEXT][..],
            ),
            (
                format!(
                    "{COUNT_CAP}articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"
                ),
                &[TEXT][..],
            ),
            (
                format!(
                    "{COUNT_CAP}favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"
                ),
                &[TEXT][..],
            ),
            (
                format!(
                    "{COUNT_CAP}articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"
                ),
                &[INT8][..],
            ),
        ];
        let mut page = Vec::new();
        let mut count = Vec::new();
        for (i, sql) in pages.iter().enumerate() {
            page.push(conn.prepare(&format!("ref_page_{i}"), sql, LIST_PARAMS)?);
            count.push(conn.prepare(&format!("ref_count_{i}"), &counts[i].0, counts[i].1)?);
        }
        Ok(Reference {
            page: page.try_into().map_err(|_| PgError::Poisoned)?,
            count: count.try_into().map_err(|_| PgError::Poisoned)?,
            article: conn.prepare("ref_article", &format!("{} WHERE a.slug = $2", article_select(true)), &[INT8, TEXT])?,
            article_id: conn.prepare("ref_article_id", "SELECT id FROM articles WHERE slug = $1", &[TEXT])?,
            comments: conn.prepare(
                "ref_comments",
                "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
                 FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = $2 \
                 ORDER BY c.created_at DESC, c.id DESC LIMIT 100",
                &[INT8, INT8],
            )?,
            profile: conn.prepare(
                "ref_profile",
                "SELECT u.id, u.username, u.bio, u.image, \
                 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
                 FROM users u WHERE u.username = $2",
                &[INT8, TEXT],
            )?,
            current_user: conn.prepare(
                "ref_current_user",
                "SELECT id, username, email, bio, image FROM users WHERE id = $1",
                &[INT8],
            )?,
            tags: conn.prepare("ref_tags", "SELECT name FROM tags ORDER BY name", &[])?,
        })
    }

    /// Runs the statements of `req` the way the spec lists them (a lookup that finds nothing stops the request) and
    /// returns the rendered answer. `results` is scratch.
    pub fn answer(
        &self,
        conn: &mut Connection,
        results: &mut Results,
        req: &Req,
    ) -> Result<Answer, PgError> {
        match req.kind {
            ReadKind::List(kind) => self.list(conn, results, req, kind),
            ReadKind::Article => self.article(conn, results, req),
            ReadKind::Comments => self.comments(conn, results, req),
            ReadKind::Profile => self.profile(conn, results, req),
            ReadKind::CurrentUser => self.current_user(conn, results, req),
            ReadKind::Tags => self.tags(conn, results),
            ReadKind::LoginLookup => Ok(Answer::status_only(0)),
        }
    }

    fn run(
        conn: &mut Connection,
        results: &mut Results,
        stmts: &[(&Stmt, &[Param<'_>])],
    ) -> Result<(), PgError> {
        for (stmt, params) in stmts {
            conn.push(stmt, params)?;
        }
        conn.flush_and_collect(results)?;
        for i in 0..results.len() {
            if let Some(e) = results.statement(i).error() {
                return Err(PgError::Server(e.clone()));
            }
        }
        Ok(())
    }

    fn list(
        &self,
        conn: &mut Connection,
        results: &mut Results,
        req: &Req,
        kind: ListKind,
    ) -> Result<Answer, PgError> {
        let slot = list_slot(kind);
        let key = Param::Text(&req.key);
        let page_params = [
            Param::Int8(req.viewer),
            Param::Int8(req.limit),
            Param::Int8(req.offset),
            key,
        ];
        let count_params: &[Param<'_>] = match kind {
            ListKind::All => &[],
            ListKind::Feed => &[Param::Int8(req.viewer)],
            _ => &[key],
        };
        Self::run(
            conn,
            results,
            &[
                (&self.page[slot], &page_params),
                (&self.count[slot], count_params),
            ],
        )?;
        let total = results.statement(1).row(0).map_or(Ok(0), |r| r.i64(0))?;
        let mut body = Vec::new();
        let mut w = JsonWriter::new(&mut body);
        w.begin_object();
        w.key("articles");
        w.begin_array();
        for row in results.statement(0).rows() {
            write_article(&mut w, row, false)?;
        }
        w.end_array();
        w.key("articlesCount");
        w.int(total);
        w.end_object();
        Ok(Answer::ok(body))
    }

    fn article(
        &self,
        conn: &mut Connection,
        results: &mut Results,
        req: &Req,
    ) -> Result<Answer, PgError> {
        Self::run(
            conn,
            results,
            &[(
                &self.article,
                &[Param::Int8(req.viewer), Param::Text(&req.key)],
            )],
        )?;
        let Some(row) = results.statement(0).row(0) else {
            return Ok(Answer::status_only(404));
        };
        let mut body = Vec::new();
        let mut w = JsonWriter::new(&mut body);
        w.begin_object();
        w.key("article");
        write_article(&mut w, row, true)?;
        w.end_object();
        Ok(Answer::ok(body))
    }

    fn comments(
        &self,
        conn: &mut Connection,
        results: &mut Results,
        req: &Req,
    ) -> Result<Answer, PgError> {
        Self::run(
            conn,
            results,
            &[(&self.article_id, &[Param::Text(&req.key)])],
        )?;
        let Some(id) = results.statement(0).row(0).map(|r| r.i64(0)).transpose()? else {
            return Ok(Answer::status_only(404));
        };
        Self::run(
            conn,
            results,
            &[(&self.comments, &[Param::Int8(req.viewer), Param::Int8(id)])],
        )?;
        let mut body = Vec::new();
        let mut w = JsonWriter::new(&mut body);
        w.begin_object();
        w.key("comments");
        w.begin_array();
        for row in results.statement(0).rows() {
            render::comment_object(
                &mut w,
                &render::Comment {
                    id: row.i64(0)?,
                    created_micros: row.timestamptz_micros(2)?,
                    updated_micros: row.timestamptz_micros(3)?,
                    body: row.str(1)?,
                    author: Profile {
                        username: row.str(4)?,
                        bio: opt(row, 5)?,
                        image: opt(row, 6)?,
                        following: row.bool(7)?,
                    },
                },
            );
        }
        w.end_array();
        w.end_object();
        Ok(Answer::ok(body))
    }

    fn profile(
        &self,
        conn: &mut Connection,
        results: &mut Results,
        req: &Req,
    ) -> Result<Answer, PgError> {
        Self::run(
            conn,
            results,
            &[(
                &self.profile,
                &[Param::Int8(req.viewer), Param::Text(&req.key)],
            )],
        )?;
        let Some(row) = results.statement(0).row(0) else {
            return Ok(Answer::status_only(404));
        };
        let mut body = Vec::new();
        let mut w = JsonWriter::new(&mut body);
        w.begin_object();
        w.key("profile");
        render::profile_object(
            &mut w,
            &Profile {
                username: row.str(1)?,
                bio: opt(row, 2)?,
                image: opt(row, 3)?,
                following: row.bool(4)?,
            },
        );
        w.end_object();
        Ok(Answer::ok(body))
    }

    /// The token is not part of the reference: the caller supplies the one the request presented in `req.key`.
    fn current_user(
        &self,
        conn: &mut Connection,
        results: &mut Results,
        req: &Req,
    ) -> Result<Answer, PgError> {
        Self::run(
            conn,
            results,
            &[(&self.current_user, &[Param::Int8(req.viewer)])],
        )?;
        let Some(row) = results.statement(0).row(0) else {
            return Ok(Answer::status_only(401));
        };
        let mut body = Vec::new();
        let mut w = JsonWriter::new(&mut body);
        w.begin_object();
        w.key("user");
        render::user_object(
            &mut w,
            &render::User {
                email: row.str(2)?,
                token: &req.key,
                username: row.str(1)?,
                bio: opt(row, 3)?,
                image: opt(row, 4)?,
            },
        );
        w.end_object();
        Ok(Answer::ok(body))
    }

    fn tags(&self, conn: &mut Connection, results: &mut Results) -> Result<Answer, PgError> {
        Self::run(conn, results, &[(&self.tags, &[])])?;
        let mut body = Vec::new();
        let mut w = JsonWriter::new(&mut body);
        w.begin_object();
        w.key("tags");
        w.begin_array();
        for row in results.statement(0).rows() {
            w.string(row.str(0)?);
        }
        w.end_array();
        w.end_object();
        Ok(Answer::ok(body))
    }
}

fn opt<'a>(row: Row<'a>, col: usize) -> Result<Option<&'a str>, PgError> {
    if row.is_null(col) {
        Ok(None)
    } else {
        row.str(col).map(Some)
    }
}

/// One row of ARTICLE_LIST_SELECT / ARTICLE_FULL_SELECT as an Article object.
fn write_article(w: &mut JsonWriter<'_>, row: Row<'_>, with_body: bool) -> Result<(), PgError> {
    let b = usize::from(with_body);
    render::article_object(
        w,
        &render::Article {
            slug: row.str(1)?,
            title: row.str(2)?,
            description: row.str(3)?,
            body: if with_body { Some(row.str(4)?) } else { None },
            tags: row.text_array(6 + b)?,
            created_micros: row.timestamptz_micros(4 + b)?,
            updated_micros: row.timestamptz_micros(5 + b)?,
            favorited: row.bool(8 + b)?,
            favorites_count: row.i64(7 + b)?,
            author: Profile {
                username: row.str(9 + b)?,
                bio: opt(row, 10 + b)?,
                image: opt(row, 11 + b)?,
                following: row.bool(12 + b)?,
            },
        },
    );
    Ok(())
}
