//! Request bodies of the SPEC: parsing and validation. Each function returns [`Field`]s (ranges of the request
//! buffer, see `scratch.rs`) or the 422 message. Nothing here copies a string unless it contains escape sequences.

use std::borrow::Cow;

use super::jobs::Field;
use super::scratch::Scratch;
use super::slug::slugify;
use crate::json::{self, Value};

/// A 422 message for the client.
pub type Invalid = &'static str;

const BAD_JSON: Invalid = "request body is not valid JSON";

fn parse(body: &[u8]) -> Result<Value<'_>, Invalid> {
    json::parse(body).map_err(|_| BAD_JSON)
}

/// The object under `name` (`{"user": {...}}`).
fn wrapper<'v, 'a>(root: &'v Value<'a>, name: &'static str) -> Result<&'v Value<'a>, Invalid> {
    match root.get(name) {
        Some(object @ Value::Object(_)) => Ok(object),
        _ => Err("request body is missing its wrapper object"),
    }
}

/// Postgres text cannot hold NUL: such a value would fail the statement (and every request batched with it).
const HAS_NUL: Invalid = "strings must not contain NUL";

/// A string member that must be present and non-empty.
fn required<'v, 'a>(
    object: &'v Value<'a>,
    key: &str,
    message: Invalid,
) -> Result<&'v Cow<'a, str>, Invalid> {
    match object.get(key) {
        Some(Value::String(text)) if text.contains('\0') => Err(HAS_NUL),
        Some(Value::String(text)) if !text.is_empty() => Ok(text),
        _ => Err(message),
    }
}

/// A string member that may be absent or `null` (both mean "unchanged").
fn optional<'v, 'a>(
    object: &'v Value<'a>,
    key: &str,
    message: Invalid,
) -> Result<Option<&'v Cow<'a, str>>, Invalid> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if text.contains('\0') => Err(HAS_NUL),
        Some(Value::String(text)) => Ok(Some(text)),
        Some(_) => Err(message),
    }
}

/// bcrypt reads at most 72 bytes of a password; the conformance suite wants longer ones rejected when they are set.
const MAX_PASSWORD_BYTES: usize = 72;
const PASSWORD_TOO_LONG: Invalid = "password must be at most 72 bytes";

/// Like [`optional`], but a present value must not be empty (email, username, password, title...).
fn optional_non_empty<'v, 'a>(
    object: &'v Value<'a>,
    key: &str,
    message: Invalid,
) -> Result<Option<&'v Cow<'a, str>>, Invalid> {
    match optional(object, key, message)? {
        Some(text) if text.is_empty() => Err(message),
        found => Ok(found),
    }
}

fn password_within_limit(password: &str) -> Result<(), Invalid> {
    if password.len() > MAX_PASSWORD_BYTES {
        Err(PASSWORD_TOO_LONG)
    } else {
        Ok(())
    }
}

pub struct Register {
    pub username: Field,
    pub email: Field,
    pub password: Field,
}

pub fn register(base: &[u8], body: &[u8], scratch: &mut Scratch) -> Result<Register, Invalid> {
    let root = parse(body)?;
    let user = wrapper(&root, "user")?;
    let password = required(user, "password", "password can't be blank")?;
    password_within_limit(password)?;
    Ok(Register {
        username: scratch.field_str(base, required(user, "username", "username can't be blank")?),
        email: scratch.field_str(base, required(user, "email", "email can't be blank")?),
        password: scratch.field_str(base, password),
    })
}

pub struct Login {
    pub email: Field,
    pub password: Field,
}

pub fn login(base: &[u8], body: &[u8], scratch: &mut Scratch) -> Result<Login, Invalid> {
    let root = parse(body)?;
    let user = wrapper(&root, "user")?;
    Ok(Login {
        email: scratch.field_str(base, required(user, "email", "email can't be blank")?),
        password: scratch.field_str(base, required(user, "password", "password can't be blank")?),
    })
}

pub struct UpdateUser {
    pub email: Option<Field>,
    pub username: Option<Field>,
    pub password: Option<Field>,
    pub bio: Option<Field>,
    pub image: Option<Field>,
}

pub fn update_user(base: &[u8], body: &[u8], scratch: &mut Scratch) -> Result<UpdateUser, Invalid> {
    let root = parse(body)?;
    let user = wrapper(&root, "user")?;
    let email = optional_non_empty(user, "email", "email can't be blank")?;
    let username = optional_non_empty(user, "username", "username can't be blank")?;
    let password = optional_non_empty(user, "password", "password can't be blank")?;
    if let Some(password) = password {
        password_within_limit(password)?;
    }
    // bio and image may be set to the empty string.
    let bio = optional(user, "bio", "bio must be a string")?;
    let image = optional(user, "image", "image must be a string")?;
    let mut field = |text: Option<&Cow<'_, str>>| text.map(|text| scratch.field_str(base, text));
    Ok(UpdateUser {
        email: field(email),
        username: field(username),
        password: field(password),
        bio: field(bio),
        image: field(image),
    })
}

pub struct NewArticle {
    pub slug_base: String,
    pub title: Field,
    pub description: Field,
    pub body: Field,
    pub tags: Vec<Field>,
}

pub fn new_article(base: &[u8], body: &[u8], scratch: &mut Scratch) -> Result<NewArticle, Invalid> {
    let root = parse(body)?;
    let article = wrapper(&root, "article")?;
    let title = required(article, "title", "title can't be blank")?;
    let description = required(article, "description", "description can't be blank")?;
    let text = required(article, "body", "body can't be blank")?;
    let mut tags = Vec::new();
    match article.get("tagList") {
        None | Some(Value::Null) => {}
        Some(Value::Array(items)) => {
            for item in items {
                match item {
                    Value::String(tag) if !tag.is_empty() && !tag.contains('\0') => {
                        tags.push(scratch.field_str(base, tag))
                    }
                    _ => return Err("tagList must contain non-empty strings"),
                }
            }
        }
        Some(_) => return Err("tagList must be an array"),
    }
    Ok(NewArticle {
        slug_base: slugify(title),
        title: scratch.field_str(base, title),
        description: scratch.field_str(base, description),
        body: scratch.field_str(base, text),
        tags,
    })
}

pub struct ArticleEdit {
    /// Present only when the title changes (the slug is rebuilt from it).
    pub slug_base: Option<String>,
    pub title: Option<Field>,
    pub description: Option<Field>,
    pub body: Option<Field>,
}

pub fn article_edit(
    base: &[u8],
    body: &[u8],
    scratch: &mut Scratch,
) -> Result<ArticleEdit, Invalid> {
    let root = parse(body)?;
    let article = wrapper(&root, "article")?;
    let title = optional_non_empty(article, "title", "title can't be blank")?;
    let description = optional_non_empty(article, "description", "description can't be blank")?;
    let text = optional_non_empty(article, "body", "body can't be blank")?;
    Ok(ArticleEdit {
        slug_base: title.map(|t| slugify(t)),
        title: title.map(|t| scratch.field_str(base, t)),
        description: description.map(|t| scratch.field_str(base, t)),
        body: text.map(|t| scratch.field_str(base, t)),
    })
}

pub fn comment(base: &[u8], body: &[u8], scratch: &mut Scratch) -> Result<Field, Invalid> {
    let root = parse(body)?;
    let comment = wrapper(&root, "comment")?;
    Ok(scratch.field_str(base, required(comment, "body", "body can't be blank")?))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Request-shaped buffer: some prefix, then the body.
    fn with_body(body: &str) -> (Vec<u8>, std::ops::Range<usize>) {
        let mut buf = b"POST /x HTTP/1.1\r\n\r\n".to_vec();
        let start = buf.len();
        buf.extend_from_slice(body.as_bytes());
        let end = buf.len();
        (buf, start..end)
    }

    #[test]
    fn register_fields_are_ranges_of_the_buffer() {
        let (buf, body) =
            with_body(r#"{"user":{"username":"ann","email":"a@x.io","password":"pw"}}"#);
        let mut scratch = Scratch::default();
        let r = register(&buf, &buf[body], &mut scratch).unwrap();
        assert_eq!(r.username.text(&buf), "ann");
        assert_eq!(r.email.text(&buf), "a@x.io");
        assert_eq!(r.password.text(&buf), "pw");
    }

    #[test]
    fn blank_and_missing_fields_are_422() {
        for body in [
            r#"{"user":{"username":"","email":"a","password":"p"}}"#,
            r#"{"user":{"email":"a","password":"p"}}"#,
            r#"{"user":{"username":1,"email":"a","password":"p"}}"#,
            r#"{"username":"a"}"#,
            "not json",
        ] {
            let (buf, range) = with_body(body);
            assert!(
                register(&buf, &buf[range], &mut Scratch::default()).is_err(),
                "{body}"
            );
        }
    }

    #[test]
    fn escaped_strings_are_decoded_into_the_scratch_area() {
        let (mut buf, body) = with_body(r#"{"comment":{"body":"line\nbreak"}}"#);
        let mut scratch = Scratch::default();
        let mut field = comment(&buf, &buf[body], &mut scratch).unwrap();
        scratch.commit(&mut buf, [&mut field]);
        assert_eq!(field.text(&buf), "line\nbreak");
    }

    #[test]
    fn article_edit_treats_null_as_unchanged_and_rebuilds_the_slug() {
        let (buf, body) = with_body(r#"{"article":{"title":"New Title!","body":null}}"#);
        let e = article_edit(&buf, &buf[body], &mut Scratch::default()).unwrap();
        assert_eq!(e.slug_base.as_deref(), Some("new-title"));
        assert!(e.body.is_none() && e.description.is_none());
        assert_eq!(e.title.unwrap().text(&buf), "New Title!");
    }

    #[test]
    fn new_article_requires_text_and_valid_tags() {
        let (buf, body) = with_body(
            r#"{"article":{"title":"T","description":"D","body":"B","tagList":["a","b"]}}"#,
        );
        let a = new_article(&buf, &buf[body], &mut Scratch::default()).unwrap();
        assert_eq!(a.tags.len(), 2);
        assert_eq!(a.slug_base, "t");
        for bad in [
            r#"{"article":{"title":"T","description":"D","body":"B","tagList":[""]}}"#,
            r#"{"article":{"title":"T","description":"D","body":"B","tagList":"a"}}"#,
            r#"{"article":{"title":"T","description":"","body":"B"}}"#,
        ] {
            let (buf, range) = with_body(bad);
            assert!(
                new_article(&buf, &buf[range], &mut Scratch::default()).is_err(),
                "{bad}"
            );
        }
    }
}
