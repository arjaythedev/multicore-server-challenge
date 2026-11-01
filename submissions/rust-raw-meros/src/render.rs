//! The JSON objects of the API (SPEC.md "Objects"), rendered straight from borrowed values into a [`JsonWriter`].
//! Shared by the read lanes and the write lanes so both produce byte-identical objects.

use crate::json::JsonWriter;

/// `Profile` of the SPEC.
pub struct Profile<'a> {
    pub username: &'a str,
    pub bio: Option<&'a str>,
    pub image: Option<&'a str>,
    pub following: bool,
}

/// `User` of the SPEC; `token` is the JWT as text.
pub struct User<'a> {
    pub email: &'a str,
    pub token: &'a str,
    pub username: &'a str,
    pub bio: Option<&'a str>,
    pub image: Option<&'a str>,
}

/// `Article` of the SPEC. `body` is `None` in list responses, which omit the field.
pub struct Article<'a, Tags> {
    pub slug: &'a str,
    pub title: &'a str,
    pub description: &'a str,
    pub body: Option<&'a str>,
    /// Tag names in the order they must appear (sorted by name).
    pub tags: Tags,
    pub created_micros: i64,
    pub updated_micros: i64,
    pub favorited: bool,
    pub favorites_count: i64,
    pub author: Profile<'a>,
}

/// `Comment` of the SPEC.
pub struct Comment<'a> {
    pub id: i64,
    pub created_micros: i64,
    pub updated_micros: i64,
    pub body: &'a str,
    pub author: Profile<'a>,
}

fn optional_string(w: &mut JsonWriter<'_>, value: Option<&str>) {
    match value {
        Some(text) => w.string(text),
        None => w.null(),
    }
}

/// Writes the fields of a profile as the current object (no braces), so the same code serves `{"profile": ...}` and
/// the `author` of articles and comments.
pub fn profile_object(w: &mut JsonWriter<'_>, p: &Profile<'_>) {
    w.begin_object();
    w.key("username");
    w.string(p.username);
    w.key("bio");
    optional_string(w, p.bio);
    w.key("image");
    optional_string(w, p.image);
    w.key("following");
    w.bool(p.following);
    w.end_object();
}

pub fn user_object(w: &mut JsonWriter<'_>, u: &User<'_>) {
    w.begin_object();
    w.key("email");
    w.string(u.email);
    w.key("token");
    w.string(u.token);
    w.key("username");
    w.string(u.username);
    w.key("bio");
    optional_string(w, u.bio);
    w.key("image");
    optional_string(w, u.image);
    w.end_object();
}

pub fn article_object<'t, Tags>(w: &mut JsonWriter<'_>, a: &Article<'_, Tags>)
where
    Tags: Iterator<Item = &'t str> + Clone,
{
    w.begin_object();
    w.key("slug");
    w.string(a.slug);
    w.key("title");
    w.string(a.title);
    w.key("description");
    w.string(a.description);
    if let Some(body) = a.body {
        w.key("body");
        w.string(body);
    }
    w.key("tagList");
    w.begin_array();
    for tag in a.tags.clone() {
        w.string(tag);
    }
    w.end_array();
    w.key("createdAt");
    w.timestamp_micros(a.created_micros);
    w.key("updatedAt");
    w.timestamp_micros(a.updated_micros);
    w.key("favorited");
    w.bool(a.favorited);
    w.key("favoritesCount");
    w.int(a.favorites_count);
    w.key("author");
    profile_object(w, &a.author);
    w.end_object();
}

pub fn comment_object(w: &mut JsonWriter<'_>, c: &Comment<'_>) {
    w.begin_object();
    w.key("id");
    w.int(c.id);
    w.key("createdAt");
    w.timestamp_micros(c.created_micros);
    w.key("updatedAt");
    w.timestamp_micros(c.updated_micros);
    w.key("body");
    w.string(c.body);
    w.key("author");
    profile_object(w, &c.author);
    w.end_object();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(f: impl FnOnce(&mut JsonWriter<'_>)) -> String {
        let mut out = Vec::new();
        f(&mut JsonWriter::new(&mut out));
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn profile_has_nulls_for_missing_bio_and_image() {
        let p = Profile {
            username: "ann",
            bio: None,
            image: Some("i.png"),
            following: true,
        };
        assert_eq!(
            render(|w| profile_object(w, &p)),
            r#"{"username":"ann","bio":null,"image":"i.png","following":true}"#
        );
    }

    #[test]
    fn article_in_a_list_has_no_body() {
        let author = Profile {
            username: "ann",
            bio: None,
            image: None,
            following: false,
        };
        let tags = ["a", "b"];
        let a = Article {
            slug: "s-1",
            title: "T",
            description: "D",
            body: None,
            tags: tags.iter().copied(),
            created_micros: 0,
            updated_micros: 1_500,
            favorited: false,
            favorites_count: 3,
            author,
        };
        assert_eq!(
            render(|w| article_object(w, &a)),
            r#"{"slug":"s-1","title":"T","description":"D","tagList":["a","b"],"createdAt":"2000-01-01T00:00:00.000Z","updatedAt":"2000-01-01T00:00:00.001Z","favorited":false,"favoritesCount":3,"author":{"username":"ann","bio":null,"image":null,"following":false}}"#
        );
    }
}
