use std::env;
use std::fs::File;
use std::io::Write;
use std::path::Path;
use std::process::Command;

fn main() {
    let out_dir = env::var("OUT_DIR").unwrap();
    let out_path = Path::new(&out_dir);

    // 1. Compile C io_uring layer with ThinLTO if present
    compile_c_layer(out_path);

    // 2. Codegen: Route match-tree
    generate_router(out_path);

    // 3. Codegen: Postgres wire messages
    generate_pg_wire_messages(out_path);

    // 4. Codegen: JSON response fragments
    generate_json_fragments(out_path);
}

fn compile_c_layer(out_path: &Path) {
    let c_file = Path::new("src/net/c/uring.c");
    println!("cargo:rerun-if-changed=src/net/c/uring.c");
    println!("cargo:rerun-if-changed=src/net/c/uring.h");

    if !c_file.exists() {
        return;
    }

    let clang_candidates = ["clang-22", "clang-21", "clang"];
    let mut clang_bin = "clang";
    for cand in &clang_candidates {
        if Command::new(cand).arg("--version").output().is_ok() {
            clang_bin = cand;
            break;
        }
    }

    let obj_path = out_path.join("uring.o");
    let lib_path = out_path.join("liburing_c.a");

    let status = Command::new(clang_bin)
        .args([
            "--target=x86_64-unknown-linux-gnu",
            "-flto=thin",
            "-O3",
            "-march=native",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-c",
            "src/net/c/uring.c",
            "-o",
            obj_path.to_str().unwrap(),
        ])
        .status();

    if let Ok(st) = status {
        if st.success() {
            let ar_candidates = ["llvm-ar-22", "llvm-ar-21", "llvm-ar", "ar"];
            let mut ar_bin = "ar";
            for cand in &ar_candidates {
                if Command::new(cand).arg("--version").output().is_ok() {
                    ar_bin = cand;
                    break;
                }
            }

            let ar_status = Command::new(ar_bin)
                .args(["crs", lib_path.to_str().unwrap(), obj_path.to_str().unwrap()])
                .status();

            if let Ok(ast) = ar_status {
                if ast.success() {
                    println!("cargo:rustc-link-search=native={}", out_path.display());
                    println!("cargo:rustc-link-lib=static=uring_c");
                }
            }
        }
    }
}

fn generate_router(out_path: &Path) {
    let dest_path = out_path.join("codegen_router.rs");
    let mut f = File::create(&dest_path).unwrap();

    let code = r#"
use crate::types::Route;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PathParams<'a> {
    pub slug: Option<&'a str>,
    pub username: Option<&'a str>,
    pub comment_id: Option<&'a str>,
}

/// Straight-line match-tree for the 19 Conduit routes.
/// Compiles to branchless / prefix slice comparisons with zero allocations.
#[inline(always)]
pub fn match_route<'a>(method: &str, raw_path: &'a str) -> Option<(Route, PathParams<'a>)> {
    // Strip query string if present
    let path = match raw_path.find('?') {
        Some(q) => &raw_path[..q],
        None => raw_path,
    };

    let rest = path.strip_prefix("/api/")?;

    if rest.starts_with("tags") {
        if rest == "tags" && method == "GET" {
            return Some((Route::Tags, PathParams::default()));
        }
        return None;
    }

    if rest.starts_with("user") {
        if rest == "user" {
            return match method {
                "GET" => Some((Route::UserGet, PathParams::default())),
                "PUT" => Some((Route::UserPut, PathParams::default())),
                _ => None,
            };
        }
        if rest == "users" {
            return match method {
                "POST" => Some((Route::UsersRegister, PathParams::default())),
                _ => None,
            };
        }
        if rest == "users/login" {
            return match method {
                "POST" => Some((Route::UsersLogin, PathParams::default())),
                _ => None,
            };
        }
        return None;
    }

    if let Some(prof) = rest.strip_prefix("profiles/") {
        if let Some(slash_idx) = prof.find('/') {
            let username = &prof[..slash_idx];
            let sub = &prof[slash_idx + 1..];
            if sub == "follow" {
                let params = PathParams { username: Some(username), ..Default::default() };
                return match method {
                    "POST" => Some((Route::ProfileFollow, params)),
                    "DELETE" => Some((Route::ProfileUnfollow, params)),
                    _ => None,
                };
            }
        } else {
            let params = PathParams { username: Some(prof), ..Default::default() };
            return match method {
                "GET" => Some((Route::ProfileGet, params)),
                _ => None,
            };
        }
        return None;
    }

    if let Some(arts) = rest.strip_prefix("articles") {
        if arts.is_empty() {
            return match method {
                "GET" => Some((Route::ArticlesList, PathParams::default())),
                "POST" => Some((Route::ArticleCreate, PathParams::default())),
                _ => None,
            };
        }
        if arts == "/feed" {
            return match method {
                "GET" => Some((Route::ArticlesFeed, PathParams::default())),
                _ => None,
            };
        }
        if let Some(tail) = arts.strip_prefix('/') {
            if let Some(slash_idx) = tail.find('/') {
                let slug = &tail[..slash_idx];
                let action = &tail[slash_idx + 1..];

                if action == "favorite" {
                    let params = PathParams { slug: Some(slug), ..Default::default() };
                    return match method {
                        "POST" => Some((Route::Favorite, params)),
                        "DELETE" => Some((Route::Unfavorite, params)),
                        _ => None,
                    };
                }
                if action == "comments" {
                    let params = PathParams { slug: Some(slug), ..Default::default() };
                    return match method {
                        "GET" => Some((Route::CommentsList, params)),
                        "POST" => Some((Route::CommentCreate, params)),
                        _ => None,
                    };
                }
                if let Some(comment_id) = action.strip_prefix("comments/") {
                    if method == "DELETE" {
                        let params = PathParams {
                            slug: Some(slug),
                            comment_id: Some(comment_id),
                            ..Default::default()
                        };
                        return Some((Route::CommentDelete, params));
                    }
                }
            } else {
                let params = PathParams { slug: Some(tail), ..Default::default() };
                return match method {
                    "GET" => Some((Route::ArticleGet, params)),
                    "PUT" => Some((Route::ArticleUpdate, params)),
                    "DELETE" => Some((Route::ArticleDelete, params)),
                    _ => None,
                };
            }
        }
    }

    None
}
"#;

    f.write_all(code.as_bytes()).unwrap();
}

fn generate_pg_wire_messages(out_path: &Path) {
    let dest_path = out_path.join("codegen_pg_msg.rs");
    let mut f = File::create(&dest_path).unwrap();

    let code = r#"
// Pre-encoded Postgres protocol binary messages
pub const PG_SYNC_MSG: &[u8] = &[b'S', 0, 0, 0, 4];
"#;
    f.write_all(code.as_bytes()).unwrap();
}

fn generate_json_fragments(out_path: &Path) {
    let dest_path = out_path.join("codegen_json.rs");
    let mut f = File::create(&dest_path).unwrap();

    let code = r#"
// Pre-computed constant JSON fragments for Conduit response serialization
pub const JSON_USER_PREFIX: &[u8] = b"{\"user\":{\"email\":\"";
pub const JSON_USER_TOKEN: &[u8] = b"\",\"token\":\"";
pub const JSON_USER_USERNAME: &[u8] = b"\",\"username\":\"";
pub const JSON_USER_BIO: &[u8] = b"\",\"bio\":";
pub const JSON_USER_IMAGE: &[u8] = b",\"image\":";
pub const JSON_USER_SUFFIX: &[u8] = b"}}";

pub const JSON_ARTICLE_PREFIX: &[u8] = b"{\"article\":{\"slug\":\"";
pub const JSON_ARTICLE_TITLE: &[u8] = b"\",\"title\":\"";
pub const JSON_ARTICLE_DESC: &[u8] = b"\",\"description\":\"";
pub const JSON_ARTICLE_BODY: &[u8] = b"\",\"body\":\"";
pub const JSON_ARTICLE_TAGS: &[u8] = b"\",\"tagList\":[";
pub const JSON_ARTICLE_CREATED: &[u8] = b"],\"createdAt\":\"";
pub const JSON_ARTICLE_UPDATED: &[u8] = b"\",\"updatedAt\":\"";
pub const JSON_ARTICLE_FAVORITED: &[u8] = b"\",\"favorited\":";
pub const JSON_ARTICLE_FAV_COUNT: &[u8] = b",\"favoritesCount\":";
pub const JSON_ARTICLE_AUTHOR_USER: &[u8] = b",\"author\":{\"username\":\"";
pub const JSON_ARTICLE_AUTHOR_BIO: &[u8] = b"\",\"bio\":";
pub const JSON_ARTICLE_AUTHOR_IMAGE: &[u8] = b",\"image\":";
pub const JSON_ARTICLE_AUTHOR_FOLLOWING: &[u8] = b",\"following\":";
pub const JSON_ARTICLE_SUFFIX: &[u8] = b"}}}";

pub const JSON_TAGS_PREFIX: &[u8] = b"{\"tags\":[";
pub const JSON_TAGS_SUFFIX: &[u8] = b"]}";
"#;
    f.write_all(code.as_bytes()).unwrap();
}
