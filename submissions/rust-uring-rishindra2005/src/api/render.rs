//! JSON response rendering and HTTP/1.1 framing for Conduit endpoints.
//! Written from scratch for rust-uring-rishindra2005.

/// User database row ready for rendering.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserRow<'a> {
    pub email: &'a str,
    pub token: &'a str,
    pub username: &'a str,
    pub bio: Option<&'a str>,
    pub image: Option<&'a str>,
}

/// Profile database row ready for rendering.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProfileRow<'a> {
    pub username: &'a str,
    pub bio: Option<&'a str>,
    pub image: Option<&'a str>,
    pub following: bool,
}

/// Article database row ready for rendering.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArticleRow<'a> {
    pub slug: &'a str,
    pub title: &'a str,
    pub description: &'a str,
    pub body: Option<&'a str>,
    pub tags: &'a [&'a str],
    pub created_at_us: i64,
    pub updated_at_us: i64,
    pub favorited: bool,
    pub favorites_count: i64,
    pub author: ProfileRow<'a>,
}

/// Comment database row ready for rendering.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommentRow<'a> {
    pub id: i64,
    pub created_at_us: i64,
    pub updated_at_us: i64,
    pub body: &'a str,
    pub author: ProfileRow<'a>,
}

const PG_EPOCH_SECS_FROM_UNIX: i64 = 946_684_800;

/// Format a Postgres binary timestamp (microseconds since 2000-01-01 00:00:00 UTC)
/// into an RFC 3339 UTC string with exactly 3 fractional digits: "YYYY-MM-DDTHH:MM:SS.mmmZ".
/// Truncates fractional milliseconds per challenge rules.
#[inline]
pub fn format_pg_timestamp(pg_us: i64, buf: &mut [u8; 24]) {
    let total_secs = PG_EPOCH_SECS_FROM_UNIX + (pg_us / 1_000_000);
    let mut rem_us = pg_us % 1_000_000;
    let mut unix_secs = total_secs;
    if rem_us < 0 {
        rem_us += 1_000_000;
        unix_secs -= 1;
    }
    let frac_ms = (rem_us / 1000) as u32;

    let mut unix_days = unix_secs / 86400;
    let mut sec_of_day = unix_secs % 86400;
    if sec_of_day < 0 {
        sec_of_day += 86400;
        unix_days -= 1;
    }

    let hour = (sec_of_day / 3600) as u32;
    let min = ((sec_of_day % 3600) / 60) as u32;
    let sec = (sec_of_day % 60) as u32;

    // Howard Hinnant's civil date algorithm from days since 1970-01-01
    let z = unix_days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let yr = (if m <= 2 { y + 1 } else { y }) as u32;

    buf[0] = b'0' + ((yr / 1000) % 10) as u8;
    buf[1] = b'0' + ((yr / 100) % 10) as u8;
    buf[2] = b'0' + ((yr / 10) % 10) as u8;
    buf[3] = b'0' + (yr % 10) as u8;
    buf[4] = b'-';
    buf[5] = b'0' + (m / 10) as u8;
    buf[6] = b'0' + (m % 10) as u8;
    buf[7] = b'-';
    buf[8] = b'0' + (d / 10) as u8;
    buf[9] = b'0' + (d % 10) as u8;
    buf[10] = b'T';
    buf[11] = b'0' + (hour / 10) as u8;
    buf[12] = b'0' + (hour % 10) as u8;
    buf[13] = b':';
    buf[14] = b'0' + (min / 10) as u8;
    buf[15] = b'0' + (min % 10) as u8;
    buf[16] = b':';
    buf[17] = b'0' + (sec / 10) as u8;
    buf[18] = b'0' + (sec % 10) as u8;
    buf[19] = b'.';
    buf[20] = b'0' + ((frac_ms / 100) % 10) as u8;
    buf[21] = b'0' + ((frac_ms / 10) % 10) as u8;
    buf[22] = b'0' + (frac_ms % 10) as u8;
    buf[23] = b'Z';
}

/// Pre-rendered static HTTP 204 No Content response (keep-alive)
pub const STATIC_204_KEEPALIVE: &[u8] = b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n";

/// Pre-rendered static HTTP 204 No Content response (close)
pub const STATIC_204_CLOSE: &[u8] = b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

/// Escapes a JSON string into `out`. Fast path memcpy for clean strings.
#[inline]
pub fn escape_json_str(s: &str, out: &mut Vec<u8>) {
    let bytes = s.as_bytes();
    // Fast path: check if any escaping is needed at all.
    // ASCII characters >= 0x20 except '"' (0x22) and '\' (0x5C) require no escaping.
    let needs_escape = bytes.iter().any(|&b| b < 0x20 || b == b'"' || b == b'\\');
    if !needs_escape {
        out.extend_from_slice(bytes);
        return;
    }

    let mut last = 0;
    for (i, &b) in bytes.iter().enumerate() {
        let esc: &[u8] = match b {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0x08 => b"\\b",
            0x0C => b"\\f",
            0..=0x1F => {
                out.extend_from_slice(&bytes[last..i]);
                const HEX: &[u8; 16] = b"0123456789abcdef";
                let u_esc = [
                    b'\\',
                    b'u',
                    b'0',
                    b'0',
                    HEX[(b >> 4) as usize],
                    HEX[(b & 0x0F) as usize],
                ];
                out.extend_from_slice(&u_esc);
                last = i + 1;
                continue;
            }
            _ => continue,
        };
        out.extend_from_slice(&bytes[last..i]);
        out.extend_from_slice(esc);
        last = i + 1;
    }
    out.extend_from_slice(&bytes[last..]);
}

#[inline]
fn append_i64(mut n: i64, out: &mut Vec<u8>) {
    if n == 0 {
        out.push(b'0');
        return;
    }
    let neg = n < 0;
    if neg {
        n = -n;
    }
    let mut temp = [0u8; 20];
    let mut pos = 20;
    let mut un = n as u64;
    while un > 0 {
        pos -= 1;
        temp[pos] = b'0' + (un % 10) as u8;
        un /= 10;
    }
    if neg {
        pos -= 1;
        temp[pos] = b'-';
    }
    out.extend_from_slice(&temp[pos..]);
}

#[inline]
fn append_usize(mut n: usize, out: &mut Vec<u8>) {
    if n == 0 {
        out.push(b'0');
        return;
    }
    let mut temp = [0u8; 20];
    let mut pos = 20;
    while n > 0 {
        pos -= 1;
        temp[pos] = b'0' + (n % 10) as u8;
        n /= 10;
    }
    out.extend_from_slice(&temp[pos..]);
}

/// Render profile inner object: `"username":"...","bio":...,"image":...,"following":...`
#[inline]
fn render_profile_fields(out: &mut Vec<u8>, profile: &ProfileRow) {
    out.extend_from_slice(b"\"username\":\"");
    escape_json_str(profile.username, out);
    out.extend_from_slice(b"\",\"bio\":");
    match profile.bio {
        Some(b) => {
            out.push(b'"');
            escape_json_str(b, out);
            out.push(b'"');
        }
        None => out.extend_from_slice(b"null"),
    }
    out.extend_from_slice(b",\"image\":");
    match profile.image {
        Some(img) => {
            out.push(b'"');
            escape_json_str(img, out);
            out.push(b'"');
        }
        None => out.extend_from_slice(b"null"),
    }
    out.extend_from_slice(b",\"following\":");
    out.extend_from_slice(if profile.following { b"true" } else { b"false" });
}

/// Render a User response: `{"user":{"email":"...","token":"...","username":"...","bio":...,"image":...}}`
pub fn render_user(out: &mut Vec<u8>, user: &UserRow) {
    out.extend_from_slice(b"{\"user\":{\"email\":\"");
    escape_json_str(user.email, out);
    out.extend_from_slice(b"\",\"token\":\"");
    escape_json_str(user.token, out);
    out.extend_from_slice(b"\",\"username\":\"");
    escape_json_str(user.username, out);
    out.extend_from_slice(b"\",\"bio\":");
    match user.bio {
        Some(b) => {
            out.push(b'"');
            escape_json_str(b, out);
            out.push(b'"');
        }
        None => out.extend_from_slice(b"null"),
    }
    out.extend_from_slice(b",\"image\":");
    match user.image {
        Some(img) => {
            out.push(b'"');
            escape_json_str(img, out);
            out.push(b'"');
        }
        None => out.extend_from_slice(b"null"),
    }
    out.extend_from_slice(b"}}");
}

/// Render a Profile response: `{"profile":{"username":"...","bio":...,"image":...,"following":...}}`
pub fn render_profile(out: &mut Vec<u8>, profile: &ProfileRow) {
    out.extend_from_slice(b"{\"profile\":{");
    render_profile_fields(out, profile);
    out.extend_from_slice(b"}}");
}

/// Render an article object. If `include_body` is false, "body" field is omitted (used in article lists).
#[inline]
pub fn render_article_object(out: &mut Vec<u8>, article: &ArticleRow, include_body: bool) {
    out.extend_from_slice(b"{\"slug\":\"");
    escape_json_str(article.slug, out);
    out.extend_from_slice(b"\",\"title\":\"");
    escape_json_str(article.title, out);
    out.extend_from_slice(b"\",\"description\":\"");
    escape_json_str(article.description, out);
    out.push(b'"');

    if include_body {
        out.extend_from_slice(b",\"body\":\"");
        if let Some(body) = article.body {
            escape_json_str(body, out);
        }
        out.push(b'"');
    }

    out.extend_from_slice(b",\"tagList\":[");
    for (i, &tag) in article.tags.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.push(b'"');
        escape_json_str(tag, out);
        out.push(b'"');
    }
    out.extend_from_slice(b"],\"createdAt\":\"");

    let mut ts_buf = [0u8; 24];
    format_pg_timestamp(article.created_at_us, &mut ts_buf);
    out.extend_from_slice(&ts_buf);

    out.extend_from_slice(b"\",\"updatedAt\":\"");
    format_pg_timestamp(article.updated_at_us, &mut ts_buf);
    out.extend_from_slice(&ts_buf);

    out.extend_from_slice(b"\",\"favorited\":");
    out.extend_from_slice(if article.favorited { b"true" } else { b"false" });
    out.extend_from_slice(b",\"favoritesCount\":");
    append_i64(article.favorites_count, out);

    out.extend_from_slice(b",\"author\":{");
    render_profile_fields(out, &article.author);
    out.extend_from_slice(b"}}");
}

/// Render a single Article response: `{"article":{...}}`
pub fn render_article(out: &mut Vec<u8>, article: &ArticleRow) {
    out.extend_from_slice(b"{\"article\":");
    render_article_object(out, article, true);
    out.push(b'}');
}

/// Render ArticlesList / Feed response: `{"articles":[...],"articlesCount":n}`
pub fn render_article_list(out: &mut Vec<u8>, articles: &[ArticleRow], count: i64) {
    out.extend_from_slice(b"{\"articles\":[");
    for (i, art) in articles.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        render_article_object(out, art, false);
    }
    out.extend_from_slice(b"],\"articlesCount\":");
    append_i64(count, out);
    out.push(b'}');
}

/// Render a comment object: `{"id":...,"createdAt":"...","updatedAt":"...","body":"...","author":{...}}`
#[inline]
pub fn render_comment_object(out: &mut Vec<u8>, comment: &CommentRow) {
    out.extend_from_slice(b"{\"id\":");
    append_i64(comment.id, out);

    out.extend_from_slice(b",\"createdAt\":\"");
    let mut ts_buf = [0u8; 24];
    format_pg_timestamp(comment.created_at_us, &mut ts_buf);
    out.extend_from_slice(&ts_buf);

    out.extend_from_slice(b"\",\"updatedAt\":\"");
    format_pg_timestamp(comment.updated_at_us, &mut ts_buf);
    out.extend_from_slice(&ts_buf);

    out.extend_from_slice(b"\",\"body\":\"");
    escape_json_str(comment.body, out);
    out.extend_from_slice(b"\",\"author\":{");
    render_profile_fields(out, &comment.author);
    out.extend_from_slice(b"}}");
}

/// Render a single Comment response: `{"comment":{...}}`
pub fn render_comment(out: &mut Vec<u8>, comment: &CommentRow) {
    out.extend_from_slice(b"{\"comment\":");
    render_comment_object(out, comment);
    out.push(b'}');
}

/// Render CommentsList response: `{"comments":[...]}`
pub fn render_comments_list(out: &mut Vec<u8>, comments: &[CommentRow]) {
    out.extend_from_slice(b"{\"comments\":[");
    for (i, c) in comments.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        render_comment_object(out, c);
    }
    out.extend_from_slice(b"]}");
}

/// Render Tags response: `{"tags":["t1","t2",...]}`
pub fn render_tags(out: &mut Vec<u8>, tags: &[&str]) {
    out.extend_from_slice(b"{\"tags\":[");
    for (i, &t) in tags.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.push(b'"');
        escape_json_str(t, out);
        out.push(b'"');
    }
    out.extend_from_slice(b"]}");
}

/// Render Errors response: `{"errors":{"body":["..."]}}`
pub fn render_errors(out: &mut Vec<u8>, messages: &[&str]) {
    out.extend_from_slice(b"{\"errors\":{\"body\":[");
    for (i, &msg) in messages.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        out.push(b'"');
        escape_json_str(msg, out);
        out.push(b'"');
    }
    out.extend_from_slice(b"]}}");
}

/// Construct full HTTP/1.1 response framing with status line, headers, and body.
pub fn frame_response(
    status_code: u16,
    status_text: &str,
    body: &[u8],
    keepalive: bool,
) -> Vec<u8> {
    if status_code == 204 {
        return if keepalive {
            STATIC_204_KEEPALIVE.to_vec()
        } else {
            STATIC_204_CLOSE.to_vec()
        };
    }

    let conn_bytes: &[u8] = if keepalive {
        b"\r\nConnection: keep-alive\r\n\r\n" as &[u8]
    } else {
        b"\r\nConnection: close\r\n\r\n" as &[u8]
    };

    // Fast path for 200 OK (vast majority of responses in Conduit)
    if status_code == 200 {
        const HDR_PREFIX: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
        let mut resp = Vec::with_capacity(HDR_PREFIX.len() + 10 + conn_bytes.len() + body.len());
        resp.extend_from_slice(HDR_PREFIX);
        append_usize(body.len(), &mut resp);
        resp.extend_from_slice(conn_bytes);
        resp.extend_from_slice(body);
        return resp;
    }

    let mut resp = Vec::with_capacity(64 + conn_bytes.len() + body.len());
    resp.extend_from_slice(b"HTTP/1.1 ");
    append_usize(status_code as usize, &mut resp);
    resp.push(b' ');
    resp.extend_from_slice(status_text.as_bytes());
    resp.extend_from_slice(b"\r\nContent-Type: application/json\r\nContent-Length: ");
    append_usize(body.len(), &mut resp);
    resp.extend_from_slice(conn_bytes);
    resp.extend_from_slice(body);
    resp
}
