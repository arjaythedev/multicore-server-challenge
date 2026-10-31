//! High-throughput zero-copy JSON streaming and response serialization.

/// Escapes a UTF-8 string into valid JSON string characters and appends to dst.
#[inline]
pub fn append_json_str(dst: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    let mut start = 0;

    for (i, &b) in bytes.iter().enumerate() {
        let escape = match b {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0x00..=0x1f => {
                dst.extend_from_slice(&bytes[start..i]);
                const HEX_DIGITS: &[u8; 16] = b"0123456789abcdef";
                dst.extend_from_slice(b"\\u00");
                dst.push(HEX_DIGITS[(b >> 4) as usize]);
                dst.push(HEX_DIGITS[(b & 0xf) as usize]);
                start = i + 1;
                continue;
            }
            _ => continue,
        };

        dst.extend_from_slice(&bytes[start..i]);
        dst.extend_from_slice(escape);
        start = i + 1;
    }

    dst.extend_from_slice(&bytes[start..]);
}

#[inline(always)]
pub fn append_quoted_str(dst: &mut Vec<u8>, s: &str) {
    dst.push(b'"');
    append_json_str(dst, s);
    dst.push(b'"');
}

#[inline(always)]
pub fn append_nullable_str(dst: &mut Vec<u8>, s: Option<&str>) {
    match s {
        Some(v) => append_quoted_str(dst, v),
        None => dst.extend_from_slice(b"null"),
    }
}

#[inline(always)]
pub fn append_u64(dst: &mut Vec<u8>, n: u64) {
    let mut buf = itoa::Buffer::new();
    dst.extend_from_slice(buf.format(n).as_bytes());
}

#[inline(always)]
pub fn append_i64(dst: &mut Vec<u8>, n: i64) {
    let mut buf = itoa::Buffer::new();
    dst.extend_from_slice(buf.format(n).as_bytes());
}

/// Serializes Conduit error format: {"errors":{"body":["<msg>"]}}
pub fn format_error_json(msg: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(64 + msg.len());
    out.extend_from_slice(b"{\"errors\":{\"body\":[");
    append_quoted_str(&mut out, msg);
    out.extend_from_slice(b"]}}");
    out
}

/// Serializes User response: {"user":{"email":"...","token":"...","username":"...","bio":...,"image":...}}
pub fn format_user_json(
    email: &str,
    token: &str,
    username: &str,
    bio: Option<&str>,
    image: Option<&str>,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(128 + email.len() + token.len() + username.len());
    out.extend_from_slice(b"{\"user\":{\"email\":");
    append_quoted_str(&mut out, email);
    out.extend_from_slice(b",\"token\":");
    append_quoted_str(&mut out, token);
    out.extend_from_slice(b",\"username\":");
    append_quoted_str(&mut out, username);
    out.extend_from_slice(b",\"bio\":");
    append_nullable_str(&mut out, bio);
    out.extend_from_slice(b",\"image\":");
    append_nullable_str(&mut out, image);
    out.extend_from_slice(b"}}");
    out
}

/// Writes Profile object into existing buffer:
/// {"username":"...","bio":...,"image":...,"following":bool}
pub fn write_profile_json(
    dst: &mut Vec<u8>,
    username: &str,
    bio: Option<&str>,
    image: Option<&str>,
    following: bool,
) {
    dst.extend_from_slice(b"{\"username\":");
    append_quoted_str(dst, username);
    dst.extend_from_slice(b",\"bio\":");
    append_nullable_str(dst, bio);
    dst.extend_from_slice(b",\"image\":");
    append_nullable_str(dst, image);
    dst.extend_from_slice(if following {
        b",\"following\":true}"
    } else {
        b",\"following\":false}"
    });
}

/// Serializes Profile response: {"profile":{...}}
pub fn format_profile_json(
    username: &str,
    bio: Option<&str>,
    image: Option<&str>,
    following: bool,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(128 + username.len());
    out.extend_from_slice(b"{\"profile\":");
    write_profile_json(&mut out, username, bio, image, following);
    out.push(b'}');
    out
}

/// Writes an Article object into an existing buffer.
pub fn write_article_json(
    dst: &mut Vec<u8>,
    slug: &str,
    title: &str,
    description: &str,
    body: Option<&str>,
    tag_list: &[String],
    created_at: &str,
    updated_at: &str,
    favorited: bool,
    favorites_count: i64,
    author_username: &str,
    author_bio: Option<&str>,
    author_image: Option<&str>,
    author_following: bool,
) {
    dst.extend_from_slice(b"{\"slug\":");
    append_quoted_str(dst, slug);
    dst.extend_from_slice(b",\"title\":");
    append_quoted_str(dst, title);
    dst.extend_from_slice(b",\"description\":");
    append_quoted_str(dst, description);
    if let Some(b) = body {
        dst.extend_from_slice(b",\"body\":");
        append_quoted_str(dst, b);
    }
    dst.extend_from_slice(b",\"tagList\":[");
    for (i, tag) in tag_list.iter().enumerate() {
        if i > 0 {
            dst.push(b',');
        }
        append_quoted_str(dst, tag);
    }
    dst.extend_from_slice(b"],\"createdAt\":");
    append_quoted_str(dst, created_at);
    dst.extend_from_slice(b",\"updatedAt\":");
    append_quoted_str(dst, updated_at);
    dst.extend_from_slice(if favorited {
        b",\"favorited\":true"
    } else {
        b",\"favorited\":false"
    });
    dst.extend_from_slice(b",\"favoritesCount\":");
    append_i64(dst, favorites_count);
    dst.extend_from_slice(b",\"author\":");
    write_profile_json(dst, author_username, author_bio, author_image, author_following);
    dst.push(b'}');
}

/// Serializes single Article response: {"article":{...}}
pub fn format_article_json(
    slug: &str,
    title: &str,
    description: &str,
    body: Option<&str>,
    tag_list: &[String],
    created_at: &str,
    updated_at: &str,
    favorited: bool,
    favorites_count: i64,
    author_username: &str,
    author_bio: Option<&str>,
    author_image: Option<&str>,
    author_following: bool,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(512);
    out.extend_from_slice(b"{\"article\":");
    write_article_json(
        &mut out,
        slug,
        title,
        description,
        body,
        tag_list,
        created_at,
        updated_at,
        favorited,
        favorites_count,
        author_username,
        author_bio,
        author_image,
        author_following,
    );
    out.push(b'}');
    out
}

/// Writes Comment object into existing buffer:
/// {"id":num,"createdAt":"...","updatedAt":"...","body":"...","author":Profile}
pub fn write_comment_json(
    dst: &mut Vec<u8>,
    id: i64,
    created_at: &str,
    updated_at: &str,
    body: &str,
    author_username: &str,
    author_bio: Option<&str>,
    author_image: Option<&str>,
    author_following: bool,
) {
    dst.extend_from_slice(b"{\"id\":");
    append_i64(dst, id);
    dst.extend_from_slice(b",\"createdAt\":");
    append_quoted_str(dst, created_at);
    dst.extend_from_slice(b",\"updatedAt\":");
    append_quoted_str(dst, updated_at);
    dst.extend_from_slice(b",\"body\":");
    append_quoted_str(dst, body);
    dst.extend_from_slice(b",\"author\":");
    write_profile_json(dst, author_username, author_bio, author_image, author_following);
    dst.push(b'}');
}

/// Serializes single Comment response: {"comment":{...}}
pub fn format_comment_json(
    id: i64,
    created_at: &str,
    updated_at: &str,
    body: &str,
    author_username: &str,
    author_bio: Option<&str>,
    author_image: Option<&str>,
    author_following: bool,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(256);
    out.extend_from_slice(b"{\"comment\":");
    write_comment_json(
        &mut out,
        id,
        created_at,
        updated_at,
        body,
        author_username,
        author_bio,
        author_image,
        author_following,
    );
    out.push(b'}');
    out
}

/// Serializes Tags response: {"tags":["tag1","tag2",...]}
pub fn format_tags_json(tags: &[&str]) -> Vec<u8> {
    let mut out = Vec::with_capacity(32 + tags.len() * 16);
    out.extend_from_slice(b"{\"tags\":[");
    for (i, tag) in tags.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        append_quoted_str(&mut out, tag);
    }
    out.extend_from_slice(b"]}");
    out
}
