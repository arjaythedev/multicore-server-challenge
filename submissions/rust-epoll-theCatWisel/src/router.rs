use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use crate::auth::TokenSigner;
use crate::codec::{self, JsonMap, JsonVal};
use crate::engine::{self, CryptoTask, ReadOp, ReadTask, WriteOp, WriteTask};
use crate::reactor::{self, ReplyAddr};

struct QueueInner<T> {
    q: VecDeque<T>,
    since: Option<Instant>,
    hold: usize,
    waiting: usize,
}

pub struct WorkQueue<T> {
    inner: Mutex<QueueInner<T>>,
    ready: Condvar,
}

impl<T> WorkQueue<T> {
    pub const fn new() -> Self {
        WorkQueue {
            inner: Mutex::new(QueueInner {
                q: VecDeque::new(),
                since: None,
                hold: 1,
                waiting: 0,
            }),
            ready: Condvar::new(),
        }
    }

    pub fn push(&self, item: T) {
        let mut g = self.inner.lock().unwrap();
        let was_empty = g.q.is_empty();
        if was_empty {
            g.since = Some(Instant::now());
        }
        g.q.push_back(item);
        let notify = g.waiting > 0 && (was_empty || g.q.len() >= g.hold);
        drop(g);
        if notify {
            self.ready.notify_one();
        }
    }

    pub fn push_front(&self, item: T) {
        let mut g = self.inner.lock().unwrap();
        let was_empty = g.q.is_empty();
        if was_empty {
            g.since = Some(Instant::now());
        }
        g.q.push_front(item);
        let notify = g.waiting > 0 && (was_empty || g.q.len() >= g.hold);
        drop(g);
        if notify {
            self.ready.notify_one();
        }
    }

    pub fn notify(&self) {
        self.ready.notify_one();
    }

    pub fn push_batch(&self, batch: &mut Vec<T>) {
        if batch.is_empty() {
            return;
        }
        let mut g = self.inner.lock().unwrap();
        let was_empty = g.q.is_empty();
        if was_empty {
            g.since = Some(Instant::now());
        }
        g.q.extend(batch.drain(..));
        let notify = g.waiting > 0 && (was_empty || g.q.len() >= g.hold);
        drop(g);
        if notify {
            self.ready.notify_one();
        }
    }

    pub fn push_batch_front(&self, batch: &mut Vec<T>) {
        if batch.is_empty() {
            return;
        }
        let mut g = self.inner.lock().unwrap();
        let was_empty = g.q.is_empty();
        if was_empty {
            g.since = Some(Instant::now());
        }
        for item in batch.drain(..).rev() {
            g.q.push_front(item);
        }
        let notify = g.waiting > 0 && (was_empty || g.q.len() >= g.hold);
        drop(g);
        if notify {
            self.ready.notify_one();
        }
    }

    pub fn drain_up_to(&self, max_items: usize, dst: &mut Vec<T>) {
        let mut g = self.inner.lock().unwrap();
        while g.q.is_empty() {
            g.hold = 1;
            g.waiting += 1;
            g = self.ready.wait(g).unwrap();
            g.waiting -= 1;
        }
        let take_n = g.q.len().min(max_items);
        dst.extend(g.q.drain(..take_n));
        if g.q.is_empty() {
            g.since = None;
        } else {
            g.since = Some(Instant::now());
            if g.waiting > 0 {
                self.ready.notify_one();
            }
        }
    }

    pub fn take_aged(
        &self,
        want: usize,
        max_age: Duration,
        max_cap: usize,
        dst: &mut Vec<T>,
    ) {
        let mut g = self.inner.lock().unwrap();
        while g.q.is_empty() {
            g.hold = 1;
            g.waiting += 1;
            g = self.ready.wait(g).unwrap();
            g.waiting -= 1;
        }
        if !max_age.is_zero() && g.q.len() < want {
            let deadline = g.since.unwrap_or_else(Instant::now) + max_age;
            while g.q.len() < want {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                g.hold = want;
                g.waiting += 1;
                g = self.ready.wait_timeout(g, deadline - now).unwrap().0;
                g.waiting -= 1;
                g.hold = 1;
            }
        }
        let take_n = g.q.len().min(max_cap);
        dst.extend(g.q.drain(..take_n));
        if g.q.is_empty() {
            g.since = None;
        } else {
            g.since = Some(Instant::now());
            if g.waiting > 0 {
                self.ready.notify_one();
            }
        }
    }
}

pub struct HttpReq<'a> {
    pub method: &'a [u8],
    pub path: &'a [u8],
    pub query: &'a [u8],
    pub auth: Option<&'a [u8]>,
    pub body: &'a [u8],
}

pub enum Dispatch {
    Immediate(u16, Vec<u8>),
    Enqueued,
}

#[inline]
fn fail_now(status: u16, msg: &str) -> Dispatch {
    Dispatch::Immediate(status, reactor::make_error_json(msg))
}

#[inline]
fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn percent_decode(src: &[u8], decode_plus: bool) -> Option<String> {
    let decoded = percent_decode_raw(src, decode_plus)?;
    if decoded.contains('\0') {
        return None;
    }
    Some(decoded)
}

fn percent_decode_raw(src: &[u8], decode_plus: bool) -> Option<String> {
    if !src.iter().any(|&b| b == b'%' || (decode_plus && b == b'+')) {
        return std::str::from_utf8(src).ok().map(String::from);
    }
    let mut out = Vec::with_capacity(src.len());
    let mut i = 0;
    while i < src.len() {
        match src[i] {
            b'%' => {
                let hi = hex_nibble(*src.get(i + 1)?)?;
                let lo = hex_nibble(*src.get(i + 2)?)?;
                out.push((hi << 4) | lo);
                i += 3;
            }
            b'+' if decode_plus => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

#[inline]
fn parse_pos_int_bytes(raw: &[u8]) -> Option<i64> {
    if raw.is_empty() || !raw.iter().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut val: i64 = 0;
    for &b in raw {
        val = val.checked_mul(10)?.checked_add((b - b'0') as i64)?;
    }
    Some(val)
}

#[inline]
fn parse_pos_int_str(s: &str) -> Option<i64> {
    parse_pos_int_bytes(s.as_bytes())
}

#[derive(Default)]
struct ListQuery {
    seen_limit: bool,
    limit: Option<i64>,
    seen_offset: bool,
    offset: Option<i64>,
    tag: Option<String>,
    author: Option<String>,
    favorited: Option<String>,
    impossible_filter: bool,
}

fn scan_list_query(raw: &[u8]) -> ListQuery {
    let mut q = ListQuery::default();
    if raw.is_empty() {
        return q;
    }
    for pair in raw.split(|&b| b == b'&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = match codec::find_byte(pair, b'=') {
            Some(eq) => (&pair[..eq], &pair[eq + 1..]),
            None => (pair, &b""[..]),
        };
        let owned_key: Option<String>;
        let key_str: &str = if !k.iter().any(|&b| b == b'%' || b == b'+') {
            match std::str::from_utf8(k) {
                Ok(s) if !s.contains('\0') => s,
                _ => continue,
            }
        } else {
            owned_key = percent_decode(k, true);
            match owned_key.as_deref() {
                Some(s) => s,
                None => continue,
            }
        };

        match key_str {
            "limit" => {
                if !q.seen_limit {
                    q.seen_limit = true;
                    if !v.iter().any(|&b| b == b'%' || b == b'+') {
                        q.limit = parse_pos_int_bytes(v);
                    } else {
                        q.limit = percent_decode(v, true).and_then(|s| parse_pos_int_str(&s));
                    }
                }
            }
            "offset" => {
                if !q.seen_offset {
                    q.seen_offset = true;
                    if !v.iter().any(|&b| b == b'%' || b == b'+') {
                        q.offset = parse_pos_int_bytes(v);
                    } else {
                        q.offset = percent_decode(v, true).and_then(|s| parse_pos_int_str(&s));
                    }
                }
            }
            "tag" | "author" | "favorited" => {
                let target = match key_str {
                    "tag" => &mut q.tag,
                    "author" => &mut q.author,
                    _ => &mut q.favorited,
                };
                if target.is_none() {
                    match percent_decode(v, true) {
                        Some(decoded) => *target = Some(decoded),
                        None => {
                            *target = Some(String::new());
                            q.impossible_filter = true;
                        }
                    }
                }
            }
            _ => {}
        }
    }
    q
}

#[inline]
fn validate_page_bounds(q: &ListQuery) -> Option<(i64, i64)> {
    let lim = if q.seen_limit {
        q.limit.filter(|n| (1..=100).contains(n))?
    } else {
        20
    };
    let off = if q.seen_offset {
        q.offset?.min(i64::MAX / 2)
    } else {
        0
    };
    Some((lim, off))
}

fn unwrap_json_envelope(body: &[u8], root_key: &str) -> Option<JsonMap> {
    let parsed = codec::parse_json(body)?;
    match parsed {
        JsonVal::Object(mut outer) => match outer.remove(root_key)? {
            JsonVal::Object(inner) => Some(inner),
            _ => None,
        },
        _ => None,
    }
}

fn contains_nul_char(map: &JsonMap) -> bool {
    fn check_val(v: &JsonVal) -> bool {
        match v {
            JsonVal::Str(s) => s.contains('\0'),
            JsonVal::Array(arr) => arr.iter().any(check_val),
            JsonVal::Object(obj) => obj.values().any(check_val),
            _ => false,
        }
    }
    map.values().any(check_val)
}

fn parse_valid_envelope(body: &[u8], root_key: &str) -> Result<JsonMap, Dispatch> {
    match unwrap_json_envelope(body, root_key) {
        Some(m) if contains_nul_char(&m) => Err(fail_now(422, "strings must not contain NUL")),
        Some(m) => Ok(m),
        None => Err(fail_now(422, "invalid request body")),
    }
}

fn optional_str_field(
    map: &JsonMap,
    key: &str,
    require_non_empty: bool,
) -> Result<Option<String>, ()> {
    match map.get(key) {
        None | Some(JsonVal::Null) => Ok(None),
        Some(JsonVal::Str(s)) if require_non_empty && s.is_empty() => Err(()),
        Some(JsonVal::Str(s)) => Ok(Some(s.clone())),
        Some(_) => Err(()),
    }
}

fn required_str_field(map: &JsonMap, key: &str) -> Result<String, ()> {
    optional_str_field(map, key, true)?.ok_or(())
}

enum AuthState<'a> {
    Anonymous,
    Rejected,
    Verified(i64, &'a [u8]),
}

#[inline]
fn verify_auth_header<'a>(signer: &TokenSigner, raw_hdr: Option<&'a [u8]>) -> AuthState<'a> {
    let Some(hdr) = raw_hdr else {
        return AuthState::Anonymous;
    };
    let Some(token) = hdr.strip_prefix(b"Token ") else {
        return AuthState::Rejected;
    };
    match signer.verify(token) {
        Some(uid) => AuthState::Verified(uid, token),
        None => AuthState::Rejected,
    }
}

#[inline]
fn enqueue_read(op: ReadOp, viewer: i64, addr: ReplyAddr) -> Dispatch {
    engine::READ_QUEUE.push(ReadTask { op, viewer, addr });
    Dispatch::Enqueued
}

#[inline]
fn enqueue_write(op: WriteOp, viewer: i64, addr: ReplyAddr) -> Dispatch {
    engine::WRITE_QUEUE.push(WriteTask { op, viewer, addr });
    Dispatch::Enqueued
}

const BCRYPT_MAX_BYTES: usize = 72;

pub fn route_request(signer: &TokenSigner, req: &HttpReq, addr: ReplyAddr) -> Dispatch {
    let Some(subpath) = req.path.strip_prefix(b"/api/") else {
        return fail_now(404, "not found");
    };
    let mut parts = [&b""[..]; 5];
    let mut nparts = 0usize;
    for seg in subpath.split(|&b| b == b'/') {
        if nparts >= 5 {
            return fail_now(404, "not found");
        }
        parts[nparts] = seg;
        nparts += 1;
    }

    let decode_seg = |seg: &[u8]| -> Option<String> {
        if seg.is_empty() {
            None
        } else {
            percent_decode(seg, false)
        }
    };

    match (req.method, &parts[..nparts]) {
        (b"GET", [b"tags"]) => enqueue_read(ReadOp::Tags, 0, addr),
        (b"GET", [b"articles"]) => match verify_auth_header(signer, req.auth) {
            AuthState::Verified(v, _) => route_article_list(req.query, v, addr),
            AuthState::Anonymous => route_article_list(req.query, 0, addr),
            AuthState::Rejected => fail_now(401, "unauthorized"),
        },
        (b"GET", [b"articles", b"feed"]) => match verify_auth_header(signer, req.auth) {
            AuthState::Verified(v, _) => {
                let q = scan_list_query(req.query);
                match validate_page_bounds(&q) {
                    Some((lim, off)) => enqueue_read(ReadOp::Feed { lim, off }, v, addr),
                    None => fail_now(422, "invalid pagination parameters"),
                }
            }
            _ => fail_now(401, "unauthorized"),
        },
        (b"GET", [b"articles", raw_slug]) if !raw_slug.is_empty() => {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => enqueue_read(ReadOp::ArticleBySlug { slug }, v, addr),
                AuthState::Anonymous => enqueue_read(ReadOp::ArticleBySlug { slug }, 0, addr),
                AuthState::Rejected => fail_now(401, "unauthorized"),
            }
        }
        (b"GET", [b"articles", raw_slug, b"comments"]) if !raw_slug.is_empty() => {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => enqueue_read(ReadOp::Comments { slug }, v, addr),
                AuthState::Anonymous => enqueue_read(ReadOp::Comments { slug }, 0, addr),
                AuthState::Rejected => fail_now(401, "unauthorized"),
            }
        }
        (b"GET", [b"profiles", raw_user]) if !raw_user.is_empty() => {
            let Some(username) = decode_seg(raw_user) else {
                return fail_now(404, "not found");
            };
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => enqueue_read(ReadOp::Profile { username }, v, addr),
                AuthState::Anonymous => enqueue_read(ReadOp::Profile { username }, 0, addr),
                AuthState::Rejected => fail_now(401, "unauthorized"),
            }
        }
        (b"GET", [b"user"]) => match verify_auth_header(signer, req.auth) {
            AuthState::Verified(uid, tok) => enqueue_read(
                ReadOp::CurrentUser {
                    id: uid,
                    token: String::from_utf8_lossy(tok).into_owned(),
                },
                uid,
                addr,
            ),
            _ => fail_now(401, "unauthorized"),
        },
        (b"POST" | b"DELETE", [b"articles", raw_slug, b"favorite"]) if !raw_slug.is_empty() => {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            let fav_on = req.method == b"POST";
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => enqueue_write(WriteOp::Favorite { slug, on: fav_on }, v, addr),
                _ => fail_now(401, "unauthorized"),
            }
        }
        (b"POST", [b"articles", raw_slug, b"comments"]) if !raw_slug.is_empty() => {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => {
                    let obj = match parse_valid_envelope(req.body, "comment") {
                        Ok(o) => o,
                        Err(resp) => return resp,
                    };
                    match required_str_field(&obj, "body") {
                        Ok(body) => enqueue_write(WriteOp::CreateComment { slug, body }, v, addr),
                        Err(()) => fail_now(422, "comment body required"),
                    }
                }
                _ => fail_now(401, "unauthorized"),
            }
        }
        (b"POST" | b"DELETE", [b"profiles", raw_user, b"follow"]) if !raw_user.is_empty() => {
            let Some(username) = decode_seg(raw_user) else {
                return fail_now(404, "not found");
            };
            let follow_on = req.method == b"POST";
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => enqueue_write(WriteOp::Follow { username, on: follow_on }, v, addr),
                _ => fail_now(401, "unauthorized"),
            }
        }
        (b"POST", [b"articles"]) => match verify_auth_header(signer, req.auth) {
            AuthState::Verified(v, _) => handle_create_article(req.body, v, addr),
            _ => fail_now(401, "unauthorized"),
        },
        (b"PUT", [b"articles", raw_slug]) if !raw_slug.is_empty() => {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => handle_update_article(req.body, slug, v, addr),
                _ => fail_now(401, "unauthorized"),
            }
        }
        (b"DELETE", [b"articles", raw_slug]) if !raw_slug.is_empty() => {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => enqueue_write(WriteOp::DeleteArticle { slug }, v, addr),
                _ => fail_now(401, "unauthorized"),
            }
        }
        (b"DELETE", [b"articles", raw_slug, b"comments", raw_id])
            if !raw_slug.is_empty() && !raw_id.is_empty() =>
        {
            let Some(slug) = decode_seg(raw_slug) else {
                return fail_now(404, "not found");
            };
            let id_str = decode_seg(raw_id);
            match verify_auth_header(signer, req.auth) {
                AuthState::Verified(v, _) => match id_str.as_deref().and_then(parse_pos_int_str) {
                    Some(cid) => enqueue_write(WriteOp::DeleteComment { slug, id: cid }, v, addr),
                    None => fail_now(404, "comment not found"),
                },
                _ => fail_now(401, "unauthorized"),
            }
        }
        (b"POST", [b"users", b"login"]) => handle_login(req.body, addr),
        (b"POST", [b"users"]) => handle_register(req.body, addr),
        (b"PUT", [b"user"]) => match verify_auth_header(signer, req.auth) {
            AuthState::Verified(uid, tok) => {
                handle_update_user(req.body, uid, String::from_utf8_lossy(tok).into_owned(), addr)
            }
            _ => fail_now(401, "unauthorized"),
        },
        _ => fail_now(404, "not found"),
    }
}

fn route_article_list(raw_query: &[u8], viewer: i64, addr: ReplyAddr) -> Dispatch {
    let q = scan_list_query(raw_query);
    let Some((lim, off)) = validate_page_bounds(&q) else {
        return fail_now(422, "invalid pagination parameters");
    };
    if q.impossible_filter {
        return Dispatch::Immediate(200, b"{\"articles\":[],\"articlesCount\":0}".to_vec());
    }
    let non_empty = |opt: Option<String>| opt.filter(|s| !s.is_empty());
    let op = if let Some(tag) = non_empty(q.tag) {
        ReadOp::ByTag { tag, lim, off }
    } else if let Some(username) = non_empty(q.author) {
        ReadOp::ByAuthor { username, lim, off }
    } else if let Some(username) = non_empty(q.favorited) {
        ReadOp::ByFavorited { username, lim, off }
    } else {
        ReadOp::Global { lim, off }
    };
    enqueue_read(op, viewer, addr)
}

fn handle_register(body: &[u8], addr: ReplyAddr) -> Dispatch {
    let obj = match parse_valid_envelope(body, "user") {
        Ok(o) => o,
        Err(resp) => return resp,
    };
    let (Ok(username), Ok(email), Ok(password)) = (
        required_str_field(&obj, "username"),
        required_str_field(&obj, "email"),
        required_str_field(&obj, "password"),
    ) else {
        return fail_now(422, "username, email, and password are required");
    };
    if password.len() > BCRYPT_MAX_BYTES {
        return fail_now(422, "password exceeds maximum length");
    }
    let task = WriteTask {
        op: WriteOp::Register {
            username,
            email,
            hash: String::new(),
        },
        viewer: 0,
        addr,
    };
    engine::CRYPTO_QUEUE.push(CryptoTask::HashPassword {
        password: password.into_bytes(),
        write: task,
    });
    Dispatch::Enqueued
}

fn handle_login(body: &[u8], addr: ReplyAddr) -> Dispatch {
    let Some(obj) = unwrap_json_envelope(body, "user") else {
        return fail_now(422, "invalid login payload");
    };
    let (Ok(email), Ok(password)) = (required_str_field(&obj, "email"), required_str_field(&obj, "password")) else {
        return fail_now(422, "email and password are required");
    };
    if email.contains('\0') || password.len() > BCRYPT_MAX_BYTES {
        return fail_now(401, "invalid credentials");
    }
    engine::READ_QUEUE.push_front(ReadTask {
        op: ReadOp::Login {
            email,
            password: password.into_bytes(),
        },
        viewer: 0,
        addr,
    });
    Dispatch::Enqueued
}

fn handle_update_user(body: &[u8], uid: i64, token: String, addr: ReplyAddr) -> Dispatch {
    let obj = match parse_valid_envelope(body, "user") {
        Ok(o) => o,
        Err(resp) => return resp,
    };
    let (Ok(email), Ok(username), Ok(password), Ok(bio), Ok(image)) = (
        optional_str_field(&obj, "email", true),
        optional_str_field(&obj, "username", true),
        optional_str_field(&obj, "password", true),
        optional_str_field(&obj, "bio", false),
        optional_str_field(&obj, "image", false),
    ) else {
        return fail_now(422, "invalid user fields");
    };
    let op = WriteOp::UpdateUser {
        token,
        email,
        username,
        hash: None,
        bio,
        image,
    };
    match password {
        Some(pw) if pw.len() > BCRYPT_MAX_BYTES => fail_now(422, "password exceeds maximum length"),
        Some(pw) => {
            engine::CRYPTO_QUEUE.push(CryptoTask::HashPassword {
                password: pw.into_bytes(),
                write: WriteTask {
                    op,
                    viewer: uid,
                    addr,
                },
            });
            Dispatch::Enqueued
        }
        None => enqueue_write(op, uid, addr),
    }
}

fn handle_create_article(body: &[u8], viewer: i64, addr: ReplyAddr) -> Dispatch {
    let obj = match parse_valid_envelope(body, "article") {
        Ok(o) => o,
        Err(resp) => return resp,
    };
    let (Ok(title), Ok(description), Ok(art_body)) = (
        required_str_field(&obj, "title"),
        required_str_field(&obj, "description"),
        required_str_field(&obj, "body"),
    ) else {
        return fail_now(422, "title, description, and body are required");
    };
    let mut tags = Vec::new();
    match obj.get("tagList") {
        None | Some(JsonVal::Null) => {}
        Some(JsonVal::Array(arr)) => {
            for item in arr {
                match item {
                    JsonVal::Str(s) if !s.is_empty() => tags.push(s.clone()),
                    _ => return fail_now(422, "tagList must contain non-empty strings"),
                }
            }
            tags.sort_unstable();
            tags.dedup();
        }
        Some(_) => return fail_now(422, "tagList must be an array"),
    }
    enqueue_write(
        WriteOp::CreateArticle {
            title,
            description,
            body: art_body,
            tags,
        },
        viewer,
        addr,
    )
}

fn handle_update_article(body: &[u8], slug: String, viewer: i64, addr: ReplyAddr) -> Dispatch {
    let obj = match parse_valid_envelope(body, "article") {
        Ok(o) => o,
        Err(resp) => return resp,
    };
    let (Ok(title), Ok(description), Ok(art_body)) = (
        optional_str_field(&obj, "title", true),
        optional_str_field(&obj, "description", true),
        optional_str_field(&obj, "body", true),
    ) else {
        return fail_now(422, "article fields must be non-empty strings");
    };
    enqueue_write(
        WriteOp::UpdateArticle {
            slug,
            title,
            description,
            body: art_body,
        },
        viewer,
        addr,
    )
}
