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

const MONTH_LENGTHS_FROM_MARCH: [u32; 12] = [31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29];

#[inline(always)]
fn put2(buf: &mut [u8; 24], at: usize, val: u32) {
    buf[at] = b'0' + ((val / 10) % 10) as u8;
    buf[at + 1] = b'0' + (val % 10) as u8;
}

#[inline(always)]
fn put3(buf: &mut [u8; 24], at: usize, val: u32) {
    buf[at] = b'0' + ((val / 100) % 10) as u8;
    buf[at + 1] = b'0' + ((val / 10) % 10) as u8;
    buf[at + 2] = b'0' + (val % 10) as u8;
}

#[inline(always)]
fn put4(buf: &mut [u8; 24], at: usize, val: u32) {
    buf[at] = b'0' + ((val / 1000) % 10) as u8;
    buf[at + 1] = b'0' + ((val / 100) % 10) as u8;
    buf[at + 2] = b'0' + ((val / 10) % 10) as u8;
    buf[at + 3] = b'0' + (val % 10) as u8;
}

/// Format a Postgres binary timestamp (microseconds since 2000-01-01 00:00:00 UTC)
/// into an RFC 3339 UTC string with exactly 3 fractional digits: "YYYY-MM-DDTHH:MM:SS.mmmZ".
/// Truncates fractional milliseconds toward negative infinity.
#[inline]
pub fn format_pg_timestamp(pg_us: i64, buf: &mut [u8; 24]) {
    const US_PER_DAY: i64 = 86_400_000_000;
    let days_since_2000 = pg_us.div_euclid(US_PER_DAY);
    let us_in_day = pg_us.rem_euclid(US_PER_DAY);

    let sec_of_day = (us_in_day / 1_000_000) as u32;
    let rem_us = (us_in_day % 1_000_000) as u32;
    let millis = rem_us / 1000;

    let hours = sec_of_day / 3600;
    let rem_sec = sec_of_day % 3600;
    let minutes = rem_sec / 60;
    let seconds = rem_sec % 60;

    // Shift origin from 2000-01-01 to 2000-03-01 (60 days) so leap day falls at year end
    let days_since_epoch = days_since_2000 - 60;

    let cycles400 = days_since_epoch.div_euclid(146_097);
    let day_in_400 = days_since_epoch.rem_euclid(146_097);

    // 100-year blocks (36,524 days each; clamp to 3 because final century has 36,525 days)
    let century = (day_in_400 / 36_524).min(3);
    let day_in_100 = day_in_400 - century * 36_524;

    // 4-year blocks (1,461 days each; clamp to 24 because 25 * 4 = 100)
    let cycle4 = (day_in_100 / 1_461).min(24);
    let day_in_4 = day_in_100 - cycle4 * 1_461;

    // 1-year blocks (365 days each; clamp to 3 because leap year is year 3)
    let year_in_cycle = (day_in_4 / 365).min(3);
    let day_in_year = (day_in_4 - year_in_cycle * 365) as u32;

    let year_from_march = cycles400 * 400 + century * 100 + cycle4 * 4 + year_in_cycle;

    let mut month_idx = 0usize;
    let mut day_in_month = day_in_year;
    for (idx, &month_len) in MONTH_LENGTHS_FROM_MARCH.iter().enumerate() {
        if day_in_month < month_len {
            month_idx = idx;
            break;
        }
        day_in_month -= month_len;
    }
    let day = day_in_month + 1;

    let (cal_year, cal_month) = if month_idx < 10 {
        (2000 + year_from_march, (month_idx + 3) as u32)
    } else {
        (2000 + year_from_march + 1, (month_idx - 9) as u32)
    };

    put4(buf, 0, cal_year as u32);
    buf[4] = b'-';
    put2(buf, 5, cal_month);
    buf[7] = b'-';
    put2(buf, 8, day);
    buf[10] = b'T';
    put2(buf, 11, hours);
    buf[13] = b':';
    put2(buf, 14, minutes);
    buf[16] = b':';
    put2(buf, 17, seconds);
    buf[19] = b'.';
    put3(buf, 20, millis);
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

#[cfg(test)]
mod ts_tests {
    use super::*;

    fn fmt(pg_us: i64) -> String {
        let mut buf = [0u8; 24];
        format_pg_timestamp(pg_us, &mut buf);
        std::str::from_utf8(&buf).unwrap().to_string()
    }

    #[test]
    fn test_pg_timestamp_spec_cases() {
        assert_eq!(fmt(0), "2000-01-01T00:00:00.000Z");
        assert_eq!(fmt(-1), "1999-12-31T23:59:59.999Z");
        assert_eq!(fmt(1_000), "2000-01-01T00:00:00.001Z");
        assert_eq!(fmt(86_400_000_000 * 59), "2000-02-29T00:00:00.000Z");
        assert_eq!(fmt(86_400_000_000 * 366), "2001-01-01T00:00:00.000Z");
        assert_eq!(fmt(762525296789000), "2024-02-29T12:34:56.789Z");
        assert_eq!(fmt(3160857600000000), "2100-03-01T00:00:00.000Z");
        assert_eq!(fmt(-946684800000000), "1970-01-01T00:00:00.000Z");
    }

    fn is_leap_year(y: i64) -> bool {
        (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
    }

    fn days_in_year(y: i64) -> i64 {
        if is_leap_year(y) { 366 } else { 365 }
    }

    fn days_in_month(y: i64, m: usize) -> i64 {
        match m {
            1 => 31,
            2 => if is_leap_year(y) { 29 } else { 28 },
            3 => 31,
            4 => 30,
            5 => 31,
            6 => 30,
            7 => 31,
            8 => 31,
            9 => 30,
            10 => 31,
            11 => 30,
            12 => 31,
            _ => unreachable!(),
        }
    }

    fn reference_format_pg_timestamp(pg_us: i64) -> String {
        let days_since_2000 = pg_us.div_euclid(86_400_000_000);
        let us_in_day = pg_us.rem_euclid(86_400_000_000);

        let sec_of_day = us_in_day / 1_000_000;
        let rem_us = us_in_day % 1_000_000;
        let millis = rem_us / 1000;
        let hour = sec_of_day / 3600;
        let min = (sec_of_day % 3600) / 60;
        let sec = sec_of_day % 60;

        let mut year = 2000i64;
        let mut rem_days = days_since_2000;
        if rem_days >= 0 {
            loop {
                let diy = days_in_year(year);
                if rem_days < diy {
                    break;
                }
                rem_days -= diy;
                year += 1;
            }
        } else {
            loop {
                year -= 1;
                let diy = days_in_year(year);
                rem_days += diy;
                if rem_days >= 0 {
                    break;
                }
            }
        }

        let mut month = 1usize;
        loop {
            let dim = days_in_month(year, month);
            if rem_days < dim {
                break;
            }
            rem_days -= dim;
            month += 1;
        }
        let day = rem_days + 1;

        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
            year, month, day, hour, min, sec, millis
        )
    }

    #[test]
    fn test_pg_timestamp_brute_force_reference_check() {
        let start_day = -36525 * 2;
        let end_day = 36525 * 2;
        let mut day_offset = start_day;
        while day_offset <= end_day {
            let pg_us = day_offset * 86_400_000_000 + 123_456;
            let expected = reference_format_pg_timestamp(pg_us);
            let actual = fmt(pg_us);
            assert_eq!(actual, expected, "Mismatch at day offset {}", day_offset);
            day_offset += 7;
        }
    }
}

