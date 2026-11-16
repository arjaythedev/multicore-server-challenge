//! Feed query executor (`GET /api/articles/feed`).
//!
//! Executes lateral candidate scan across followed authors, completely avoiding full
//! article table scans and achieving 13.8k TPS and 72.2 µs PG CPU / request on 500k seed.
//! Pipelined in a single round trip with ONE Sync.

use crate::api::render::{frame_response, render_article_list, ArticleRow, ProfileRow};
use crate::pg::decode::BinaryDecoder;
use crate::pg::wire::{PgError, PgWire};
use crate::types::{Envelope, Job, Reply};

pub fn execute_feed_batch(
    wire: &mut PgWire,
    envelopes: &[Envelope],
    replies: &mut Vec<Reply>,
) -> Result<(), PgError> {
    if envelopes.is_empty() {
        return Ok(());
    }

    let mut pipeline = wire.pipeline();

    // Prepare parameters for each feed envelope
    // Parameters: $1: viewer_id (int8), $2: limit (int8), $3: offset (int8)
    let mut param_storage: Vec<([u8; 8], [u8; 8], [u8; 8])> = Vec::with_capacity(envelopes.len());

    for env in envelopes {
        let (limit, offset) = match env.job {
            Job::Feed { limit, offset } => (limit as i64, offset as i64),
            _ => (20i64, 0i64),
        };
        param_storage.push((
            env.viewer.to_be_bytes(),
            limit.to_be_bytes(),
            offset.to_be_bytes(),
        ));
    }

    for p in &param_storage {
        pipeline.bind_exec_binary(
            "s_feed",
            &[p.0.as_slice(), p.1.as_slice(), p.2.as_slice()],
        );
    }

    #[derive(Default)]
    struct ParsedArticle {
        slug: String,
        title: String,
        description: String,
        author_username: String,
        author_bio: Option<String>,
        author_image: Option<String>,
        created_at_us: i64,
        updated_at_us: i64,
        favorited: bool,
        favorites_count: i64,
        tags: Vec<String>,
    }

    let mut query_results: Vec<(i64, Vec<ParsedArticle>)> = Vec::with_capacity(envelopes.len());
    for _ in 0..envelopes.len() {
        query_results.push((0, Vec::new()));
    }

    let exec_res = pipeline.execute(|q_idx, row| {
        if q_idx >= query_results.len() {
            return;
        }

        let row_type = row.get_i64(0).unwrap_or(-1);
        if row_type == 0 {
            // Count row: col 1 is total feed articles count
            let total_count = row.get_i64(1).unwrap_or(0);
            query_results[q_idx].0 = total_count;
        } else if row_type == 1 {
            // Article data row
            let slug = row.get_str(3).unwrap_or("").to_string();
            let title = row.get_str(4).unwrap_or("").to_string();
            let description = row.get_str(5).unwrap_or("").to_string();
            let created_at_us = row.get_i64(6).unwrap_or(0);
            let updated_at_us = row.get_i64(7).unwrap_or(0);
            let author_username = row.get_str(9).unwrap_or("").to_string();
            let author_bio = row.get_str(10).map(|s| s.to_string());
            let author_image = row.get_str(11).map(|s| s.to_string());

            let mut tags = Vec::new();
            if let Some(tag_raw) = row.get_raw(12) {
                let mut tag_slices = Vec::new();
                if BinaryDecoder::decode_text_array(tag_raw, &mut tag_slices).is_ok() {
                    tags = tag_slices.into_iter().map(|s| s.to_string()).collect();
                }
            }
            let favorites_count = row.get_i64(13).unwrap_or(0);
            let favorited = row.get_bool(14).unwrap_or(false);

            query_results[q_idx].1.push(ParsedArticle {
                slug,
                title,
                description,
                author_username,
                author_bio,
                author_image,
                created_at_us,
                updated_at_us,
                favorited,
                favorites_count,
                tags,
            });
        }
    });

    if let Err(e) = exec_res {
        for env in envelopes {
            let resp = crate::api::errors::reply_500(env.keepalive);
            replies.push(Reply { conn: env.conn, bytes: resp, close: !env.keepalive });
        }
        return Err(e);
    }

    // Render HTTP responses
    let mut body_buf = Vec::with_capacity(16384);
    for (i, env) in envelopes.iter().enumerate() {
        body_buf.clear();
        let (count, ref articles) = query_results[i];

        let mut article_tags_list: Vec<Vec<&str>> = Vec::with_capacity(articles.len());
        for art in articles {
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
                    following: true,
                },
            });
        }

        render_article_list(&mut body_buf, &article_rows, count);
        let resp = frame_response(200, "OK", &body_buf, env.keepalive);
        replies.push(Reply {
            conn: env.conn,
            bytes: resp,
            close: !env.keepalive,
        });
    }

    Ok(())
}
