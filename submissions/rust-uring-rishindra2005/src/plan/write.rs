//! Group-commit write executor.
//!
//! Executes database mutations within a single transaction (`BEGIN` -> pipeline -> `COMMIT`).
//! Strictly enforces challenge Rule 4: all database writes are committed to disk before
//! transmitting the HTTP response to the client.
//!
//! Entire write group executes in a SINGLE round trip with ONE Sync.
//! Conflict-free SQL and savepoint isolation ensure individual errors never abort the group.

use crate::api::render::{
    frame_response, render_article, render_comment, render_errors, render_profile, render_user,
    ArticleRow, CommentRow, ProfileRow, UserRow,
};
use crate::pg::decode::{BinaryDecoder, BinaryEncoder};
use crate::pg::wire::{PgError, PgWire};
use crate::types::{Envelope, Job, Reply};

/// Executes a batch of write operations in a single atomic group transaction.
pub fn execute_write_group(
    wire: &mut PgWire,
    envelopes: &[Envelope],
    replies: &mut Vec<Reply>,
) -> Result<(), PgError> {
    if envelopes.is_empty() {
        return Ok(());
    }

    let mut pipeline = wire.pipeline();

    // 1. Begin group transaction
    pipeline.bind_exec_binary("s_begin", &[]);

    // Enum tracking the kind of query executed for each slot
    #[derive(Clone, Copy, Debug)]
    enum QueryKind {
        Register,
        UserUpdate,
        FollowStep1,
        FollowStep2,
        FavoriteStep1,
        FavoriteStep2,
        CommentCreate,
        CommentDelete,
        ArticleCreate,
        ArticleUpdate,
        ArticleDelete,
    }

    // Maps query ordinal in the pipeline (excluding s_begin) to (env_idx, QueryKind)
    let mut q2env: Vec<(usize, QueryKind)> = Vec::with_capacity(envelopes.len() * 2);

    // Keep parameter byte buffers alive across pipeline binding
    let mut param_buf_i64: Vec<[u8; 8]> = Vec::with_capacity(envelopes.len() * 4);
    let mut param_buf_i64_2: Vec<[u8; 8]> = Vec::with_capacity(envelopes.len() * 4);
    let mut tag_arrays: Vec<Vec<u8>> = Vec::with_capacity(envelopes.len());

    for (env_idx, env) in envelopes.iter().enumerate() {
        match &env.job {
            Job::Register { username, email, password_hash } => {
                pipeline.bind_exec_binary(
                    "s_reg",
                    &[username.as_bytes(), email.as_bytes(), password_hash.as_bytes()],
                );
                q2env.push((env_idx, QueryKind::Register));
            }

            Job::UserUpdate { email, username, password_hash, bio, image } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                let email_param = email.as_deref().map(|s| s.as_bytes());
                let username_param = username.as_deref().map(|s| s.as_bytes());
                let pass_param = password_hash.as_deref().map(|s| s.as_bytes());
                let bio_param = match bio {
                    Some(Some(b)) => Some(b.as_bytes()),
                    _ => None,
                };
                let image_param = match image {
                    Some(Some(img)) => Some(img.as_bytes()),
                    _ => None,
                };

                pipeline.bind_exec_binary_opts(
                    "s_upduser",
                    &[
                        Some(param_buf_i64[uid_idx].as_slice()),
                        email_param,
                        username_param,
                        pass_param,
                        bio_param,
                        image_param,
                    ],
                );
                q2env.push((env_idx, QueryKind::UserUpdate));
            }

            Job::Follow { username, on } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                if *on {
                    pipeline.bind_exec_binary("s_follow_on", &[param_buf_i64[uid_idx].as_slice(), username.as_bytes()]);
                } else {
                    pipeline.bind_exec_binary("s_follow_off", &[param_buf_i64[uid_idx].as_slice(), username.as_bytes()]);
                }
                q2env.push((env_idx, QueryKind::FollowStep1));

                pipeline.bind_exec_binary("s_prof", &[param_buf_i64[uid_idx].as_slice(), username.as_bytes()]);
                q2env.push((env_idx, QueryKind::FollowStep2));
            }

            Job::Favorite { slug, on } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                if *on {
                    pipeline.bind_exec_binary("s_fav_on", &[param_buf_i64[uid_idx].as_slice(), slug.as_bytes()]);
                } else {
                    pipeline.bind_exec_binary("s_fav_off", &[param_buf_i64[uid_idx].as_slice(), slug.as_bytes()]);
                }
                q2env.push((env_idx, QueryKind::FavoriteStep1));

                pipeline.bind_exec_binary("s_aslug", &[param_buf_i64[uid_idx].as_slice(), slug.as_bytes()]);
                q2env.push((env_idx, QueryKind::FavoriteStep2));
            }

            Job::CommentCreate { slug, body } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                pipeline.bind_exec_binary(
                    "s_cmt_create",
                    &[param_buf_i64[uid_idx].as_slice(), slug.as_bytes(), body.as_bytes()],
                );
                q2env.push((env_idx, QueryKind::CommentCreate));
            }

            Job::CommentDelete { slug, id } => {
                let id_idx = param_buf_i64.len();
                param_buf_i64.push(id.to_be_bytes());
                let uid_idx = param_buf_i64_2.len();
                param_buf_i64_2.push(env.viewer.to_be_bytes());

                pipeline.bind_exec_binary(
                    "s_cmt_delete",
                    &[
                        param_buf_i64[id_idx].as_slice(),
                        slug.as_bytes(),
                        param_buf_i64_2[uid_idx].as_slice(),
                    ],
                );
                q2env.push((env_idx, QueryKind::CommentDelete));
            }

            Job::ArticleCreate { title, description, body, tags } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                let mut tag_buf = Vec::new();
                BinaryEncoder::encode_text_array(tags, &mut tag_buf);
                let tag_idx = tag_arrays.len();
                tag_arrays.push(tag_buf);

                pipeline.bind_exec_binary_opts(
                    "s_art_create",
                    &[
                        Some(param_buf_i64[uid_idx].as_slice()),
                        Some(title.as_bytes()),
                        Some(description.as_bytes()),
                        Some(body.as_bytes()),
                        Some(&tag_arrays[tag_idx]),
                    ],
                );
                q2env.push((env_idx, QueryKind::ArticleCreate));
            }

            Job::ArticleUpdate { slug, title, description, body } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                let title_param = title.as_deref().map(|s| s.as_bytes());
                let desc_param = description.as_deref().map(|s| s.as_bytes());
                let body_param = body.as_deref().map(|s| s.as_bytes());

                pipeline.bind_exec_binary_opts(
                    "s_art_update",
                    &[
                        Some(slug.as_bytes()),
                        Some(param_buf_i64[uid_idx].as_slice()),
                        title_param,
                        desc_param,
                        body_param,
                    ],
                );
                q2env.push((env_idx, QueryKind::ArticleUpdate));
            }

            Job::ArticleDelete { slug } => {
                let uid_idx = param_buf_i64.len();
                param_buf_i64.push(env.viewer.to_be_bytes());

                pipeline.bind_exec_binary(
                    "s_art_delete",
                    &[slug.as_bytes(), param_buf_i64[uid_idx].as_slice()],
                );
                q2env.push((env_idx, QueryKind::ArticleDelete));
            }

            _ => {}
        }
    }

    // 2. Commit group transaction
    pipeline.bind_exec_binary("s_commit", &[]);

    // Storage for parsed outcomes
    #[derive(Default)]
    struct ArticleRowData {
        slug: String,
        title: String,
        description: String,
        body: Option<String>,
        created_at_us: i64,
        updated_at_us: i64,
        author_username: String,
        author_bio: Option<String>,
        author_image: Option<String>,
        following: bool,
        favorited: bool,
        favorites_count: i64,
        tags: Vec<String>,
    }

    enum WriteOutcome {
        Empty,
        Register(Option<(i64, String, String, Option<String>, Option<String>)>),
        UserUpdateOutcome { uid: Option<i64>, username: Option<String>, email: String, bio: Option<String>, image: Option<String> },
        Profile(Option<(String, Option<String>, Option<String>, bool)>),
        Article(Option<ArticleRowData>),
        Comment(Option<(i64, String, i64, i64, String, Option<String>, Option<String>)>),
        DeleteOutcome { author_id: Option<i64>, deleted_id: Option<i64> },
        ArticleUpdateOutcome { author_id: Option<i64>, article: Option<ArticleRowData> },
    }

    let mut outcomes: Vec<WriteOutcome> = Vec::with_capacity(envelopes.len());
    for _ in 0..envelopes.len() {
        outcomes.push(WriteOutcome::Empty);
    }

    let exec_res = pipeline.execute(|q_idx, row| {
        // Query 0 is s_begin, so actual queries start at q_idx = 1
        if q_idx == 0 || q_idx > q2env.len() {
            return;
        }
        let (env_idx, kind) = q2env[q_idx - 1];

        match kind {
            QueryKind::Register => {
                let id = row.get_i64(0).unwrap_or(0);
                let uname = row.get_str(1).unwrap_or("").to_string();
                let uemail = row.get_str(2).unwrap_or("").to_string();
                let ubio = row.get_str(3).map(|s| s.to_string());
                let uimage = row.get_str(4).map(|s| s.to_string());
                outcomes[env_idx] = WriteOutcome::Register(Some((id, uname, uemail, ubio, uimage)));
            }

            QueryKind::UserUpdate => {
                let uid = row.get_i64(0);
                let uname = row.get_str(1).map(|s| s.to_string());
                let uemail = row.get_str(2).unwrap_or("").to_string();
                let ubio = row.get_str(3).map(|s| s.to_string());
                let uimage = row.get_str(4).map(|s| s.to_string());
                outcomes[env_idx] = WriteOutcome::UserUpdateOutcome {
                    uid,
                    username: uname,
                    email: uemail,
                    bio: ubio,
                    image: uimage,
                };
            }

            QueryKind::FollowStep1 | QueryKind::FavoriteStep1 => {}

            QueryKind::FollowStep2 => {
                let uname = row.get_str(1).unwrap_or("").to_string();
                let ubio = row.get_str(2).map(|s| s.to_string());
                let uimage = row.get_str(3).map(|s| s.to_string());
                let following = row.get_bool(4).unwrap_or(false);
                outcomes[env_idx] = WriteOutcome::Profile(Some((uname, ubio, uimage, following)));
            }

            QueryKind::FavoriteStep2 => {
                let aslug = row.get_str(1).unwrap_or("").to_string();
                let title = row.get_str(2).unwrap_or("").to_string();
                let description = row.get_str(3).unwrap_or("").to_string();
                let body = row.get_str(4).map(|s| s.to_string());
                let created_at_us = row.get_i64(5).unwrap_or(0);
                let updated_at_us = row.get_i64(6).unwrap_or(0);
                let uname = row.get_str(8).unwrap_or("").to_string();
                let ubio = row.get_str(9).map(|s| s.to_string());
                let uimage = row.get_str(10).map(|s| s.to_string());
                let following = row.get_bool(11).unwrap_or(false);
                let favorited = row.get_bool(12).unwrap_or(false);
                let fc = row.get_i64(13).unwrap_or(0);

                let mut tags = Vec::new();
                if let Some(tag_raw) = row.get_raw(14) {
                    let mut tag_slices = Vec::new();
                    if BinaryDecoder::decode_text_array(tag_raw, &mut tag_slices).is_ok() {
                        tags = tag_slices.into_iter().map(|s| s.to_string()).collect();
                    }
                }

                outcomes[env_idx] = WriteOutcome::Article(Some(ArticleRowData {
                    slug: aslug,
                    title,
                    description,
                    body,
                    created_at_us,
                    updated_at_us,
                    author_username: uname,
                    author_bio: ubio,
                    author_image: uimage,
                    following,
                    favorited,
                    favorites_count: fc,
                    tags,
                }));
            }

            QueryKind::CommentCreate => {
                let id = row.get_i64(0).unwrap_or(0);
                let cbody = row.get_str(1).unwrap_or("").to_string();
                let created_at_us = row.get_i64(2).unwrap_or(0);
                let updated_at_us = row.get_i64(3).unwrap_or(0);
                let uname = row.get_str(5).unwrap_or("").to_string();
                let ubio = row.get_str(6).map(|s| s.to_string());
                let uimage = row.get_str(7).map(|s| s.to_string());
                outcomes[env_idx] = WriteOutcome::Comment(Some((id, cbody, created_at_us, updated_at_us, uname, ubio, uimage)));
            }

            QueryKind::CommentDelete | QueryKind::ArticleDelete => {
                let author_id = row.get_i64(0);
                let deleted_id = row.get_i64(1);
                outcomes[env_idx] = WriteOutcome::DeleteOutcome { author_id, deleted_id };
            }

            QueryKind::ArticleCreate => {
                let aslug = row.get_str(1).unwrap_or("").to_string();
                let atitle = row.get_str(2).unwrap_or("").to_string();
                let adesc = row.get_str(3).unwrap_or("").to_string();
                let abody = row.get_str(4).map(|s| s.to_string());
                let created_at_us = row.get_i64(5).unwrap_or(0);
                let updated_at_us = row.get_i64(6).unwrap_or(0);
                let uname = row.get_str(8).unwrap_or("").to_string();
                let ubio = row.get_str(9).map(|s| s.to_string());
                let uimage = row.get_str(10).map(|s| s.to_string());

                let mut tags = Vec::new();
                if let Some(tag_raw) = row.get_raw(11) {
                    let mut tag_slices = Vec::new();
                    if BinaryDecoder::decode_text_array(tag_raw, &mut tag_slices).is_ok() {
                        tags = tag_slices.into_iter().map(|s| s.to_string()).collect();
                    }
                }

                outcomes[env_idx] = WriteOutcome::Article(Some(ArticleRowData {
                    slug: aslug,
                    title: atitle,
                    description: adesc,
                    body: abody,
                    created_at_us,
                    updated_at_us,
                    author_username: uname,
                    author_bio: ubio,
                    author_image: uimage,
                    following: false,
                    favorited: false,
                    favorites_count: 0,
                    tags,
                }));
            }

            QueryKind::ArticleUpdate => {
                let author_id = row.get_i64(0);
                let aslug = row.get_str(2).unwrap_or("").to_string();
                let atitle = row.get_str(3).unwrap_or("").to_string();
                let adesc = row.get_str(4).unwrap_or("").to_string();
                let abody = row.get_str(5).map(|s| s.to_string());
                let created_at_us = row.get_i64(6).unwrap_or(0);
                let updated_at_us = row.get_i64(7).unwrap_or(0);
                let uname = row.get_str(9).unwrap_or("").to_string();
                let ubio = row.get_str(10).map(|s| s.to_string());
                let uimage = row.get_str(11).map(|s| s.to_string());

                let mut tags = Vec::new();
                if let Some(tag_raw) = row.get_raw(12) {
                    let mut tag_slices = Vec::new();
                    if BinaryDecoder::decode_text_array(tag_raw, &mut tag_slices).is_ok() {
                        tags = tag_slices.into_iter().map(|s| s.to_string()).collect();
                    }
                }
                let fc = row.get_i64(13).unwrap_or(0);
                let favorited = row.get_bool(14).unwrap_or(false);
                let following = row.get_bool(15).unwrap_or(false);

                let mut article = None;
                if !aslug.is_empty() {
                    article = Some(ArticleRowData {
                        slug: aslug,
                        title: atitle,
                        description: adesc,
                        body: abody,
                        created_at_us,
                        updated_at_us,
                        author_username: uname,
                        author_bio: ubio,
                        author_image: uimage,
                        following,
                        favorited,
                        favorites_count: fc,
                        tags,
                    });
                }
                outcomes[env_idx] = WriteOutcome::ArticleUpdateOutcome { author_id, article };
            }
        }
    });

    if envelopes.iter().any(|e| matches!(e.job, Job::ArticleCreate { .. })) {
        crate::plan::count_cache::on_article_create();
    }
    if envelopes.iter().any(|e| matches!(e.job, Job::ArticleDelete { .. })) {
        crate::plan::count_cache::on_article_delete();
    }

    // In case of transaction/database error, reply 500 to every envelope so no client hangs
    if let Err(e) = exec_res {
        for env in envelopes {
            let resp = crate::api::errors::reply_500(env.keepalive);
            replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
        }
        return Err(e);
    }

    // 3. Build HTTP replies only after group transaction commit succeeded
    let mut body_buf = Vec::with_capacity(4096);

    for (env_idx, env) in envelopes.iter().enumerate() {
        body_buf.clear();

        match &outcomes[env_idx] {
            WriteOutcome::Register(Some((id, uname, uemail, ubio, uimage))) => {
                let token = crate::sec::jwt_sign(*id);
                let user_row = UserRow {
                    email: uemail,
                    token: &token,
                    username: uname,
                    bio: ubio.as_deref(),
                    image: uimage.as_deref(),
                };
                render_user(&mut body_buf, &user_row);
                let resp = frame_response(201, "Created", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Register(None) | WriteOutcome::Empty if matches!(env.job, Job::Register { .. }) => {
                render_errors(&mut body_buf, &["has already been taken"]);
                let resp = frame_response(422, "Unprocessable Entity", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::UserUpdateOutcome { uid, username, email, bio, image } => {
                if uid.is_none() {
                    render_errors(&mut body_buf, &["user not found"]);
                    let resp = frame_response(401, "Unauthorized", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else if username.is_none() {
                    render_errors(&mut body_buf, &["email or username is already taken"]);
                    let resp = frame_response(422, "Unprocessable Entity", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else {
                    let uname = username.as_deref().unwrap();
                    let token = env.token.as_deref().unwrap_or("");
                    let user_row = UserRow {
                        email: &email,
                        token,
                        username: uname,
                        bio: bio.as_deref(),
                        image: image.as_deref(),
                    };
                    render_user(&mut body_buf, &user_row);
                    let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                }
            }

            WriteOutcome::Empty if matches!(env.job, Job::UserUpdate { .. }) => {
                render_errors(&mut body_buf, &["user not found"]);
                let resp = frame_response(401, "Unauthorized", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Profile(Some((uname, ubio, uimage, following))) => {
                let profile_row = ProfileRow {
                    username: uname,
                    bio: ubio.as_deref(),
                    image: uimage.as_deref(),
                    following: *following,
                };
                render_profile(&mut body_buf, &profile_row);
                let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Profile(None) | WriteOutcome::Empty if matches!(env.job, Job::Follow { .. }) => {
                render_errors(&mut body_buf, &["profile not found"]);
                let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Article(Some(art)) => {
                let tag_refs: Vec<&str> = art.tags.iter().map(|s| s.as_str()).collect();

                let article_row = ArticleRow {
                    slug: &art.slug,
                    title: &art.title,
                    description: &art.description,
                    body: art.body.as_deref(),
                    tags: &tag_refs,
                    created_at_us: art.created_at_us,
                    updated_at_us: art.updated_at_us,
                    favorited: art.favorited,
                    favorites_count: art.favorites_count,
                    author: ProfileRow {
                        username: &art.author_username,
                        bio: art.author_bio.as_deref(),
                        image: art.author_image.as_deref(),
                        following: art.following,
                    },
                };
                render_article(&mut body_buf, &article_row);
                let status_code = if matches!(env.job, Job::ArticleCreate { .. }) { 201 } else { 200 };
                let status_text = if status_code == 201 { "Created" } else { "OK" };
                let resp = frame_response(status_code, status_text, &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Article(None) | WriteOutcome::Empty if matches!(env.job, Job::Favorite { .. }) => {
                render_errors(&mut body_buf, &["article not found"]);
                let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Comment(Some((id, cbody, created_at_us, updated_at_us, uname, ubio, uimage))) => {
                let comment_row = CommentRow {
                    id: *id,
                    created_at_us: *created_at_us,
                    updated_at_us: *updated_at_us,
                    body: cbody,
                    author: ProfileRow {
                        username: uname,
                        bio: ubio.as_deref(),
                        image: uimage.as_deref(),
                        following: false,
                    },
                };
                render_comment(&mut body_buf, &comment_row);
                let resp = frame_response(201, "Created", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::Comment(None) | WriteOutcome::Empty if matches!(env.job, Job::CommentCreate { .. }) => {
                render_errors(&mut body_buf, &["article not found"]);
                let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            WriteOutcome::DeleteOutcome { author_id, deleted_id } => {
                if author_id.is_none() {
                    render_errors(&mut body_buf, &["not found"]);
                    let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else if *author_id != Some(env.viewer) {
                    render_errors(&mut body_buf, &["forbidden"]);
                    let resp = frame_response(403, "Forbidden", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else if deleted_id.is_some() {
                    let resp = frame_response(204, "No Content", &[], env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else {
                    render_errors(&mut body_buf, &["forbidden"]);
                    let resp = frame_response(403, "Forbidden", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                }
            }

            WriteOutcome::ArticleUpdateOutcome { author_id, article } => {
                if author_id.is_none() {
                    render_errors(&mut body_buf, &["article not found"]);
                    let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else if *author_id != Some(env.viewer) {
                    render_errors(&mut body_buf, &["forbidden"]);
                    let resp = frame_response(403, "Forbidden", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else if let Some(art) = article {
                    let tag_refs: Vec<&str> = art.tags.iter().map(|s| s.as_str()).collect();
                    let article_row = ArticleRow {
                        slug: &art.slug,
                        title: &art.title,
                        description: &art.description,
                        body: art.body.as_deref(),
                        tags: &tag_refs,
                        created_at_us: art.created_at_us,
                        updated_at_us: art.updated_at_us,
                        favorited: art.favorited,
                        favorites_count: art.favorites_count,
                        author: ProfileRow {
                            username: &art.author_username,
                            bio: art.author_bio.as_deref(),
                            image: art.author_image.as_deref(),
                            following: art.following,
                        },
                    };
                    render_article(&mut body_buf, &article_row);
                    let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                } else {
                    render_errors(&mut body_buf, &["article not found"]);
                    let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                    replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                }
            }

            _ => {
                render_errors(&mut body_buf, &["not found"]);
                let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_user_update_param_resolution() {
        // Case 1: All absent -> all SQL NULL
        let job_absent = Job::UserUpdate {
            email: None,
            username: None,
            password_hash: None,
            bio: None,
            image: None,
        };
        if let Job::UserUpdate { ref email, ref username, ref password_hash, ref bio, ref image } = job_absent {
            let email_p = email.as_deref().map(|s| s.as_bytes());
            let username_p = username.as_deref().map(|s| s.as_bytes());
            let pass_p = password_hash.as_deref().map(|s| s.as_bytes());
            let bio_p = match bio {
                Some(Some(b)) => Some(b.as_bytes()),
                _ => None,
            };
            let image_p = match image {
                Some(Some(img)) => Some(img.as_bytes()),
                _ => None,
            };
            assert_eq!(email_p, None);
            assert_eq!(username_p, None);
            assert_eq!(pass_p, None);
            assert_eq!(bio_p, None);
            assert_eq!(image_p, None);
        }

        // Case 2: Explicit nulls (e.g. nulls-unchanged) -> SQL NULL
        let job_nulls = Job::UserUpdate {
            email: None,
            username: None,
            password_hash: None,
            bio: Some(None),
            image: Some(None),
        };
        if let Job::UserUpdate { ref bio, ref image, .. } = job_nulls {
            let bio_p = match bio {
                Some(Some(b)) => Some(b.as_bytes()),
                _ => None,
            };
            let image_p = match image {
                Some(Some(img)) => Some(img.as_bytes()),
                _ => None,
            };
            assert_eq!(bio_p, None);
            assert_eq!(image_p, None);
        }

        // Case 3: Explicit empty string (e.g. empty-bio) -> Some(b"")
        let job_empty_bio = Job::UserUpdate {
            email: None,
            username: None,
            password_hash: None,
            bio: Some(Some("".into())),
            image: None,
        };
        if let Job::UserUpdate { ref bio, .. } = job_empty_bio {
            let bio_p = match bio {
                Some(Some(b)) => Some(b.as_bytes()),
                _ => None,
            };
            assert_eq!(bio_p, Some(b"".as_slice()));
        }

        // Case 4: Values provided -> Some(bytes)
        let job_values = Job::UserUpdate {
            email: Some("new@example.com".into()),
            username: Some("newname".into()),
            password_hash: None,
            bio: Some(Some("my bio".into())),
            image: Some(Some("https://example.com/img.png".into())),
        };
        if let Job::UserUpdate { ref email, ref username, ref password_hash, ref bio, ref image } = job_values {
            let email_p = email.as_deref().map(|s| s.as_bytes());
            let username_p = username.as_deref().map(|s| s.as_bytes());
            let pass_p = password_hash.as_deref().map(|s| s.as_bytes());
            let bio_p = match bio {
                Some(Some(b)) => Some(b.as_bytes()),
                _ => None,
            };
            let image_p = match image {
                Some(Some(img)) => Some(img.as_bytes()),
                _ => None,
            };
            assert_eq!(email_p, Some(b"new@example.com".as_slice()));
            assert_eq!(username_p, Some(b"newname".as_slice()));
            assert_eq!(pass_p, None);
            assert_eq!(bio_p, Some(b"my bio".as_slice()));
            assert_eq!(image_p, Some(b"https://example.com/img.png".as_slice()));
        }
    }

    #[test]
    fn test_article_update_param_resolution() {
        // Updating only body: title and description are None -> SQL NULL
        let job = Job::ArticleUpdate {
            slug: "hello-world-500001".into(),
            title: None,
            description: None,
            body: Some("Updated body".into()),
        };
        if let Job::ArticleUpdate { title, description, body, .. } = job {
            let title_p = title.as_deref().map(|s| s.as_bytes());
            let desc_p = description.as_deref().map(|s| s.as_bytes());
            let body_p = body.as_deref().map(|s| s.as_bytes());

            assert_eq!(title_p, None); // NULL title ensures slug is NOT modified!
            assert_eq!(desc_p, None);
            assert_eq!(body_p, Some(b"Updated body".as_slice()));
        }
    }
}
