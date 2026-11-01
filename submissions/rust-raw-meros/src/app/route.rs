//! Maps `(method, path)` to a [`Route`]. The path has no query string. Segments are matched byte-wise; captured
//! segments are returned still percent-encoded (the handler decodes what it needs).

use crate::http::Method;

/// An API endpoint of the SPEC, with its captured path segments.
#[derive(Debug, PartialEq, Eq)]
pub enum Route<'a> {
    Register,
    Login,
    CurrentUser,
    UpdateUser,
    Profile {
        username: &'a [u8],
    },
    Follow {
        username: &'a [u8],
        follow: bool,
    },
    ListArticles,
    Feed,
    Article {
        slug: &'a [u8],
    },
    CreateArticle,
    UpdateArticle {
        slug: &'a [u8],
    },
    DeleteArticle {
        slug: &'a [u8],
    },
    Favorite {
        slug: &'a [u8],
        favorite: bool,
    },
    Comments {
        slug: &'a [u8],
    },
    AddComment {
        slug: &'a [u8],
    },
    DeleteComment {
        slug: &'a [u8],
        id: &'a [u8],
    },
    Tags,
    /// No such path, or a method the path does not support.
    NotFound,
}

const API_PREFIX: &[u8] = b"/api/";

/// Splits a path like `/api/articles/x/comments` after the prefix and routes it.
pub fn route<'a>(method: Method, path: &'a [u8]) -> Route<'a> {
    let Some(rest) = path.strip_prefix(API_PREFIX) else {
        return Route::NotFound;
    };
    let mut segments = rest.split(|&b| b == b'/');
    let first = segments.next().unwrap_or(b"");
    let second = segments.next();
    let third = segments.next();
    let fourth = segments.next();
    if segments.next().is_some() {
        return Route::NotFound;
    }
    use Method::{Delete, Get, Post, Put};
    match (first, second, third, fourth, method) {
        (b"users", None, ..) if method == Post => Route::Register,
        (b"users", Some(b"login"), None, _, Post) => Route::Login,
        (b"user", None, ..) => match method {
            Get => Route::CurrentUser,
            Put => Route::UpdateUser,
            _ => Route::NotFound,
        },
        (b"profiles", Some(name), None, _, Get) if !name.is_empty() => {
            Route::Profile { username: name }
        }
        (b"profiles", Some(name), Some(b"follow"), None, Post | Delete) if !name.is_empty() => {
            Route::Follow {
                username: name,
                follow: method == Post,
            }
        }
        (b"articles", None, ..) => match method {
            Get => Route::ListArticles,
            Post => Route::CreateArticle,
            _ => Route::NotFound,
        },
        (b"articles", Some(b"feed"), None, _, Get) => Route::Feed,
        (b"articles", Some(slug), None, _, _) if !slug.is_empty() => match method {
            Get => Route::Article { slug },
            Put => Route::UpdateArticle { slug },
            Delete => Route::DeleteArticle { slug },
            _ => Route::NotFound,
        },
        (b"articles", Some(slug), Some(b"favorite"), None, Post | Delete) if !slug.is_empty() => {
            Route::Favorite {
                slug,
                favorite: method == Post,
            }
        }
        (b"articles", Some(slug), Some(b"comments"), None, _) if !slug.is_empty() => match method {
            Get => Route::Comments { slug },
            Post => Route::AddComment { slug },
            _ => Route::NotFound,
        },
        (b"articles", Some(slug), Some(b"comments"), Some(id), Delete) if !slug.is_empty() => {
            Route::DeleteComment { slug, id }
        }
        (b"tags", None, ..) if method == Get => Route::Tags,
        _ => Route::NotFound,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Method::{Delete, Get, Post, Put};

    #[test]
    fn every_endpoint_of_the_spec_routes() {
        assert_eq!(route(Post, b"/api/users"), Route::Register);
        assert_eq!(route(Post, b"/api/users/login"), Route::Login);
        assert_eq!(route(Get, b"/api/user"), Route::CurrentUser);
        assert_eq!(route(Put, b"/api/user"), Route::UpdateUser);
        assert_eq!(
            route(Get, b"/api/profiles/ann"),
            Route::Profile { username: b"ann" }
        );
        assert_eq!(
            route(Post, b"/api/profiles/ann/follow"),
            Route::Follow {
                username: b"ann",
                follow: true
            }
        );
        assert_eq!(
            route(Delete, b"/api/profiles/ann/follow"),
            Route::Follow {
                username: b"ann",
                follow: false
            }
        );
        assert_eq!(route(Get, b"/api/articles"), Route::ListArticles);
        assert_eq!(route(Get, b"/api/articles/feed"), Route::Feed);
        assert_eq!(route(Post, b"/api/articles"), Route::CreateArticle);
        assert_eq!(
            route(Get, b"/api/articles/a-1"),
            Route::Article { slug: b"a-1" }
        );
        assert_eq!(
            route(Put, b"/api/articles/a-1"),
            Route::UpdateArticle { slug: b"a-1" }
        );
        assert_eq!(
            route(Delete, b"/api/articles/a-1"),
            Route::DeleteArticle { slug: b"a-1" }
        );
        assert_eq!(
            route(Post, b"/api/articles/a-1/favorite"),
            Route::Favorite {
                slug: b"a-1",
                favorite: true
            }
        );
        assert_eq!(
            route(Delete, b"/api/articles/a-1/favorite"),
            Route::Favorite {
                slug: b"a-1",
                favorite: false
            }
        );
        assert_eq!(
            route(Get, b"/api/articles/a-1/comments"),
            Route::Comments { slug: b"a-1" }
        );
        assert_eq!(
            route(Post, b"/api/articles/a-1/comments"),
            Route::AddComment { slug: b"a-1" }
        );
        assert_eq!(
            route(Delete, b"/api/articles/a-1/comments/7"),
            Route::DeleteComment {
                slug: b"a-1",
                id: b"7"
            }
        );
        assert_eq!(route(Get, b"/api/tags"), Route::Tags);
    }

    #[test]
    fn unknown_paths_and_wrong_methods_are_not_found() {
        assert_eq!(route(Get, b"/"), Route::NotFound);
        assert_eq!(route(Get, b"/api"), Route::NotFound);
        assert_eq!(route(Get, b"/api/users"), Route::NotFound);
        assert_eq!(route(Delete, b"/api/user"), Route::NotFound);
        assert_eq!(route(Get, b"/api/articles/a/b/c/d"), Route::NotFound);
        assert_eq!(route(Post, b"/api/tags"), Route::NotFound);
        assert_eq!(route(Get, b"/api/articles//comments"), Route::NotFound);
        assert_eq!(route(Get, b"/api/profiles/"), Route::NotFound);
    }

    #[test]
    fn the_feed_is_not_an_article_slug() {
        assert_eq!(route(Get, b"/api/articles/feed"), Route::Feed);
        assert_eq!(
            route(Get, b"/api/articles/feed2"),
            Route::Article { slug: b"feed2" }
        );
    }
}
