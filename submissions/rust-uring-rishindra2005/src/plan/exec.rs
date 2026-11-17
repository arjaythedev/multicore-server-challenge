//! Read batch executor for Conduit query families.
//!
//! Executes per-family queries pipelined in a single round trip with ONE Sync.
//! Uses q2env ordinal mapping to guarantee that skipped envelopes never desynchronize
//! query results on the wire.

use crate::api::render::{
    frame_response, render_article, render_article_list, render_comments_list, render_errors,
    render_profile, render_tags, render_user, ArticleRow, CommentRow, ProfileRow, UserRow,
};
use crate::pg::decode::BinaryDecoder;
use crate::pg::wire::{encode_int8_array, encode_text_array, PgError, PgWire};
use crate::types::{Envelope, Job, KdfJob, ListFilter, Reply};

// Map each envelope to its query slot
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PlannedJob<'a> {
    Tags,
    // GET /api/tags that shares the single s_tags execution of an earlier envelope in this batch.
    TagsShared,
    UserGet { uid_bytes: [u8; 8] },
    Profile { viewer_bytes: [u8; 8], username: &'a str },
    ArticleGet { viewer_bytes: [u8; 8], slug: &'a str },
    Comments { viewer_bytes: [u8; 8], slug: &'a str },
    LoginLookup { email: &'a str },
    ListGlobal { limit_bytes: [u8; 8], offset_bytes: [u8; 8], viewer_bytes: [u8; 8] },
    ListTag { tag_name: &'a str, limit_bytes: [u8; 8], offset_bytes: [u8; 8], viewer_bytes: [u8; 8] },
    ListAuthor { author: &'a str, limit_bytes: [u8; 8], offset_bytes: [u8; 8], viewer_bytes: [u8; 8] },
    ListFavorited { favorited: &'a str, limit_bytes: [u8; 8], offset_bytes: [u8; 8], viewer_bytes: [u8; 8] },
    Skip,
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum QueuedStmt {
    Single(usize),
    Packed(Vec<usize>),
}

#[derive(Copy, Clone, PartialEq, Eq, Hash, Debug)]
pub(crate) enum PackKind {
    UserGet,
    LoginLookup,
    Profile,
    ArticleGet,
    Comments,
}

impl<'a> PlannedJob<'a> {
    pub(crate) fn pack_kind(&self) -> Option<PackKind> {
        match self {
            PlannedJob::UserGet { .. } => Some(PackKind::UserGet),
            PlannedJob::LoginLookup { .. } => Some(PackKind::LoginLookup),
            PlannedJob::Profile { .. } => Some(PackKind::Profile),
            PlannedJob::ArticleGet { .. } => Some(PackKind::ArticleGet),
            PlannedJob::Comments { .. } => Some(PackKind::Comments),
            _ => None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PlannedGroup {
    Single(usize),
    Packed {
        kind: PackKind,
        envs: Vec<usize>,
    },
}

pub(crate) fn group_planned_jobs<'a>(planned: &'a [PlannedJob<'a>]) -> Vec<PlannedGroup> {
    let mut groups = Vec::new();
    let mut processed = vec![false; planned.len()];

    for i in 0..planned.len() {
        if processed[i] {
            continue;
        }
        match &planned[i] {
            PlannedJob::Skip | PlannedJob::TagsShared => {
                processed[i] = true;
            }
            job => {
                if let Some(kind) = job.pack_kind() {
                    let mut envs = Vec::new();
                    for j in i..planned.len() {
                        if !processed[j] && planned[j].pack_kind() == Some(kind) {
                            envs.push(j);
                        }
                    }
                    if envs.len() >= 2 {
                        for &idx in &envs {
                            processed[idx] = true;
                        }
                        groups.push(PlannedGroup::Packed { kind, envs });
                    } else {
                        processed[i] = true;
                        groups.push(PlannedGroup::Single(i));
                    }
                } else {
                    processed[i] = true;
                    groups.push(PlannedGroup::Single(i));
                }
            }
        }
    }

    groups
}

#[derive(Default)]
pub(crate) struct ArticleItem {
    pub slug: String,
    pub title: String,
    pub description: String,
    pub body: Option<String>,
    pub created_at_us: i64,
    pub updated_at_us: i64,
    pub author_username: String,
    pub author_bio: Option<String>,
    pub author_image: Option<String>,
    pub following: bool,
    pub favorited: bool,
    pub favorites_count: i64,
    pub tags: Vec<String>,
}

pub(crate) enum QueryOutcome {
    Empty,
    Tags(Vec<String>),
    User { _id: i64, username: String, email: String, bio: Option<String>, image: Option<String> },
    LoginUser { id: i64, username: String, email: String, bio: Option<String>, image: Option<String>, password_hash: String },
    Profile { username: String, bio: Option<String>, image: Option<String>, following: bool },
    Article(ArticleItem),
    Comments(Vec<CommentRowData>),
    ArticlesList { count: i64, articles: Vec<ArticleItem> },
}

pub(crate) struct CommentRowData {
    pub id: i64,
    pub body: String,
    pub created_at_us: i64,
    pub updated_at_us: i64,
    pub author_username: String,
    pub author_bio: Option<String>,
    pub author_image: Option<String>,
    pub author_following: bool,
}

fn parse_row_into_outcome(
    job: &PlannedJob,
    row: &crate::pg::decode::BinaryRow,
    base: usize,
    outcome: &mut QueryOutcome,
) {
    match job {
        PlannedJob::Tags => {
            if let Some(tname) = row.get_str(base) {
                match outcome {
                    QueryOutcome::Tags(list) => list.push(tname.to_string()),
                    _ => *outcome = QueryOutcome::Tags(vec![tname.to_string()]),
                }
            }
        }

        PlannedJob::UserGet { .. } => {
            let _id = row.get_i64(base).unwrap_or(0);
            let username = row.get_str(1 + base).unwrap_or("").to_string();
            let email = row.get_str(2 + base).unwrap_or("").to_string();
            let bio = row.get_str(3 + base).map(|s| s.to_string());
            let image = row.get_str(4 + base).map(|s| s.to_string());
            *outcome = QueryOutcome::User { _id, username, email, bio, image };
        }

        PlannedJob::LoginLookup { .. } => {
            let id = row.get_i64(base).unwrap_or(0);
            let username = row.get_str(1 + base).unwrap_or("").to_string();
            let email = row.get_str(2 + base).unwrap_or("").to_string();
            let bio = row.get_str(3 + base).map(|s| s.to_string());
            let image = row.get_str(4 + base).map(|s| s.to_string());
            let password_hash = row.get_str(5 + base).unwrap_or("").to_string();
            *outcome = QueryOutcome::LoginUser { id, username, email, bio, image, password_hash };
        }

        PlannedJob::Profile { .. } => {
            let username = row.get_str(1 + base).unwrap_or("").to_string();
            let bio = row.get_str(2 + base).map(|s| s.to_string());
            let image = row.get_str(3 + base).map(|s| s.to_string());
            let following = row.get_bool(4 + base).unwrap_or(false);
            *outcome = QueryOutcome::Profile { username, bio, image, following };
        }

        PlannedJob::ArticleGet { .. } => {
            let slug = row.get_str(1 + base).unwrap_or("").to_string();
            let title = row.get_str(2 + base).unwrap_or("").to_string();
            let description = row.get_str(3 + base).unwrap_or("").to_string();
            let body = row.get_str(4 + base).map(|s| s.to_string());
            let created_at_us = row.get_i64(5 + base).unwrap_or(0);
            let updated_at_us = row.get_i64(6 + base).unwrap_or(0);
            let author_username = row.get_str(8 + base).unwrap_or("").to_string();
            let author_bio = row.get_str(9 + base).map(|s| s.to_string());
            let author_image = row.get_str(10 + base).map(|s| s.to_string());
            let following = row.get_bool(11 + base).unwrap_or(false);
            let favorited = row.get_bool(12 + base).unwrap_or(false);
            let favorites_count = row.get_i64(13 + base).unwrap_or(0);

            let mut tags = Vec::new();
            if let Some(tag_raw) = row.get_raw(14 + base) {
                let mut tag_slices = Vec::new();
                if BinaryDecoder::decode_text_array(tag_raw, &mut tag_slices).is_ok() {
                    tags = tag_slices.into_iter().map(|s| s.to_string()).collect();
                }
            }

            *outcome = QueryOutcome::Article(ArticleItem {
                slug,
                title,
                description,
                body,
                created_at_us,
                updated_at_us,
                author_username,
                author_bio,
                author_image,
                following,
                favorited,
                favorites_count,
                tags,
            });
        }

        PlannedJob::Comments { .. } => {
            match outcome {
                QueryOutcome::Comments(ref mut list) => {
                    if let Some(cid) = row.get_i64(1 + base) {
                        let body = row.get_str(2 + base).unwrap_or("").to_string();
                        let created_at_us = row.get_i64(3 + base).unwrap_or(0);
                        let updated_at_us = row.get_i64(4 + base).unwrap_or(0);
                        let author_username = row.get_str(6 + base).unwrap_or("").to_string();
                        let author_bio = row.get_str(7 + base).map(|s| s.to_string());
                        let author_image = row.get_str(8 + base).map(|s| s.to_string());
                        let author_following = row.get_bool(9 + base).unwrap_or(false);
                        list.push(CommentRowData {
                            id: cid,
                            body,
                            created_at_us,
                            updated_at_us,
                            author_username,
                            author_bio,
                            author_image,
                            author_following,
                        });
                    }
                }
                _ => {
                    let mut list = Vec::new();
                    if let Some(cid) = row.get_i64(1 + base) {
                        let body = row.get_str(2 + base).unwrap_or("").to_string();
                        let created_at_us = row.get_i64(3 + base).unwrap_or(0);
                        let updated_at_us = row.get_i64(4 + base).unwrap_or(0);
                        let author_username = row.get_str(6 + base).unwrap_or("").to_string();
                        let author_bio = row.get_str(7 + base).map(|s| s.to_string());
                        let author_image = row.get_str(8 + base).map(|s| s.to_string());
                        let author_following = row.get_bool(9 + base).unwrap_or(false);
                        list.push(CommentRowData {
                            id: cid,
                            body,
                            created_at_us,
                            updated_at_us,
                            author_username,
                            author_bio,
                            author_image,
                            author_following,
                        });
                    }
                    *outcome = QueryOutcome::Comments(list);
                }
            }
        }

        PlannedJob::ListGlobal { .. }
        | PlannedJob::ListTag { .. }
        | PlannedJob::ListAuthor { .. }
        | PlannedJob::ListFavorited { .. } => {
            let row_kind = row.get_i64(base).unwrap_or(-1);
            if row_kind == 0 {
                let count = row.get_i64(1 + base).unwrap_or(0);
                match outcome {
                    QueryOutcome::ArticlesList { count: ref mut c, .. } => *c = count,
                    _ => *outcome = QueryOutcome::ArticlesList { count, articles: Vec::new() },
                }
            } else if row_kind == 1 {
                let slug = row.get_str(3 + base).unwrap_or("").to_string();
                let title = row.get_str(4 + base).unwrap_or("").to_string();
                let description = row.get_str(5 + base).unwrap_or("").to_string();
                let created_at_us = row.get_i64(6 + base).unwrap_or(0);
                let updated_at_us = row.get_i64(7 + base).unwrap_or(0);
                let author_username = row.get_str(9 + base).unwrap_or("").to_string();
                let author_bio = row.get_str(10 + base).map(|s| s.to_string());
                let author_image = row.get_str(11 + base).map(|s| s.to_string());

                let mut tags = Vec::new();
                if let Some(tag_raw) = row.get_raw(12 + base) {
                    let mut tag_slices = Vec::new();
                    if BinaryDecoder::decode_text_array(tag_raw, &mut tag_slices).is_ok() {
                        tags = tag_slices.into_iter().map(|s| s.to_string()).collect();
                    }
                }

                let favorites_count = row.get_i64(13 + base).unwrap_or(0);
                let favorited = row.get_bool(14 + base).unwrap_or(false);
                let following = row.get_bool(15 + base).unwrap_or(false);

                let item = ArticleItem {
                    slug,
                    title,
                    description,
                    body: None,
                    created_at_us,
                    updated_at_us,
                    author_username,
                    author_bio,
                    author_image,
                    following,
                    favorited,
                    favorites_count,
                    tags,
                };

                match outcome {
                    QueryOutcome::ArticlesList { ref mut articles, .. } => articles.push(item),
                    _ => *outcome = QueryOutcome::ArticlesList { count: 0, articles: vec![item] },
                }
            }
        }

        PlannedJob::TagsShared | PlannedJob::Skip => {}
    }
}

/// Executes a batch of read envelopes using per-family pipelined statements.
pub fn execute_read_batch(
    wire: &mut PgWire,
    envelopes: &[Envelope],
    replies: &mut Vec<Reply>,
    kdf_jobs: &mut Vec<KdfJob>,
) -> Result<(), PgError> {
    if envelopes.is_empty() {
        return Ok(());
    }

    let mut pipeline = wire.pipeline();

    let mut planned: Vec<PlannedJob> = Vec::with_capacity(envelopes.len());
    // All GET /api/tags requests of this batch are answered from one s_tags execution that runs
    // while they are being served (the same query and the same result for every one of them).
    let mut tags_planned = false;

    for env in envelopes {
        match &env.job {
            Job::Tags => {
                if tags_planned {
                    planned.push(PlannedJob::TagsShared);
                } else {
                    tags_planned = true;
                    planned.push(PlannedJob::Tags);
                }
            }
            Job::UserGet => {
                let uid_bytes = env.viewer.to_be_bytes();
                planned.push(PlannedJob::UserGet { uid_bytes });
            }
            Job::Profile { username } => {
                let viewer_bytes = env.viewer.to_be_bytes();
                planned.push(PlannedJob::Profile {
                    viewer_bytes,
                    username,
                });
            }
            Job::ArticleGet { slug } => {
                let viewer_bytes = env.viewer.to_be_bytes();
                planned.push(PlannedJob::ArticleGet {
                    viewer_bytes,
                    slug,
                });
            }
            Job::Comments { slug } => {
                let viewer_bytes = env.viewer.to_be_bytes();
                planned.push(PlannedJob::Comments {
                    viewer_bytes,
                    slug,
                });
            }
            Job::LoginLookup { email, .. } => {
                planned.push(PlannedJob::LoginLookup { email });
            }
            Job::List { filter, limit, offset } => {
                let lim = *limit as i64;
                let off = *offset as i64;
                match filter {
                    ListFilter::Global => {
                        planned.push(PlannedJob::ListGlobal {
                            limit_bytes: lim.to_be_bytes(),
                            offset_bytes: off.to_be_bytes(),
                            viewer_bytes: env.viewer.to_be_bytes(),
                        });
                    }
                    ListFilter::Tag(tag_name) => {
                        planned.push(PlannedJob::ListTag {
                            tag_name: tag_name.as_ref(),
                            limit_bytes: lim.to_be_bytes(),
                            offset_bytes: off.to_be_bytes(),
                            viewer_bytes: env.viewer.to_be_bytes(),
                        });
                    }
                    ListFilter::Author(author_name) => {
                        planned.push(PlannedJob::ListAuthor {
                            author: author_name,
                            limit_bytes: lim.to_be_bytes(),
                            offset_bytes: off.to_be_bytes(),
                            viewer_bytes: env.viewer.to_be_bytes(),
                        });
                    }
                    ListFilter::Favorited(fav_user) => {
                        planned.push(PlannedJob::ListFavorited {
                            favorited: fav_user,
                            limit_bytes: lim.to_be_bytes(),
                            offset_bytes: off.to_be_bytes(),
                            viewer_bytes: env.viewer.to_be_bytes(),
                        });
                    }
                }
            }
            _ => {
                planned.push(PlannedJob::Skip);
            }
        }
    }

    let groups = group_planned_jobs(&planned);
    let mut q2env: Vec<QueuedStmt> = Vec::with_capacity(groups.len());

    for group in groups {
        match group {
            PlannedGroup::Single(env_idx) => {
                match &planned[env_idx] {
                    PlannedJob::Tags => {
                        pipeline.bind_exec_binary("s_tags", &[]);
                    }
                    PlannedJob::UserGet { uid_bytes } => {
                        pipeline.bind_exec_binary("s_uid", &[uid_bytes.as_slice()]);
                    }
                    PlannedJob::Profile { viewer_bytes, username } => {
                        pipeline.bind_exec_binary("s_prof", &[viewer_bytes.as_slice(), username.as_bytes()]);
                    }
                    PlannedJob::ArticleGet { viewer_bytes, slug } => {
                        pipeline.bind_exec_binary("s_aslug", &[viewer_bytes.as_slice(), slug.as_bytes()]);
                    }
                    PlannedJob::Comments { viewer_bytes, slug } => {
                        pipeline.bind_exec_binary("s_cmts", &[viewer_bytes.as_slice(), slug.as_bytes()]);
                    }
                    PlannedJob::LoginLookup { email, .. } => {
                        pipeline.bind_exec_binary("s_uemail", &[email.as_bytes()]);
                    }
                    PlannedJob::ListGlobal { limit_bytes, offset_bytes, viewer_bytes } => {
                        pipeline.bind_exec_binary(
                            "s_global",
                            &[limit_bytes.as_slice(), offset_bytes.as_slice(), viewer_bytes.as_slice()],
                        );
                    }
                    PlannedJob::ListTag { tag_name, limit_bytes, offset_bytes, viewer_bytes } => {
                        pipeline.bind_exec_binary(
                            "s_tag_list",
                            &[tag_name.as_bytes(), limit_bytes.as_slice(), offset_bytes.as_slice(), viewer_bytes.as_slice()],
                        );
                    }
                    PlannedJob::ListAuthor { author, limit_bytes, offset_bytes, viewer_bytes } => {
                        pipeline.bind_exec_binary(
                            "s_author_list",
                            &[author.as_bytes(), limit_bytes.as_slice(), offset_bytes.as_slice(), viewer_bytes.as_slice()],
                        );
                    }
                    PlannedJob::ListFavorited { favorited, limit_bytes, offset_bytes, viewer_bytes } => {
                        pipeline.bind_exec_binary(
                            "s_fav_list",
                            &[favorited.as_bytes(), limit_bytes.as_slice(), offset_bytes.as_slice(), viewer_bytes.as_slice()],
                        );
                    }
                    PlannedJob::Skip | PlannedJob::TagsShared => unreachable!(),
                }
                q2env.push(QueuedStmt::Single(env_idx));
            }
            PlannedGroup::Packed { kind, envs } => {
                match kind {
                    PackKind::UserGet => {
                        let mut uids = Vec::with_capacity(envs.len());
                        for &idx in &envs {
                            uids.push(envelopes[idx].viewer);
                        }
                        let mut buf0 = Vec::new();
                        encode_int8_array(&uids, &mut buf0);
                        pipeline.bind_exec_binary("s_uid_p", &[&buf0]);
                    }
                    PackKind::LoginLookup => {
                        let mut emails = Vec::with_capacity(envs.len());
                        for &idx in &envs {
                            if let PlannedJob::LoginLookup { email } = &planned[idx] {
                                emails.push(*email);
                            }
                        }
                        let mut buf0 = Vec::new();
                        encode_text_array(&emails, &mut buf0);
                        pipeline.bind_exec_binary("s_uemail_p", &[&buf0]);
                    }
                    PackKind::Profile => {
                        let mut viewers = Vec::with_capacity(envs.len());
                        let mut usernames = Vec::with_capacity(envs.len());
                        for &idx in &envs {
                            if let PlannedJob::Profile { username, .. } = &planned[idx] {
                                viewers.push(envelopes[idx].viewer);
                                usernames.push(*username);
                            }
                        }
                        let mut buf0 = Vec::new();
                        let mut buf1 = Vec::new();
                        encode_int8_array(&viewers, &mut buf0);
                        encode_text_array(&usernames, &mut buf1);
                        pipeline.bind_exec_binary("s_prof_p", &[&buf0, &buf1]);
                    }
                    PackKind::ArticleGet => {
                        let mut viewers = Vec::with_capacity(envs.len());
                        let mut slugs = Vec::with_capacity(envs.len());
                        for &idx in &envs {
                            if let PlannedJob::ArticleGet { slug, .. } = &planned[idx] {
                                viewers.push(envelopes[idx].viewer);
                                slugs.push(*slug);
                            }
                        }
                        let mut buf0 = Vec::new();
                        let mut buf1 = Vec::new();
                        encode_int8_array(&viewers, &mut buf0);
                        encode_text_array(&slugs, &mut buf1);
                        pipeline.bind_exec_binary("s_aslug_p", &[&buf0, &buf1]);
                    }
                    PackKind::Comments => {
                        let mut viewers = Vec::with_capacity(envs.len());
                        let mut slugs = Vec::with_capacity(envs.len());
                        for &idx in &envs {
                            if let PlannedJob::Comments { slug, .. } = &planned[idx] {
                                viewers.push(envelopes[idx].viewer);
                                slugs.push(*slug);
                            }
                        }
                        let mut buf0 = Vec::new();
                        let mut buf1 = Vec::new();
                        encode_int8_array(&viewers, &mut buf0);
                        encode_text_array(&slugs, &mut buf1);
                        pipeline.bind_exec_binary("s_cmts_p", &[&buf0, &buf1]);
                    }
                }
                q2env.push(QueuedStmt::Packed(envs));
            }
        }
    }

    let mut outcomes: Vec<QueryOutcome> = Vec::with_capacity(envelopes.len());
    for _ in 0..envelopes.len() {
        outcomes.push(QueryOutcome::Empty);
    }

    let exec_res = pipeline.execute(|q_idx, row| {
        if q_idx >= q2env.len() {
            return;
        }
        let (env_idx, base) = match &q2env[q_idx] {
            QueuedStmt::Single(idx) => (*idx, 0),
            QueuedStmt::Packed(envs) => {
                let ord = row.get_i64(0).unwrap_or(0);
                if ord < 1 || (ord as usize) > envs.len() {
                    return;
                }
                (envs[(ord - 1) as usize], 1)
            }
        };

        parse_row_into_outcome(&planned[env_idx], &row, base, &mut outcomes[env_idx]);
    });

    // In case of database error, reply 500 to every envelope so no connection hangs
    if let Err(e) = exec_res {
        for env in envelopes {
            let resp = crate::api::errors::reply_500(env.keepalive);
            replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
        }
        return Err(e);
    }

    // Render responses for envelopes
    let mut body_buf = Vec::with_capacity(16384);
    let mut batch_tags_body: Option<Vec<u8>> = None;

    for (idx, env) in envelopes.iter().enumerate() {
        body_buf.clear();

        if planned[idx] == PlannedJob::TagsShared {
            // The owning Tags envelope has a lower index, so its body is already rendered (or the
            // query returned no tags, which renders as an empty list).
            let resp = match &batch_tags_body {
                Some(body) => frame_response(200, "OK", body, env.keepalive),
                None => {
                    render_tags(&mut body_buf, &[]);
                    frame_response(200, "OK", &body_buf, env.keepalive)
                }
            };
            replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            continue;
        }

        match &mut outcomes[idx] {
            QueryOutcome::Tags(tags) => {
                let refs: Vec<&str> = tags.iter().map(|s| s.as_str()).collect();
                render_tags(&mut body_buf, &refs);
                batch_tags_body = Some(body_buf.clone());
                let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            QueryOutcome::User { username, email, bio, image, .. } => {
                let user_row = UserRow {
                    email,
                    token: env.token.as_deref().unwrap_or(""),
                    username,
                    bio: bio.as_deref(),
                    image: image.as_deref(),
                };
                render_user(&mut body_buf, &user_row);
                let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            QueryOutcome::Profile { username, bio, image, following } => {
                let prof = ProfileRow {
                    username,
                    bio: bio.as_deref(),
                    image: image.as_deref(),
                    following: *following,
                };
                render_profile(&mut body_buf, &prof);
                let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            QueryOutcome::Article(art) => {
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
            }

            QueryOutcome::Comments(cmts) => {
                let mut cmt_rows = Vec::with_capacity(cmts.len());
                for c in cmts.iter() {
                    cmt_rows.push(CommentRow {
                        id: c.id,
                        created_at_us: c.created_at_us,
                        updated_at_us: c.updated_at_us,
                        body: &c.body,
                        author: ProfileRow {
                            username: &c.author_username,
                            bio: c.author_bio.as_deref(),
                            image: c.author_image.as_deref(),
                            following: c.author_following,
                        },
                    });
                }
                render_comments_list(&mut body_buf, &cmt_rows);
                let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            QueryOutcome::ArticlesList { count, articles } => {
                let mut article_tags_list: Vec<Vec<&str>> = Vec::with_capacity(articles.len());
                for art in articles.iter() {
                    let tag_refs: Vec<&str> = art.tags.iter().map(|s| s.as_str()).collect();
                    article_tags_list.push(tag_refs);
                }

                let mut article_rows = Vec::with_capacity(articles.len());
                for (j, art) in articles.iter().enumerate() {
                    article_rows.push(ArticleRow {
                        slug: &art.slug,
                        title: &art.title,
                        description: &art.description,
                        body: None,
                        tags: &article_tags_list[j],
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
                    });
                }

                render_article_list(&mut body_buf, &article_rows, *count);
                let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
            }

            QueryOutcome::LoginUser { id, username, email, bio, image, password_hash } => {
                if let Job::LoginLookup { ref password, .. } = env.job {
                    kdf_jobs.push(KdfJob::Verify {
                        env_conn: env.conn,
                        keepalive: env.keepalive,
                        password: password.clone(),
                        stored_hash: password_hash.clone().into_boxed_str(),
                        user_id: *id,
                        username: username.clone().into_boxed_str(),
                        email: email.clone().into_boxed_str(),
                        bio: bio.clone().map(Into::into),
                        image: image.clone().map(Into::into),
                    });
                }
            }

            QueryOutcome::Empty => {
                match &env.job {
                    Job::Tags => {
                        render_tags(&mut body_buf, &[]);
                        let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    Job::Comments { .. } => {
                        // Article not found: 404 per SPEC line 229 with body key per SPEC 44
                        render_errors(&mut body_buf, &["article not found"]);
                        let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    Job::List { .. } => {
                        render_article_list(&mut body_buf, &[], 0);
                        let resp = frame_response(200, "OK", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    Job::LoginLookup { .. } => {
                        render_errors(&mut body_buf, &["email or password is invalid"]);
                        let resp = frame_response(401, "Unauthorized", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    Job::Profile { .. } => {
                        render_errors(&mut body_buf, &["profile not found"]);
                        let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    Job::ArticleGet { .. } => {
                        render_errors(&mut body_buf, &["article not found"]);
                        let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    Job::UserGet => {
                        render_errors(&mut body_buf, &["user not found"]);
                        let resp = frame_response(401, "Unauthorized", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                    _ => {
                        render_errors(&mut body_buf, &["not found"]);
                        let resp = frame_response(404, "Not Found", &body_buf, env.keepalive);
                        replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
                    }
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ConnRef;

    #[test]
    fn test_q2env_mapping_with_skip() {
        // Test that skips in envelopes correctly map query ordinals to original envelopes
        let envelopes = vec![
            Envelope {
                conn: ConnRef { reactor: 0, slot: 1, gen: 1 },
                viewer: 0,
                token: None,
                keepalive: true,
                job: Job::Tags,
            },
            Envelope {
                conn: ConnRef { reactor: 0, slot: 2, gen: 1 },
                viewer: 0,
                token: None,
                keepalive: true,
                job: Job::ArticleDelete { slug: "skip-me".into() }, // Causes PlannedJob::Skip
            },
            Envelope {
                conn: ConnRef { reactor: 0, slot: 3, gen: 1 },
                viewer: 0,
                token: None,
                keepalive: true,
                job: Job::LoginLookup { email: "test@example.com".into(), password: "pw".into() },
            },
        ];

        // Simulate planning
        let mut planned = Vec::new();
        for env in &envelopes {
            match &env.job {
                Job::Tags => planned.push(PlannedJob::Tags),
                Job::LoginLookup { email, .. } => planned.push(PlannedJob::LoginLookup { email }),
                _ => planned.push(PlannedJob::Skip),
            }
        }
        assert_eq!(planned.len(), 3);
        assert_eq!(planned[0], PlannedJob::Tags);
        assert_eq!(planned[1], PlannedJob::Skip);
        assert_eq!(planned[2], PlannedJob::LoginLookup { email: "test@example.com" });

        // Simulate group_planned_jobs
        let groups = group_planned_jobs(&planned);

        // Issued queries count is 2 (query 0 and query 1)
        assert_eq!(groups.len(), 2);
        // Query 0 maps to envelope 0 (Tags)
        assert_eq!(groups[0], PlannedGroup::Single(0));
        // Query 1 maps to envelope 2 (LoginLookup), NOT envelope 1 (which was Skip)!
        assert_eq!(groups[1], PlannedGroup::Single(2));
    }

    #[test]
    fn test_group_planned_jobs_and_mapping() {
        // A test of the grouping: a batch of planned jobs [Profile a, ArticleGet x, Profile b, Profile a]
        // -> exactly 2 statements queued (packed s_prof_p with 3 elements in order a,b,a and single s_aslug),
        // and an ord->env mapping test.
        let planned = vec![
            PlannedJob::Profile { viewer_bytes: 10i64.to_be_bytes(), username: "a" },
            PlannedJob::ArticleGet { viewer_bytes: 0i64.to_be_bytes(), slug: "x" },
            PlannedJob::Profile { viewer_bytes: 20i64.to_be_bytes(), username: "b" },
            PlannedJob::Profile { viewer_bytes: 30i64.to_be_bytes(), username: "a" },
        ];

        let groups = group_planned_jobs(&planned);
        assert_eq!(groups.len(), 2, "Exactly 2 statements queued");
        assert_eq!(
            groups[0],
            PlannedGroup::Packed {
                kind: PackKind::Profile,
                envs: vec![0, 2, 3],
            },
            "Packed s_prof_p with 3 elements in order a, b, a"
        );
        assert_eq!(
            groups[1],
            PlannedGroup::Single(1),
            "Single s_aslug for envelope 1"
        );

        // Ordinal-to-envelope mapping test
        let q2env = vec![
            QueuedStmt::Packed(vec![0, 2, 3]),
            QueuedStmt::Single(1),
        ];

        let map_ord = |q_idx: usize, ord: i64| -> Option<usize> {
            match &q2env[q_idx] {
                QueuedStmt::Single(idx) => Some(*idx),
                QueuedStmt::Packed(envs) => {
                    if ord < 1 || (ord as usize) > envs.len() {
                        None
                    } else {
                        Some(envs[(ord - 1) as usize])
                    }
                }
            }
        };

        // Statement 0 (Packed s_prof_p with envs [0, 2, 3]):
        // ord 1 (1-based) -> env 0 (Profile "a")
        assert_eq!(map_ord(0, 1), Some(0));
        // ord 2 -> env 2 (Profile "b")
        assert_eq!(map_ord(0, 2), Some(2));
        // ord 3 -> env 3 (Profile "a")
        assert_eq!(map_ord(0, 3), Some(3));
        // ord 0 or out of range -> None
        assert_eq!(map_ord(0, 0), None);
        assert_eq!(map_ord(0, 4), None);

        // Statement 1 (Single s_aslug for env 1):
        assert_eq!(map_ord(1, 0), Some(1));
    }
}
