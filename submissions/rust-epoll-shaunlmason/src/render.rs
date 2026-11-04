//! JSON bodies built straight into byte buffers.

use crate::json;

pub fn user(b: &mut Vec<u8>, email: &[u8], token: &[u8], username: &[u8], bio: Option<&[u8]>, image: Option<&[u8]>) {
    b.extend_from_slice(b"{\"user\":{\"email\":");
    json::string(b, email);
    b.extend_from_slice(b",\"token\":");
    json::string(b, token);
    b.extend_from_slice(b",\"username\":");
    json::string(b, username);
    b.extend_from_slice(b",\"bio\":");
    json::opt(b, bio);
    b.extend_from_slice(b",\"image\":");
    json::opt(b, image);
    b.extend_from_slice(b"}}");
}

pub fn profile(b: &mut Vec<u8>, username: &[u8], bio: Option<&[u8]>, image: Option<&[u8]>, following: bool) {
    b.extend_from_slice(b"{\"username\":");
    json::string(b, username);
    b.extend_from_slice(b",\"bio\":");
    json::opt(b, bio);
    b.extend_from_slice(b",\"image\":");
    json::opt(b, image);
    b.extend_from_slice(b",\"following\":");
    json::bool(b, following);
    b.push(b'}');
}

pub struct Comment<'a> {
    pub id: i64,
    pub body: &'a [u8],
    pub created: i64,
    pub updated: i64,
    pub username: &'a [u8],
    pub bio: Option<&'a [u8]>,
    pub image: Option<&'a [u8]>,
    pub following: bool,
}

pub fn comment(b: &mut Vec<u8>, c: &Comment) {
    b.extend_from_slice(b"{\"id\":");
    json::int(b, c.id);
    b.extend_from_slice(b",\"createdAt\":");
    json::ts(b, c.created);
    b.extend_from_slice(b",\"updatedAt\":");
    json::ts(b, c.updated);
    b.extend_from_slice(b",\"body\":");
    json::string(b, c.body);
    b.extend_from_slice(b",\"author\":");
    profile(b, c.username, c.bio, c.image, c.following);
    b.push(b'}');
}
