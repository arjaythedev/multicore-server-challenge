//! Request queueing, worker pools, and database statement execution.

use std::os::unix::io::RawFd;
use std::sync::mpsc::Receiver;
use crate::app::handlers::*;
use crate::app::queries::*;
use crate::config::ServerConfig;
use crate::crypto::bcrypt::{hash_password, verify_password};
use crate::crypto::jwt::generate_token;
use crate::json_out::*;
use crate::pg::client::{PgClient, PgConnectionInfo};
use crate::pg::proto::{decode_text_array, INT8_OID, TEXT_OID};
use crate::time_fmt::format_pg_timestamp;

#[inline]
pub fn direct_send(fd: RawFd, data: &[u8]) {
    unsafe {
        libc::send(
            fd,
            data.as_ptr() as *const libc::c_void,
            data.len(),
            libc::MSG_NOSIGNAL | libc::MSG_DONTWAIT,
        );
    }
}

pub enum ReadRequest {
    GetTags {
        fd: RawFd,
        keep_alive: bool,
    },
    GetUser {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        presented_token: String,
    },
    GetProfile {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        username: String,
    },
    GetArticle {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
    },
    ListArticles {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        limit: usize,
        offset: usize,
        tag: Option<String>,
        author: Option<String>,
        favorited: Option<String>,
    },
    FeedArticles {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        limit: usize,
        offset: usize,
    },
    GetComments {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
    },
}

pub enum WriteRequest {
    RegisterUser {
        fd: RawFd,
        keep_alive: bool,
        username: String,
        email: String,
        password: String,
    },
    UpdateUser {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        presented_token: String,
        email: Option<String>,
        username: Option<String>,
        password: Option<String>,
        bio: Option<Option<String>>,
        image: Option<Option<String>>,
    },
    FollowUser {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        username: String,
        follow: bool,
    },
    CreateArticle {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        title: String,
        description: String,
        body: String,
        tag_list: Vec<String>,
    },
    UpdateArticle {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
        title: Option<String>,
        description: Option<String>,
        body: Option<String>,
    },
    DeleteArticle {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
    },
    FavoriteArticle {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
        favorite: bool,
    },
    CreateComment {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
        body: String,
    },
    DeleteComment {
        fd: RawFd,
        keep_alive: bool,
        viewer: u64,
        slug: String,
        comment_id: i64,
    },
}

pub struct BcryptRequest {
    pub fd: RawFd,
    pub keep_alive: bool,
    pub email: String,
    pub password: String,
}

pub fn run_read_worker(rx: Receiver<ReadRequest>, config: ServerConfig) {
    let info = PgConnectionInfo::parse(&config.db_url).expect("Invalid DATABASE_URL");
    let mut pg = PgClient::connect(&info).expect("Read lane failed to connect to Postgres");

    // Prepare read statements
    pg.prepare("stmt_tags", SQL_TAGS, &[]).ok();
    pg.prepare("stmt_get_user", SQL_GET_CURRENT_USER, &[INT8_OID]).ok();
    pg.prepare("stmt_get_profile", SQL_GET_PROFILE, &[INT8_OID, TEXT_OID]).ok();
    pg.prepare("stmt_get_art", SQL_GET_ARTICLE_BY_SLUG, &[INT8_OID, TEXT_OID]).ok();
    pg.prepare("stmt_art_id", SQL_FIND_ARTICLE_ID, &[TEXT_OID]).ok();
    pg.prepare("stmt_comments", SQL_GET_COMMENTS, &[INT8_OID, INT8_OID]).ok();

    while let Ok(req) = rx.recv() {
        match req {
            ReadRequest::GetTags { fd, keep_alive } => {
                match pg.execute_prepared("stmt_tags", &[]) {
                    Ok(rows) => {
                        let mut tags = Vec::with_capacity(rows.len());
                        for r in &rows {
                            if let Some(Some(bytes)) = r.columns.get(0) {
                                if let Ok(s) = std::str::from_utf8(bytes) {
                                    tags.push(s);
                                }
                            }
                        }
                        let body = format_tags_json(&tags);
                        let resp = make_http_response(200, "OK", &body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    Err(_) => {
                        let resp = make_error_response(500, "Internal Server Error", "Database error", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            ReadRequest::GetUser { fd, keep_alive, viewer, presented_token } => {
                let viewer_bytes = (viewer as i64).to_be_bytes();
                match pg.execute_prepared("stmt_get_user", &[&viewer_bytes]) {
                    Ok(rows) if !rows.is_empty() => {
                        let r = &rows[0];
                        let username = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let email = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let bio = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let image = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());

                        let body = format_user_json(email, &presented_token, username, bio, image);
                        let resp = make_http_response(200, "OK", &body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            ReadRequest::GetProfile { fd, keep_alive, viewer, username } => {
                let viewer_bytes = (viewer as i64).to_be_bytes();
                match pg.execute_prepared("stmt_get_profile", &[&viewer_bytes, username.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let r = &rows[0];
                        let uname = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&username);
                        let bio = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let image = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let following = r.columns.get(4).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                        let body = format_profile_json(uname, bio, image, following);
                        let resp = make_http_response(200, "OK", &body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            ReadRequest::GetArticle { fd, keep_alive, viewer, slug } => {
                let viewer_bytes = (viewer as i64).to_be_bytes();
                match pg.execute_prepared("stmt_get_art", &[&viewer_bytes, slug.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let r = &rows[0];
                        let art_slug = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&slug);
                        let title = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let desc = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let body_text = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let created_at = r.columns.get(5).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                        let updated_at = r.columns.get(6).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                        let tags = r.columns.get(7).and_then(|c| c.as_deref()).map(decode_text_array).unwrap_or_default();
                        let fav_count = r.columns.get(8).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let favorited = r.columns.get(9).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);
                        let author_uname = r.columns.get(10).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let author_bio = r.columns.get(11).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let author_img = r.columns.get(12).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let author_following = r.columns.get(13).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                        let resp_body = format_article_json(
                            art_slug,
                            title,
                            desc,
                            body_text,
                            &tags,
                            std::str::from_utf8(&created_at).unwrap_or(""),
                            std::str::from_utf8(&updated_at).unwrap_or(""),
                            favorited,
                            fav_count,
                            author_uname,
                            author_bio,
                            author_img,
                            author_following,
                        );
                        let resp = make_http_response(200, "OK", &resp_body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            ReadRequest::ListArticles { fd, keep_alive, viewer, limit, offset, tag, author, favorited } => {
                let (page_sql, count_sql, filter_val) = if let Some(ref t) = tag {
                    (
                        format!("{} WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC;", ARTICLE_LIST_SELECT),
                        "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s;".to_string(),
                        Some(t.as_str()),
                    )
                } else if let Some(ref au) = author {
                    (
                        format!("{} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3;", ARTICLE_LIST_SELECT),
                        "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s;".to_string(),
                        Some(au.as_str()),
                    )
                } else if let Some(ref fav) = favorited {
                    (
                        format!("{} WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC;", ARTICLE_LIST_SELECT),
                        "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s;".to_string(),
                        Some(fav.as_str()),
                    )
                } else {
                    (
                        format!("{} ORDER BY a.id DESC LIMIT $2 OFFSET $3;", ARTICLE_LIST_SELECT),
                        "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s;".to_string(),
                        None,
                    )
                };

                let viewer_bytes = (viewer as i64).to_be_bytes();
                let limit_bytes = (limit as i64).to_be_bytes();
                let offset_bytes = (offset as i64).to_be_bytes();

                let (page_rows, count_rows) = if let Some(val) = filter_val {
                    let p_stmt = format!("p_list_{}", limit);
                    let c_stmt = format!("c_list_{}", limit);
                    pg.prepare(&p_stmt, &page_sql, &[INT8_OID, INT8_OID, INT8_OID, TEXT_OID]).ok();
                    pg.prepare(&c_stmt, &count_sql, &[TEXT_OID]).ok();

                    let p_res = pg.execute_prepared(&p_stmt, &[&viewer_bytes, &limit_bytes, &offset_bytes, val.as_bytes()]);
                    let c_res = pg.execute_prepared(&c_stmt, &[val.as_bytes()]);
                    (p_res.unwrap_or_default(), c_res.unwrap_or_default())
                } else {
                    let p_stmt = format!("p_none_{}", limit);
                    let c_stmt = format!("c_none_{}", limit);
                    pg.prepare(&p_stmt, &page_sql, &[INT8_OID, INT8_OID, INT8_OID]).ok();
                    pg.prepare(&c_stmt, &count_sql, &[]).ok();

                    let p_res = pg.execute_prepared(&p_stmt, &[&viewer_bytes, &limit_bytes, &offset_bytes]);
                    let c_res = pg.execute_prepared(&c_stmt, &[]);
                    (p_res.unwrap_or_default(), c_res.unwrap_or_default())
                };

                let count = count_rows.first().and_then(|r| r.columns.get(0)).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);

                let mut out = Vec::with_capacity(1024);
                out.extend_from_slice(b"{\"articles\":[");
                for (i, r) in page_rows.iter().enumerate() {
                    if i > 0 {
                        out.push(b',');
                    }
                    let slug = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let title = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let desc = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let created_at = r.columns.get(4).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                    let updated_at = r.columns.get(5).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                    let tags = r.columns.get(6).and_then(|c| c.as_deref()).map(decode_text_array).unwrap_or_default();
                    let fav_count = r.columns.get(7).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                    let favorited = r.columns.get(8).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);
                    let author_uname = r.columns.get(9).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let author_bio = r.columns.get(10).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                    let author_img = r.columns.get(11).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                    let author_following = r.columns.get(12).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                    write_article_json(
                        &mut out,
                        slug,
                        title,
                        desc,
                        None,
                        &tags,
                        std::str::from_utf8(&created_at).unwrap_or(""),
                        std::str::from_utf8(&updated_at).unwrap_or(""),
                        favorited,
                        fav_count,
                        author_uname,
                        author_bio,
                        author_img,
                        author_following,
                    );
                }
                out.extend_from_slice(b"],\"articlesCount\":");
                append_i64(&mut out, count);
                out.push(b'}');

                let resp = make_http_response(200, "OK", &out, keep_alive);
                direct_send(fd, &resp);
            }
            ReadRequest::FeedArticles { fd, keep_alive, viewer, limit, offset } => {
                let feed_sql = format!("{} WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC;", ARTICLE_LIST_SELECT);
                let count_sql = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s;".to_string();

                let viewer_bytes = (viewer as i64).to_be_bytes();
                let limit_bytes = (limit as i64).to_be_bytes();
                let offset_bytes = (offset as i64).to_be_bytes();

                pg.prepare("p_feed", &feed_sql, &[INT8_OID, INT8_OID, INT8_OID]).ok();
                pg.prepare("c_feed", &count_sql, &[INT8_OID]).ok();

                let page_rows = pg.execute_prepared("p_feed", &[&viewer_bytes, &limit_bytes, &offset_bytes]).unwrap_or_default();
                let count_rows = pg.execute_prepared("c_feed", &[&viewer_bytes]).unwrap_or_default();
                let count = count_rows.first().and_then(|r| r.columns.get(0)).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);

                let mut out = Vec::with_capacity(1024);
                out.extend_from_slice(b"{\"articles\":[");
                for (i, r) in page_rows.iter().enumerate() {
                    if i > 0 {
                        out.push(b',');
                    }
                    let slug = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let title = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let desc = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let created_at = r.columns.get(4).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                    let updated_at = r.columns.get(5).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                    let tags = r.columns.get(6).and_then(|c| c.as_deref()).map(decode_text_array).unwrap_or_default();
                    let fav_count = r.columns.get(7).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                    let favorited = r.columns.get(8).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);
                    let author_uname = r.columns.get(9).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                    let author_bio = r.columns.get(10).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                    let author_img = r.columns.get(11).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                    let author_following = r.columns.get(12).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                    write_article_json(
                        &mut out,
                        slug,
                        title,
                        desc,
                        None,
                        &tags,
                        std::str::from_utf8(&created_at).unwrap_or(""),
                        std::str::from_utf8(&updated_at).unwrap_or(""),
                        favorited,
                        fav_count,
                        author_uname,
                        author_bio,
                        author_img,
                        author_following,
                    );
                }
                out.extend_from_slice(b"],\"articlesCount\":");
                append_i64(&mut out, count);
                out.push(b'}');

                let resp = make_http_response(200, "OK", &out, keep_alive);
                direct_send(fd, &resp);
            }
            ReadRequest::GetComments { fd, keep_alive, viewer, slug } => {
                let viewer_bytes = (viewer as i64).to_be_bytes();
                match pg.execute_prepared("stmt_art_id", &[slug.as_bytes()]) {
                    Ok(art_rows) if !art_rows.is_empty() => {
                        let art_id_bytes = art_rows[0].columns[0].as_ref().unwrap();
                        let comments = pg.execute_prepared("stmt_comments", &[&viewer_bytes, art_id_bytes]).unwrap_or_default();

                        let mut out = Vec::with_capacity(512);
                        out.extend_from_slice(b"{\"comments\":[");
                        for (i, c) in comments.iter().enumerate() {
                            if i > 0 {
                                out.push(b',');
                            }
                            let cid = c.columns.get(0).and_then(|col| col.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                            let body = c.columns.get(1).and_then(|col| col.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                            let created_at = c.columns.get(2).and_then(|col| col.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                            let updated_at = c.columns.get(3).and_then(|col| col.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                            let uname = c.columns.get(4).and_then(|col| col.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                            let bio = c.columns.get(5).and_then(|col| col.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                            let img = c.columns.get(6).and_then(|col| col.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                            let following = c.columns.get(7).and_then(|col| col.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                            write_comment_json(
                                &mut out,
                                cid,
                                std::str::from_utf8(&created_at).unwrap_or(""),
                                std::str::from_utf8(&updated_at).unwrap_or(""),
                                body,
                                uname,
                                bio,
                                img,
                                following,
                            );
                        }
                        out.extend_from_slice(b"]}");
                        let resp = make_http_response(200, "OK", &out, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
        }
    }
}

pub fn run_write_worker(rx: Receiver<WriteRequest>, config: ServerConfig) {
    let info = PgConnectionInfo::parse(&config.db_url).expect("Invalid DATABASE_URL");
    let mut pg = PgClient::connect(&info).expect("Write lane failed to connect to Postgres");

    // Prepare write statements
    pg.prepare("stmt_reg", SQL_REGISTER_USER, &[TEXT_OID, TEXT_OID, TEXT_OID]).ok();
    pg.prepare("stmt_upd_user", SQL_UPDATE_USER, &[INT8_OID, TEXT_OID, TEXT_OID, TEXT_OID, TEXT_OID, TEXT_OID]).ok();
    pg.prepare("stmt_find_user", SQL_FIND_USER_BY_NAME, &[TEXT_OID]).ok();
    pg.prepare("stmt_follow", SQL_FOLLOW_USER, &[INT8_OID, INT8_OID]).ok();
    pg.prepare("stmt_unfollow", SQL_UNFOLLOW_USER, &[INT8_OID, INT8_OID]).ok();
    pg.prepare("stmt_create_art", SQL_CREATE_ARTICLE, &[INT8_OID, TEXT_OID, TEXT_OID, TEXT_OID]).ok();
    pg.prepare("stmt_get_art_id", SQL_GET_ARTICLE_BY_ID, &[INT8_OID, INT8_OID]).ok();
    pg.prepare("stmt_find_author", SQL_FIND_ARTICLE_AUTHOR, &[TEXT_OID]).ok();
    pg.prepare("stmt_find_art_id", SQL_FIND_ARTICLE_ID, &[TEXT_OID]).ok();
    pg.prepare("stmt_upd_art", SQL_UPDATE_ARTICLE, &[INT8_OID, TEXT_OID, TEXT_OID, TEXT_OID]).ok();
    pg.prepare("stmt_del_art", SQL_DELETE_ARTICLE, &[INT8_OID]).ok();
    pg.prepare("stmt_fav", SQL_FAVORITE_ARTICLE, &[INT8_OID, INT8_OID]).ok();
    pg.prepare("stmt_unfav", SQL_UNFAVORITE_ARTICLE, &[INT8_OID, INT8_OID]).ok();
    pg.prepare("stmt_create_comm", SQL_CREATE_COMMENT, &[INT8_OID, INT8_OID, TEXT_OID]).ok();
    pg.prepare("stmt_find_comm", SQL_FIND_COMMENT_AUTHOR, &[INT8_OID, TEXT_OID]).ok();
    pg.prepare("stmt_del_comm", SQL_DELETE_COMMENT, &[INT8_OID]).ok();

    while let Ok(req) = rx.recv() {
        match req {
            WriteRequest::RegisterUser { fd, keep_alive, username, email, password } => {
                let hashed = hash_password(&password);
                match pg.execute_prepared("stmt_reg", &[username.as_bytes(), email.as_bytes(), hashed.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let r = &rows[0];
                        let id = r.columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let uname = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&username);
                        let uemail = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&email);
                        let bio = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let image = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());

                        let token = generate_token(id as u64, &config.jwt_secret);
                        let body = format_user_json(uemail, &token, uname, bio, image);
                        let resp = make_http_response(201, "Created", &body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(422, "Unprocessable Entity", "Username or email already taken", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::UpdateUser { fd, keep_alive, viewer, presented_token, email, username, password, bio, image } => {
                let viewer_bytes = (viewer as i64).to_be_bytes();
                let hashed_pwd = password.as_deref().map(hash_password);

                let email_param = email.as_deref().map(|s| s.as_bytes()).unwrap_or(b"");
                let uname_param = username.as_deref().map(|s| s.as_bytes()).unwrap_or(b"");
                let pwd_param = hashed_pwd.as_deref().map(|s| s.as_bytes()).unwrap_or(b"");
                let bio_param = bio.as_ref().and_then(|b| b.as_deref()).map(|s| s.as_bytes()).unwrap_or(b"");
                let img_param = image.as_ref().and_then(|i| i.as_deref()).map(|s| s.as_bytes()).unwrap_or(b"");

                match pg.execute_prepared("stmt_upd_user", &[&viewer_bytes, email_param, uname_param, pwd_param, bio_param, img_param]) {
                    Ok(rows) if !rows.is_empty() => {
                        let r = &rows[0];
                        let uname = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let uemail = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                        let ubio = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let uimg = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());

                        let body = format_user_json(uemail, &presented_token, uname, ubio, uimg);
                        let resp = make_http_response(200, "OK", &body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(422, "Unprocessable Entity", "Update failed", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::FollowUser { fd, keep_alive, viewer, username, follow } => {
                match pg.execute_prepared("stmt_find_user", &[username.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let r = &rows[0];
                        let target_id = r.columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let uname = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&username);
                        let bio = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                        let image = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());

                        let viewer_bytes = (viewer as i64).to_be_bytes();
                        let target_bytes = target_id.to_be_bytes();
                        if follow {
                            pg.execute_prepared("stmt_follow", &[&viewer_bytes, &target_bytes]).ok();
                        } else {
                            pg.execute_prepared("stmt_unfollow", &[&viewer_bytes, &target_bytes]).ok();
                        }

                        let body = format_profile_json(uname, bio, image, follow);
                        let resp = make_http_response(200, "OK", &body, keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::CreateArticle { fd, keep_alive, viewer, title, description, body, tag_list } => {
                let viewer_bytes = (viewer as i64).to_be_bytes();
                pg.simple_query("BEGIN;").ok();

                let res = pg.execute_prepared("stmt_create_art", &[&viewer_bytes, title.as_bytes(), description.as_bytes(), body.as_bytes()]);
                match res {
                    Ok(rows) if !rows.is_empty() => {
                        let art_id = rows[0].columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let art_id_bytes = art_id.to_be_bytes();

                        if !tag_list.is_empty() {
                            for tag in &tag_list {
                                let ins_tag = format!("INSERT INTO tags (name) VALUES ('{}') ON CONFLICT (name) DO NOTHING;", tag.replace('\'', "''"));
                                pg.simple_query(&ins_tag).ok();
                                let ins_art_tag = format!("INSERT INTO article_tags (article_id, tag_id) SELECT {}, id FROM tags WHERE name = '{}';", art_id, tag.replace('\'', "''"));
                                pg.simple_query(&ins_art_tag).ok();
                            }
                        }
                        pg.simple_query("COMMIT;").ok();

                        match pg.execute_prepared("stmt_get_art_id", &[&viewer_bytes, &art_id_bytes]) {
                            Ok(art_rows) if !art_rows.is_empty() => {
                                let r = &art_rows[0];
                                let slug = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let title_str = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&title);
                                let desc_str = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&description);
                                let body_str = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&body);
                                let created_at = r.columns.get(5).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let updated_at = r.columns.get(6).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let tags = r.columns.get(7).and_then(|c| c.as_deref()).map(decode_text_array).unwrap_or(tag_list);
                                let fav_count = r.columns.get(8).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                                let favorited = r.columns.get(9).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);
                                let author_uname = r.columns.get(10).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let author_bio = r.columns.get(11).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let author_img = r.columns.get(12).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let author_following = r.columns.get(13).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                                let resp_body = format_article_json(
                                    slug,
                                    title_str,
                                    desc_str,
                                    Some(body_str),
                                    &tags,
                                    std::str::from_utf8(&created_at).unwrap_or(""),
                                    std::str::from_utf8(&updated_at).unwrap_or(""),
                                    favorited,
                                    fav_count,
                                    author_uname,
                                    author_bio,
                                    author_img,
                                    author_following,
                                );
                                let resp = make_http_response(201, "Created", &resp_body, keep_alive);
                                direct_send(fd, &resp);
                            }
                            _ => {
                                let resp = make_error_response(500, "Internal Server Error", "Database error", keep_alive);
                                direct_send(fd, &resp);
                            }
                        }
                    }
                    _ => {
                        pg.simple_query("ROLLBACK;").ok();
                        let resp = make_error_response(422, "Unprocessable Entity", "Failed to create article", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::UpdateArticle { fd, keep_alive, viewer, slug, title, description, body } => {
                match pg.execute_prepared("stmt_find_author", &[slug.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let art_id = rows[0].columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let author_id = rows[0].columns.get(1).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);

                        if author_id as u64 != viewer {
                            let resp = make_error_response(403, "Forbidden", "Forbidden", keep_alive);
                            direct_send(fd, &resp);
                            continue;
                        }

                        let art_id_bytes = art_id.to_be_bytes();
                        let viewer_bytes = (viewer as i64).to_be_bytes();
                        let title_param = title.as_deref().map(|s| s.as_bytes()).unwrap_or(b"");
                        let desc_param = description.as_deref().map(|s| s.as_bytes()).unwrap_or(b"");
                        let body_param = body.as_deref().map(|s| s.as_bytes()).unwrap_or(b"");

                        pg.execute_prepared("stmt_upd_art", &[&art_id_bytes, title_param, desc_param, body_param]).ok();

                        match pg.execute_prepared("stmt_get_art_id", &[&viewer_bytes, &art_id_bytes]) {
                            Ok(art_rows) if !art_rows.is_empty() => {
                                let r = &art_rows[0];
                                let updated_slug = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&slug);
                                let title_str = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let desc_str = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let body_str = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let created_at = r.columns.get(5).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let updated_at = r.columns.get(6).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let tags = r.columns.get(7).and_then(|c| c.as_deref()).map(decode_text_array).unwrap_or_default();
                                let fav_count = r.columns.get(8).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                                let favorited = r.columns.get(9).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);
                                let author_uname = r.columns.get(10).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let author_bio = r.columns.get(11).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let author_img = r.columns.get(12).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let author_following = r.columns.get(13).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                                let resp_body = format_article_json(
                                    updated_slug,
                                    title_str,
                                    desc_str,
                                    Some(body_str),
                                    &tags,
                                    std::str::from_utf8(&created_at).unwrap_or(""),
                                    std::str::from_utf8(&updated_at).unwrap_or(""),
                                    favorited,
                                    fav_count,
                                    author_uname,
                                    author_bio,
                                    author_img,
                                    author_following,
                                );
                                let resp = make_http_response(200, "OK", &resp_body, keep_alive);
                                direct_send(fd, &resp);
                            }
                            _ => {
                                let resp = make_error_response(500, "Internal Server Error", "Database error", keep_alive);
                                direct_send(fd, &resp);
                            }
                        }
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::DeleteArticle { fd, keep_alive, viewer, slug } => {
                match pg.execute_prepared("stmt_find_author", &[slug.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let art_id = rows[0].columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let author_id = rows[0].columns.get(1).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);

                        if author_id as u64 != viewer {
                            let resp = make_error_response(403, "Forbidden", "Forbidden", keep_alive);
                            direct_send(fd, &resp);
                            continue;
                        }

                        let art_id_bytes = art_id.to_be_bytes();
                        pg.execute_prepared("stmt_del_art", &[&art_id_bytes]).ok();
                        let resp = make_204_response(keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::FavoriteArticle { fd, keep_alive, viewer, slug, favorite } => {
                match pg.execute_prepared("stmt_find_art_id", &[slug.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let art_id = rows[0].columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let art_id_bytes = art_id.to_be_bytes();
                        let viewer_bytes = (viewer as i64).to_be_bytes();

                        if favorite {
                            pg.execute_prepared("stmt_fav", &[&viewer_bytes, &art_id_bytes]).ok();
                        } else {
                            pg.execute_prepared("stmt_unfav", &[&viewer_bytes, &art_id_bytes]).ok();
                        }

                        match pg.execute_prepared("stmt_get_art_id", &[&viewer_bytes, &art_id_bytes]) {
                            Ok(art_rows) if !art_rows.is_empty() => {
                                let r = &art_rows[0];
                                let title = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let desc = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let body = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let created_at = r.columns.get(5).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let updated_at = r.columns.get(6).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let tags = r.columns.get(7).and_then(|c| c.as_deref()).map(decode_text_array).unwrap_or_default();
                                let fav_count = r.columns.get(8).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                                let is_fav = r.columns.get(9).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);
                                let author_uname = r.columns.get(10).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let author_bio = r.columns.get(11).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let author_img = r.columns.get(12).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let author_following = r.columns.get(13).and_then(|c| c.as_deref()).map(|b| b[0] != 0).unwrap_or(false);

                                let resp_body = format_article_json(
                                    &slug,
                                    title,
                                    desc,
                                    Some(body),
                                    &tags,
                                    std::str::from_utf8(&created_at).unwrap_or(""),
                                    std::str::from_utf8(&updated_at).unwrap_or(""),
                                    is_fav,
                                    fav_count,
                                    author_uname,
                                    author_bio,
                                    author_img,
                                    author_following,
                                );
                                let resp = make_http_response(200, "OK", &resp_body, keep_alive);
                                direct_send(fd, &resp);
                            }
                            _ => {
                                let resp = make_error_response(500, "Internal Server Error", "Database error", keep_alive);
                                direct_send(fd, &resp);
                            }
                        }
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::CreateComment { fd, keep_alive, viewer, slug, body } => {
                match pg.execute_prepared("stmt_find_art_id", &[slug.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let art_id = rows[0].columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        let art_id_bytes = art_id.to_be_bytes();
                        let viewer_bytes = (viewer as i64).to_be_bytes();

                        match pg.execute_prepared("stmt_create_comm", &[&art_id_bytes, &viewer_bytes, body.as_bytes()]) {
                            Ok(comm_rows) if !comm_rows.is_empty() => {
                                let r = &comm_rows[0];
                                let cid = r.columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                                let body_str = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&body);
                                let created_at = r.columns.get(2).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let updated_at = r.columns.get(3).and_then(|c| c.as_deref()).map(|b| format_pg_timestamp(i64::from_be_bytes(b[0..8].try_into().unwrap()))).unwrap_or_default();
                                let uname = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                                let ubio = r.columns.get(5).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                                let uimg = r.columns.get(6).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());

                                let resp_body = format_comment_json(
                                    cid,
                                    std::str::from_utf8(&created_at).unwrap_or(""),
                                    std::str::from_utf8(&updated_at).unwrap_or(""),
                                    body_str,
                                    uname,
                                    ubio,
                                    uimg,
                                    false,
                                );
                                let resp = make_http_response(201, "Created", &resp_body, keep_alive);
                                direct_send(fd, &resp);
                            }
                            _ => {
                                let resp = make_error_response(500, "Internal Server Error", "Database error", keep_alive);
                                direct_send(fd, &resp);
                            }
                        }
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
            WriteRequest::DeleteComment { fd, keep_alive, viewer, slug, comment_id } => {
                let cid_bytes = comment_id.to_be_bytes();
                match pg.execute_prepared("stmt_find_comm", &[&cid_bytes, slug.as_bytes()]) {
                    Ok(rows) if !rows.is_empty() => {
                        let author_id = rows[0].columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                        if author_id as u64 != viewer {
                            let resp = make_error_response(403, "Forbidden", "Forbidden", keep_alive);
                            direct_send(fd, &resp);
                            continue;
                        }

                        pg.execute_prepared("stmt_del_comm", &[&cid_bytes]).ok();
                        let resp = make_204_response(keep_alive);
                        direct_send(fd, &resp);
                    }
                    _ => {
                        let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
                        direct_send(fd, &resp);
                    }
                }
            }
        }
    }
}

pub fn run_bcrypt_worker(rx: Receiver<BcryptRequest>, config: ServerConfig) {
    let info = PgConnectionInfo::parse(&config.db_url).expect("Invalid DATABASE_URL");
    let mut pg = PgClient::connect(&info).expect("Bcrypt lane failed to connect to Postgres");

    pg.prepare("stmt_login", SQL_LOGIN_USER, &[TEXT_OID]).ok();

    while let Ok(req) = rx.recv() {
        match pg.execute_prepared("stmt_login", &[req.email.as_bytes()]) {
            Ok(rows) if !rows.is_empty() => {
                let r = &rows[0];
                let id = r.columns.get(0).and_then(|c| c.as_deref()).map(|b| i64::from_be_bytes(b[0..8].try_into().unwrap())).unwrap_or(0);
                let username = r.columns.get(1).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
                let email = r.columns.get(2).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or(&req.email);
                let bio = r.columns.get(3).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                let image = r.columns.get(4).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok());
                let stored_hash = r.columns.get(5).and_then(|c| c.as_deref()).and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");

                if verify_password(&req.password, stored_hash) {
                    let token = generate_token(id as u64, &config.jwt_secret);
                    let body = format_user_json(email, &token, username, bio, image);
                    let resp = make_http_response(200, "OK", &body, req.keep_alive);
                    direct_send(req.fd, &resp);
                } else {
                    let resp = make_error_response(401, "Unauthorized", "Invalid email or password", req.keep_alive);
                    direct_send(req.fd, &resp);
                }
            }
            _ => {
                let resp = make_error_response(401, "Unauthorized", "Invalid email or password", req.keep_alive);
                direct_send(req.fd, &resp);
            }
        }
    }
}
