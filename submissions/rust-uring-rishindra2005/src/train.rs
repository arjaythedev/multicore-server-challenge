//! Self-contained training replay for Profile-Guided Optimization (PGO).
//! Replays realistic traffic through the real HTTP parser, router match-tree,
//! JWT verification, Postgres binary decoding, and JSON renderers.
//! Owned by `toolchain`.

use crate::net::http::{parse_http_request, HttpMethod, ParseResult};
use crate::api::routes::match_route;
use crate::api::render::{
    render_article, render_article_list, render_comment, render_comments_list,
    render_errors, render_profile, render_tags, render_user,
    ArticleRow, CommentRow, ProfileRow, UserRow,
};
use crate::sec::jwt::{jwt_verify, jwt_sign};
use crate::pg::decode::{read_i64, read_col_raw};

const RECORDED_TRAIN_REQUESTS: &[&[u8]] = &[
    b"GET /api/tags HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAccept: application/json\r\n\r\n",
    b"GET /api/articles?limit=20&offset=0 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAccept: application/json\r\n\r\n",
    b"GET /api/articles/feed?limit=20&offset=0 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAccept: application/json\r\n\r\n",
    b"GET /api/articles/how-to-train-your-dragon-1 HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAccept: application/json\r\n\r\n",
    b"GET /api/articles/how-to-train-your-dragon-1/comments HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAccept: application/json\r\n\r\n",
    b"POST /api/articles/how-to-train-your-dragon-1/favorite HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAuthorization: Token test\r\n\r\n",
    b"GET /api/profiles/dragontrainer HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAccept: application/json\r\n\r\n",
    b"GET /api/user HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nAuthorization: Token test\r\nAccept: application/json\r\n\r\n",
    b"POST /api/users/login HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nContent-Type: application/json\r\nContent-Length: 54\r\n\r\n{\"user\":{\"email\":\"user@example.com\",\"password\":\"secret\"}}",
];

pub fn run_training_workload() {
    let training_token = jwt_sign(12345);
    let mut out_buf = Vec::with_capacity(4096);

    // Mock Postgres binary column buffers
    let id_bytes = 42i64.to_be_bytes();
    let text_bytes = b"how-to-train-your-dragon-1";

    let author = ProfileRow {
        username: "hiccup",
        bio: Some("Dragon rider"),
        image: None,
        following: false,
    };

    let article = ArticleRow {
        slug: "how-to-train-your-dragon-1",
        title: "How to Train Your Dragon",
        description: "A story about dragons",
        body: Some("Detailed dragon training techniques and flying tactics."),
        tags: &["animation", "dragons", "vikings"],
        created_at_us: 796737600_000_000,
        updated_at_us: 796737600_000_000,
        favorited: false,
        favorites_count: 42,
        author: author.clone(),
    };

    let comment = CommentRow {
        id: 101,
        created_at_us: 796737600_000_000,
        updated_at_us: 796737600_000_000,
        body: "Great article!",
        author: author.clone(),
    };

    let articles = [article.clone()];
    let comments = [comment.clone()];

    // 25,000 iterations (~25-50ms)
    for i in 0..25_000 {
        let req_raw = RECORDED_TRAIN_REQUESTS[i % RECORDED_TRAIN_REQUESTS.len()];

        // 1. Real HTTP Parser
        if let ParseResult::Complete(req) = parse_http_request(req_raw) {
            let method_str = match req.method {
                HttpMethod::Get => "GET",
                HttpMethod::Post => "POST",
                HttpMethod::Put => "PUT",
                HttpMethod::Delete => "DELETE",
                _ => "GET",
            };

            // 2. Real Router Match-Tree
            if let Some((route, params)) = match_route(method_str, req.path) {
                std::hint::black_box(route);
                std::hint::black_box(params);
            }
        }

        // 3. Real JWT Verification
        if i % 8 == 0 {
            if let Some(viewer) = jwt_verify(&training_token) {
                std::hint::black_box(viewer);
            }
        }

        // 4. Real Postgres binary decoding
        if let Ok((id, _)) = read_i64(&id_bytes) {
            std::hint::black_box(id);
        }
        if let Ok((slug_raw, _)) = read_col_raw(text_bytes) {
            std::hint::black_box(slug_raw);
        }

        // 5. Real JSON rendering across all schemas
        out_buf.clear();
        render_article(&mut out_buf, &article);

        if i % 3 == 0 {
            out_buf.clear();
            render_article_list(&mut out_buf, &articles, 1);
        }

        if i % 5 == 0 {
            out_buf.clear();
            let user = UserRow {
                email: "hiccup@berk.org",
                token: &training_token,
                username: "hiccup",
                bio: Some("Dragon rider"),
                image: None,
            };
            render_user(&mut out_buf, &user);
        }

        if i % 7 == 0 {
            out_buf.clear();
            render_profile(&mut out_buf, &author);
        }

        if i % 11 == 0 {
            out_buf.clear();
            render_comment(&mut out_buf, &comment);
            out_buf.clear();
            render_comments_list(&mut out_buf, &comments);
        }

        if i % 20 == 0 {
            out_buf.clear();
            render_tags(&mut out_buf, &["animation", "dragons", "vikings", "training"]);
        }

        if i % 50 == 0 {
            out_buf.clear();
            render_errors(&mut out_buf, &["Record not found or access denied"]);
        }
    }
}
