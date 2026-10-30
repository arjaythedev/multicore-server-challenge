//! Conduit API route dispatch and request handlers.

use crate::crypto::jwt::verify_token;
use crate::json_out::*;
use crate::net::http_parser::{HttpMethod, ParsedRequest};

pub fn slugify(title: &str) -> String {
    let mut s = String::with_capacity(title.len());
    let mut prev_dash = true;
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            s.push(c.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash {
            s.push('-');
            prev_dash = true;
        }
    }
    if s.ends_with('-') {
        s.pop();
    }
    s
}

pub fn make_http_response(status: u16, status_text: &str, body: &[u8], keep_alive: bool) -> Vec<u8> {
    let mut resp = Vec::with_capacity(128 + body.len());
    resp.extend_from_slice(b"HTTP/1.1 ");
    let mut code_buf = itoa::Buffer::new();
    resp.extend_from_slice(code_buf.format(status).as_bytes());
    resp.push(b' ');
    resp.extend_from_slice(status_text.as_bytes());
    resp.extend_from_slice(b"\r\nContent-Type: application/json\r\nContent-Length: ");
    let mut len_buf = itoa::Buffer::new();
    resp.extend_from_slice(len_buf.format(body.len()).as_bytes());
    if keep_alive {
        resp.extend_from_slice(b"\r\nConnection: keep-alive\r\n\r\n");
    } else {
        resp.extend_from_slice(b"\r\nConnection: close\r\n\r\n");
    }
    resp.extend_from_slice(body);
    resp
}

pub fn make_204_response(keep_alive: bool) -> Vec<u8> {
    let mut resp = Vec::with_capacity(64);
    resp.extend_from_slice(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n");
    if keep_alive {
        resp.extend_from_slice(b"Connection: keep-alive\r\n\r\n");
    } else {
        resp.extend_from_slice(b"Connection: close\r\n\r\n");
    }
    resp
}

pub fn make_error_response(status: u16, status_text: &str, msg: &str, keep_alive: bool) -> Vec<u8> {
    let body = format_error_json(msg);
    make_http_response(status, status_text, &body, keep_alive)
}

pub struct QueryParams<'a> {
    pub limit: usize,
    pub offset: usize,
    pub tag: Option<&'a str>,
    pub author: Option<&'a str>,
    pub favorited: Option<&'a str>,
}

pub fn parse_query_params<'a>(query: Option<&'a str>) -> Result<QueryParams<'a>, &'static str> {
    let mut limit = 20;
    let mut offset = 0;
    let mut tag = None;
    let mut author = None;
    let mut favorited = None;

    if let Some(q) = query {
        for pair in q.split('&') {
            if pair.is_empty() {
                continue;
            }
            let (k, v) = match pair.split_once('=') {
                Some((k, v)) => (k, v),
                None => (pair, ""),
            };
            match k {
                "limit" => {
                    let l: usize = v.parse().map_err(|_| "Invalid limit")?;
                    if !(1..=100).contains(&l) {
                        return Err("Limit out of range 1..100");
                    }
                    limit = l;
                }
                "offset" => {
                    let o: usize = v.parse().map_err(|_| "Invalid offset")?;
                    offset = o;
                }
                "tag" => {
                    if tag.is_none() && author.is_none() && favorited.is_none() {
                        tag = Some(v);
                    }
                }
                "author" => {
                    if tag.is_none() && author.is_none() && favorited.is_none() {
                        author = Some(v);
                    }
                }
                "favorited" => {
                    if tag.is_none() && author.is_none() && favorited.is_none() {
                        favorited = Some(v);
                    }
                }
                _ => {}
            }
        }
    }

    Ok(QueryParams {
        limit,
        offset,
        tag,
        author,
        favorited,
    })
}

use crate::app::batcher::{direct_send, BcryptRequest, ReadRequest, WriteRequest};
use std::os::unix::io::RawFd;
use std::sync::mpsc::Sender;

pub fn route_and_dispatch(
    fd: RawFd,
    req: ParsedRequest,
    read_tx: &Sender<ReadRequest>,
    write_tx: &Sender<WriteRequest>,
    bcrypt_tx: &Sender<BcryptRequest>,
    jwt_secret: &[u8],
    now_secs: u64,
) {
    let path = req.path;
    let method = req.method;
    let keep_alive = req.keep_alive;

    // Helper: extract viewer for auth-optional
    let get_optional_viewer = || -> Result<u64, ()> {
        match req.token {
            Some(t) => verify_token(t, jwt_secret, now_secs).map_err(|_| ()),
            None => Ok(0),
        }
    };

    // Helper: extract viewer for auth-required
    let get_required_viewer = || -> Result<(u64, &str), ()> {
        let t = req.token.ok_or(())?;
        let uid = verify_token(t, jwt_secret, now_secs).map_err(|_| ())?;
        Ok((uid, t))
    };

    // 1. GET /api/tags
    if path == "/api/tags" && method == HttpMethod::Get {
        read_tx.send(ReadRequest::GetTags { fd, keep_alive }).ok();
        return;
    }

    // 2. POST /api/users
    if path == "/api/users" && method == HttpMethod::Post {
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(req.body) {
            if let Some(user_obj) = v.get("user") {
                let username = user_obj.get("username").and_then(|u| u.as_str()).unwrap_or("");
                let email = user_obj.get("email").and_then(|e| e.as_str()).unwrap_or("");
                let password = user_obj.get("password").and_then(|p| p.as_str()).unwrap_or("");

                if !username.is_empty() && !email.is_empty() && !password.is_empty() {
                    write_tx.send(WriteRequest::RegisterUser {
                        fd,
                        keep_alive,
                        username: username.to_string(),
                        email: email.to_string(),
                        password: password.to_string(),
                    }).ok();
                    return;
                }
            }
        }
        let resp = make_error_response(422, "Unprocessable Entity", "Invalid registration fields", keep_alive);
        direct_send(fd, &resp);
        return;
    }

    // 3. POST /api/users/login
    if path == "/api/users/login" && method == HttpMethod::Post {
        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(req.body) {
            if let Some(user_obj) = v.get("user") {
                let email = user_obj.get("email").and_then(|e| e.as_str()).unwrap_or("");
                let password = user_obj.get("password").and_then(|p| p.as_str()).unwrap_or("");

                if !email.is_empty() && !password.is_empty() {
                    bcrypt_tx.send(BcryptRequest {
                        fd,
                        keep_alive,
                        email: email.to_string(),
                        password: password.to_string(),
                    }).ok();
                    return;
                }
            }
        }
        let resp = make_error_response(422, "Unprocessable Entity", "Invalid login fields", keep_alive);
        direct_send(fd, &resp);
        return;
    }

    // 4. GET /api/user
    if path == "/api/user" && method == HttpMethod::Get {
        let (viewer, presented_token) = match get_required_viewer() {
            Ok(res) => res,
            Err(_) => {
                let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                direct_send(fd, &resp);
                return;
            }
        };
        read_tx.send(ReadRequest::GetUser {
            fd,
            keep_alive,
            viewer,
            presented_token: presented_token.to_string(),
        }).ok();
        return;
    }

    // 5. PUT /api/user
    if path == "/api/user" && method == HttpMethod::Put {
        let (viewer, presented_token) = match get_required_viewer() {
            Ok(res) => res,
            Err(_) => {
                let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                direct_send(fd, &resp);
                return;
            }
        };

        if let Ok(v) = serde_json::from_slice::<serde_json::Value>(req.body) {
            if let Some(user_obj) = v.get("user") {
                let email = user_obj.get("email").and_then(|e| e.as_str()).map(|s| s.to_string());
                let username = user_obj.get("username").and_then(|u| u.as_str()).map(|s| s.to_string());
                let password = user_obj.get("password").and_then(|p| p.as_str()).map(|s| s.to_string());
                let bio = user_obj.get("bio").map(|b| b.as_str().map(|s| s.to_string()));
                let image = user_obj.get("image").map(|i| i.as_str().map(|s| s.to_string()));

                write_tx.send(WriteRequest::UpdateUser {
                    fd,
                    keep_alive,
                    viewer,
                    presented_token: presented_token.to_string(),
                    email,
                    username,
                    password,
                    bio,
                    image,
                }).ok();
                return;
            }
        }
        let resp = make_error_response(422, "Unprocessable Entity", "Invalid user payload", keep_alive);
        direct_send(fd, &resp);
        return;
    }

    // Profiles: /api/profiles/:username[/follow]
    if let Some(rest) = path.strip_prefix("/api/profiles/") {
        let mut parts = rest.split('/');
        let username = parts.next().unwrap_or("");
        let action = parts.next();

        if action.is_none() && method == HttpMethod::Get {
            let viewer = match get_optional_viewer() {
                Ok(v) => v,
                Err(_) => {
                    let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            };
            read_tx.send(ReadRequest::GetProfile {
                fd,
                keep_alive,
                viewer,
                username: username.to_string(),
            }).ok();
            return;
        }

        if action == Some("follow") {
            let (viewer, _) = match get_required_viewer() {
                Ok(res) => res,
                Err(_) => {
                    let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            };
            if method == HttpMethod::Post {
                write_tx.send(WriteRequest::FollowUser {
                    fd,
                    keep_alive,
                    viewer,
                    username: username.to_string(),
                    follow: true,
                }).ok();
                return;
            } else if method == HttpMethod::Delete {
                write_tx.send(WriteRequest::FollowUser {
                    fd,
                    keep_alive,
                    viewer,
                    username: username.to_string(),
                    follow: false,
                }).ok();
                return;
            }
        }
    }

    // Articles: /api/articles/feed
    if path == "/api/articles/feed" && method == HttpMethod::Get {
        let (viewer, _) = match get_required_viewer() {
            Ok(res) => res,
            Err(_) => {
                let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                direct_send(fd, &resp);
                return;
            }
        };
        let q = match parse_query_params(req.query) {
            Ok(q) => q,
            Err(_) => {
                let resp = make_error_response(422, "Unprocessable Entity", "Invalid query parameters", keep_alive);
                direct_send(fd, &resp);
                return;
            }
        };
        read_tx.send(ReadRequest::FeedArticles {
            fd,
            keep_alive,
            viewer,
            limit: q.limit,
            offset: q.offset,
        }).ok();
        return;
    }

    // Articles: /api/articles
    if path == "/api/articles" {
        if method == HttpMethod::Get {
            let viewer = match get_optional_viewer() {
                Ok(v) => v,
                Err(_) => {
                    let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            };
            let q = match parse_query_params(req.query) {
                Ok(q) => q,
                Err(_) => {
                    let resp = make_error_response(422, "Unprocessable Entity", "Invalid query parameters", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            };
            read_tx.send(ReadRequest::ListArticles {
                fd,
                keep_alive,
                viewer,
                limit: q.limit,
                offset: q.offset,
                tag: q.tag.map(|s| s.to_string()),
                author: q.author.map(|s| s.to_string()),
                favorited: q.favorited.map(|s| s.to_string()),
            }).ok();
            return;
        } else if method == HttpMethod::Post {
            let (viewer, _) = match get_required_viewer() {
                Ok(res) => res,
                Err(_) => {
                    let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            };
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(req.body) {
                if let Some(art) = v.get("article") {
                    let title = art.get("title").and_then(|t| t.as_str()).unwrap_or("");
                    let desc = art.get("description").and_then(|d| d.as_str()).unwrap_or("");
                    let body = art.get("body").and_then(|b| b.as_str()).unwrap_or("");
                    let mut tag_list = Vec::new();
                    if let Some(arr) = art.get("tagList").and_then(|t| t.as_array()) {
                        for item in arr {
                            if let Some(s) = item.as_str() {
                                if !s.is_empty() {
                                    tag_list.push(s.to_string());
                                }
                            }
                        }
                    }

                    if !title.is_empty() && !desc.is_empty() && !body.is_empty() {
                        write_tx.send(WriteRequest::CreateArticle {
                            fd,
                            keep_alive,
                            viewer,
                            title: title.to_string(),
                            description: desc.to_string(),
                            body: body.to_string(),
                            tag_list,
                        }).ok();
                        return;
                    }
                }
            }
            let resp = make_error_response(422, "Unprocessable Entity", "Invalid article payload", keep_alive);
            direct_send(fd, &resp);
            return;
        }
    }

    // Article subroutes: /api/articles/:slug...
    if let Some(rest) = path.strip_prefix("/api/articles/") {
        let mut parts = rest.split('/');
        let slug = parts.next().unwrap_or("");
        let action = parts.next();
        let sub_action = parts.next();

        if action.is_none() {
            if method == HttpMethod::Get {
                let viewer = match get_optional_viewer() {
                    Ok(v) => v,
                    Err(_) => {
                        let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                        direct_send(fd, &resp);
                        return;
                    }
                };
                read_tx.send(ReadRequest::GetArticle {
                    fd,
                    keep_alive,
                    viewer,
                    slug: slug.to_string(),
                }).ok();
                return;
            } else if method == HttpMethod::Put {
                let (viewer, _) = match get_required_viewer() {
                    Ok(res) => res,
                    Err(_) => {
                        let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                        direct_send(fd, &resp);
                        return;
                    }
                };
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(req.body) {
                    if let Some(art) = v.get("article") {
                        let title = art.get("title").and_then(|t| t.as_str()).map(|s| s.to_string());
                        let desc = art.get("description").and_then(|d| d.as_str()).map(|s| s.to_string());
                        let body = art.get("body").and_then(|b| b.as_str()).map(|s| s.to_string());

                        write_tx.send(WriteRequest::UpdateArticle {
                            fd,
                            keep_alive,
                            viewer,
                            slug: slug.to_string(),
                            title,
                            description: desc,
                            body,
                        }).ok();
                        return;
                    }
                }
                let resp = make_error_response(422, "Unprocessable Entity", "Invalid update payload", keep_alive);
                direct_send(fd, &resp);
                return;
            } else if method == HttpMethod::Delete {
                let (viewer, _) = match get_required_viewer() {
                    Ok(res) => res,
                    Err(_) => {
                        let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                        direct_send(fd, &resp);
                        return;
                    }
                };
                write_tx.send(WriteRequest::DeleteArticle {
                    fd,
                    keep_alive,
                    viewer,
                    slug: slug.to_string(),
                }).ok();
                return;
            }
        } else if action == Some("favorite") {
            let (viewer, _) = match get_required_viewer() {
                Ok(res) => res,
                Err(_) => {
                    let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            };
            if method == HttpMethod::Post {
                write_tx.send(WriteRequest::FavoriteArticle {
                    fd,
                    keep_alive,
                    viewer,
                    slug: slug.to_string(),
                    favorite: true,
                }).ok();
                return;
            } else if method == HttpMethod::Delete {
                write_tx.send(WriteRequest::FavoriteArticle {
                    fd,
                    keep_alive,
                    viewer,
                    slug: slug.to_string(),
                    favorite: false,
                }).ok();
                return;
            }
        } else if action == Some("comments") {
            if sub_action.is_none() {
                if method == HttpMethod::Get {
                    let viewer = match get_optional_viewer() {
                        Ok(v) => v,
                        Err(_) => {
                            let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                            direct_send(fd, &resp);
                            return;
                        }
                    };
                    read_tx.send(ReadRequest::GetComments {
                        fd,
                        keep_alive,
                        viewer,
                        slug: slug.to_string(),
                    }).ok();
                    return;
                } else if method == HttpMethod::Post {
                    let (viewer, _) = match get_required_viewer() {
                        Ok(res) => res,
                        Err(_) => {
                            let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                            direct_send(fd, &resp);
                            return;
                        }
                    };
                    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(req.body) {
                        if let Some(c) = v.get("comment") {
                            let body = c.get("body").and_then(|b| b.as_str()).unwrap_or("");
                            if !body.is_empty() {
                                write_tx.send(WriteRequest::CreateComment {
                                    fd,
                                    keep_alive,
                                    viewer,
                                    slug: slug.to_string(),
                                    body: body.to_string(),
                                }).ok();
                                return;
                            }
                        }
                    }
                    let resp = make_error_response(422, "Unprocessable Entity", "Invalid comment body", keep_alive);
                    direct_send(fd, &resp);
                    return;
                }
            } else if let Some(cid_str) = sub_action {
                if method == HttpMethod::Delete {
                    let (viewer, _) = match get_required_viewer() {
                        Ok(res) => res,
                        Err(_) => {
                            let resp = make_error_response(401, "Unauthorized", "Unauthorized", keep_alive);
                            direct_send(fd, &resp);
                            return;
                        }
                    };
                    let comment_id: i64 = match cid_str.parse() {
                        Ok(id) => id,
                        Err(_) => {
                            let resp = make_error_response(404, "Not Found", "Comment not found", keep_alive);
                            direct_send(fd, &resp);
                            return;
                        }
                    };
                    write_tx.send(WriteRequest::DeleteComment {
                        fd,
                        keep_alive,
                        viewer,
                        slug: slug.to_string(),
                        comment_id,
                    }).ok();
                    return;
                }
            }
        }
    }

    // Default 404
    let resp = make_error_response(404, "Not Found", "Not Found", keep_alive);
    direct_send(fd, &resp);
}
