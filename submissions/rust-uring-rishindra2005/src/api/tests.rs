//! Comprehensive unit tests and golden comparisons for Conduit API layer.

#[cfg(test)]
mod tests {
    use crate::api::admit::{admit, Admit};
    use crate::api::render::*;
    use crate::api::routes::{parse_route, RequestParams, RouteError};
    use crate::types::{ConnRef, Job, KdfJob, ListFilter, Route};

    const DUMMY_CONN: ConnRef = ConnRef {
        reactor: 0,
        slot: 1,
        gen: 1,
    };

    // ==========================================
    // 1. Timestamp formatting & RFC 3339 tests
    // ==========================================

    #[test]
    fn test_timestamp_epoch_and_truncation() {
        let mut buf = [0u8; 24];

        // 2000-01-01 00:00:00.000Z (PG epoch 0)
        format_pg_timestamp(0, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-01-01T00:00:00.000Z");

        // Exactly 1 second later
        format_pg_timestamp(1_000_000, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-01-01T00:00:01.000Z");

        // Microseconds truncation: 999 us must truncate to .000 ms, NOT round to .001
        format_pg_timestamp(999, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-01-01T00:00:00.000Z");

        format_pg_timestamp(1_999, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-01-01T00:00:00.001Z");

        format_pg_timestamp(999_999, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-01-01T00:00:00.999Z");
    }

    #[test]
    fn test_timestamp_leap_years_and_golden() {
        let mut buf = [0u8; 24];

        // 2000 is a leap year: day 59 is Feb 29
        // 59 days = 59 * 86400 * 1_000_000 us = 5_097_600_000_000 us
        format_pg_timestamp(59 * 86400 * 1_000_000, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-02-29T00:00:00.000Z");

        // Day 60 is Mar 1
        format_pg_timestamp(60 * 86400 * 1_000_000, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2000-03-01T00:00:00.000Z");

        // SPEC golden date: 2025-04-01T12:00:00.000Z
        // Days between 2000-01-01 and 2025-04-01:
        // 25 years: leap years are 2000, 2004, 2008, 2012, 2016, 2020, 2024 (7 leap years)
        // 25 * 365 + 7 = 9125 + 7 = 9132 days until 2025-01-01
        // Jan (31) + Feb (28) + Mar (31) = 90 days. Total = 9222 days.
        // 9222 days * 86400 + 12 * 3600 = 796_780_800 + 43_200 = 796_824_000 seconds.
        let spec_ts_us = 796_824_000 * 1_000_000;
        format_pg_timestamp(spec_ts_us, &mut buf);
        assert_eq!(std::str::from_utf8(&buf).unwrap(), "2025-04-01T12:00:00.000Z");
    }

    // ==========================================
    // 2. JSON escaping tests
    // ==========================================

    #[test]
    fn test_escape_json_str() {
        let mut out = Vec::new();

        // Fast path: clean string
        escape_json_str("simple_ascii_123", &mut out);
        assert_eq!(std::str::from_utf8(&out).unwrap(), "simple_ascii_123");

        // Quotes and backslashes
        out.clear();
        escape_json_str("hello \"world\" \\path", &mut out);
        assert_eq!(std::str::from_utf8(&out).unwrap(), "hello \\\"world\\\" \\\\path");

        // Control characters
        out.clear();
        escape_json_str("line1\nline2\r\ttab", &mut out);
        assert_eq!(std::str::from_utf8(&out).unwrap(), "line1\\nline2\\r\\ttab");

        // Low control character (< 0x20)
        out.clear();
        escape_json_str("\x01\x1f", &mut out);
        assert_eq!(std::str::from_utf8(&out).unwrap(), "\\u0001\\u001f");

        // UTF-8 multibyte characters must pass through untouched
        out.clear();
        escape_json_str("<b>&</b> \"quoted\" ünïcode", &mut out);
        assert_eq!(std::str::from_utf8(&out).unwrap(), "<b>&</b> \\\"quoted\\\" ünïcode");
    }

    // ==========================================
    // 3. Render functions & Golden shape tests
    // ==========================================

    #[test]
    fn test_render_user() {
        let mut out = Vec::new();
        let user = UserRow {
            email: "alice@example.com",
            token: "jwt.token.here",
            username: "alice",
            bio: None,
            image: None,
        };
        render_user(&mut out, &user);
        assert_eq!(
            std::str::from_utf8(&out).unwrap(),
            "{\"user\":{\"email\":\"alice@example.com\",\"token\":\"jwt.token.here\",\"username\":\"alice\",\"bio\":null,\"image\":null}}"
        );

        out.clear();
        let user_with_bio = UserRow {
            email: "bob@example.com",
            token: "jwt.bob.here",
            username: "bob",
            bio: Some("Hello \"world\"\nBio"),
            image: Some("https://example.com/pic.png"),
        };
        render_user(&mut out, &user_with_bio);
        assert_eq!(
            std::str::from_utf8(&out).unwrap(),
            "{\"user\":{\"email\":\"bob@example.com\",\"token\":\"jwt.bob.here\",\"username\":\"bob\",\"bio\":\"Hello \\\"world\\\"\\nBio\",\"image\":\"https://example.com/pic.png\"}}"
        );
    }

    #[test]
    fn test_render_profile() {
        let mut out = Vec::new();
        let prof = ProfileRow {
            username: "alice",
            bio: None,
            image: None,
            following: true,
        };
        render_profile(&mut out, &prof);
        assert_eq!(
            std::str::from_utf8(&out).unwrap(),
            "{\"profile\":{\"username\":\"alice\",\"bio\":null,\"image\":null,\"following\":true}}"
        );
    }

    #[test]
    fn test_render_article_single_and_list() {
        let mut out = Vec::new();
        let art = ArticleRow {
            slug: "test-slug-1",
            title: "Test Title",
            description: "Test Desc",
            body: Some("Test Body Paragraph"),
            tags: &["tag1", "tag2"],
            created_at_us: 0,
            updated_at_us: 1_000_000,
            favorited: false,
            favorites_count: 5,
            author: ProfileRow {
                username: "author1",
                bio: None,
                image: None,
                following: false,
            },
        };

        // Single article (includes body)
        render_article(&mut out, &art);
        let s = std::str::from_utf8(&out).unwrap();
        assert!(s.contains("\"slug\":\"test-slug-1\""));
        assert!(s.contains("\"body\":\"Test Body Paragraph\""));
        assert!(s.contains("\"tagList\":[\"tag1\",\"tag2\"]"));
        assert!(s.contains("\"createdAt\":\"2000-01-01T00:00:00.000Z\""));
        assert!(s.contains("\"updatedAt\":\"2000-01-01T00:00:01.000Z\""));
        assert!(s.contains("\"favoritesCount\":5"));
        assert!(s.contains("\"following\":false"));

        // Article list (OMITS body per SPEC)
        out.clear();
        render_article_list(&mut out, &[art], 100);
        let list_str = std::str::from_utf8(&out).unwrap();
        assert!(list_str.starts_with("{\"articles\":["));
        assert!(!list_str.contains("\"body\":"));
        assert!(list_str.ends_with(",\"articlesCount\":100}"));
    }

    #[test]
    fn test_render_comment_and_list() {
        let mut out = Vec::new();
        let comment = CommentRow {
            id: 42,
            created_at_us: 0,
            updated_at_us: 0,
            body: "Great article!",
            author: ProfileRow {
                username: "reader",
                bio: None,
                image: None,
                following: true,
            },
        };

        render_comment(&mut out, &comment);
        let s = std::str::from_utf8(&out).unwrap();
        assert_eq!(
            s,
            "{\"comment\":{\"id\":42,\"createdAt\":\"2000-01-01T00:00:00.000Z\",\"updatedAt\":\"2000-01-01T00:00:00.000Z\",\"body\":\"Great article!\",\"author\":{\"username\":\"reader\",\"bio\":null,\"image\":null,\"following\":true}}}"
        );

        out.clear();
        render_comments_list(&mut out, &[comment]);
        assert_eq!(
            std::str::from_utf8(&out).unwrap(),
            "{\"comments\":[{\"id\":42,\"createdAt\":\"2000-01-01T00:00:00.000Z\",\"updatedAt\":\"2000-01-01T00:00:00.000Z\",\"body\":\"Great article!\",\"author\":{\"username\":\"reader\",\"bio\":null,\"image\":null,\"following\":true}}]}"
        );
    }

    #[test]
    fn test_render_tags_and_errors() {
        let mut out = Vec::new();
        render_tags(&mut out, &["rust", "zig", "io_uring"]);
        assert_eq!(
            std::str::from_utf8(&out).unwrap(),
            "{\"tags\":[\"rust\",\"zig\",\"io_uring\"]}"
        );

        out.clear();
        render_errors(&mut out, &["first error", "second error"]);
        assert_eq!(
            std::str::from_utf8(&out).unwrap(),
            "{\"errors\":{\"body\":[\"first error\",\"second error\"]}}"
        );
    }

    #[test]
    fn test_frame_response_200_and_204() {
        let body = b"{\"hello\":\"world\"}";
        let framed = frame_response(200, "OK", body, true);
        let s = std::str::from_utf8(&framed).unwrap();
        assert!(s.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(s.contains("Content-Type: application/json\r\n"));
        assert!(s.contains(&format!("Content-Length: {}\r\n", body.len())));
        assert!(s.contains("Connection: keep-alive\r\n\r\n"));
        assert!(s.ends_with("{\"hello\":\"world\"}"));

        // 204 No Content has empty body
        let framed_204 = frame_response(204, "No Content", b"", true);
        assert_eq!(
            std::str::from_utf8(&framed_204).unwrap(),
            "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
        );
    }

    // ==========================================
    // 4. Route parsing and query validation
    // ==========================================

    #[test]
    fn test_parse_route_endpoints() {
        // Users & Auth
        assert_eq!(
            parse_route("POST", "/api/users/login").unwrap().route,
            Route::UsersLogin
        );
        assert_eq!(
            parse_route("POST", "/api/users").unwrap().route,
            Route::UsersRegister
        );
        assert_eq!(
            parse_route("GET", "/api/user").unwrap().route,
            Route::UserGet
        );
        assert_eq!(
            parse_route("PUT", "/api/user").unwrap().route,
            Route::UserPut
        );

        // Profiles
        let p = parse_route("GET", "/api/profiles/johndoe").unwrap();
        assert_eq!(p.route, Route::ProfileGet);
        assert_eq!(p.params.username, Some("johndoe"));

        let p = parse_route("POST", "/api/profiles/johndoe/follow").unwrap();
        assert_eq!(p.route, Route::ProfileFollow);
        assert_eq!(p.params.username, Some("johndoe"));

        let p = parse_route("DELETE", "/api/profiles/johndoe/follow").unwrap();
        assert_eq!(p.route, Route::ProfileUnfollow);
        assert_eq!(p.params.username, Some("johndoe"));

        // Articles
        let p = parse_route("GET", "/api/articles").unwrap();
        assert_eq!(p.route, Route::ArticlesList);
        assert_eq!(p.params.limit, 20);
        assert_eq!(p.params.offset, 0);
        assert_eq!(p.params.filter, ListFilter::Global);

        assert_eq!(
            parse_route("GET", "/api/articles/feed").unwrap().route,
            Route::ArticlesFeed
        );

        let p = parse_route("GET", "/api/articles/my-slug").unwrap();
        assert_eq!(p.route, Route::ArticleGet);
        assert_eq!(p.params.slug, Some("my-slug"));

        assert_eq!(
            parse_route("POST", "/api/articles").unwrap().route,
            Route::ArticleCreate
        );
        assert_eq!(
            parse_route("PUT", "/api/articles/my-slug").unwrap().route,
            Route::ArticleUpdate
        );
        assert_eq!(
            parse_route("DELETE", "/api/articles/my-slug").unwrap().route,
            Route::ArticleDelete
        );

        // Favorites
        assert_eq!(
            parse_route("POST", "/api/articles/my-slug/favorite").unwrap().route,
            Route::Favorite
        );
        assert_eq!(
            parse_route("DELETE", "/api/articles/my-slug/favorite").unwrap().route,
            Route::Unfavorite
        );

        // Comments
        assert_eq!(
            parse_route("GET", "/api/articles/my-slug/comments").unwrap().route,
            Route::CommentsList
        );
        assert_eq!(
            parse_route("POST", "/api/articles/my-slug/comments").unwrap().route,
            Route::CommentCreate
        );
        let p = parse_route("DELETE", "/api/articles/my-slug/comments/999").unwrap();
        assert_eq!(p.route, Route::CommentDelete);
        assert_eq!(p.params.slug, Some("my-slug"));
        assert_eq!(p.params.comment_id, Some(999));

        // Tags
        assert_eq!(
            parse_route("GET", "/api/tags").unwrap().route,
            Route::Tags
        );
    }

    #[test]
    fn test_query_validation_and_precedence() {
        // Conformance 422 limit checks
        for bad in &[
            "/api/articles?limit=0",
            "/api/articles?limit=101",
            "/api/articles?limit=-1",
            "/api/articles?limit=abc",
            "/api/articles?limit=",
            "/api/articles?limit=1.5",
            "/api/articles?limit=%2B5",
            "/api/articles?limit=%205",
        ] {
            assert!(
                matches!(parse_route("GET", bad), Err(RouteError::InvalidQuery(_))),
                "Expected 422 for {}",
                bad
            );
        }

        // Conformance 422 offset checks
        for bad in &[
            "/api/articles?offset=-1",
            "/api/articles?offset=abc",
            "/api/articles?offset=",
            "/api/articles?offset=99999999999999999999",
        ] {
            assert!(
                matches!(parse_route("GET", bad), Err(RouteError::InvalidQuery(_))),
                "Expected 422 for {}",
                bad
            );
        }

        // Valid leading zeros per conformance test
        let p = parse_route("GET", "/api/articles?limit=05&offset=005").unwrap();
        assert_eq!(p.params.limit, 5);
        assert_eq!(p.params.offset, 5);

        // Filter precedence: tag beats author beats favorited
        let p = parse_route("GET", "/api/articles?author=bob&tag=rust&favorited=charlie").unwrap();
        assert_eq!(p.params.filter, ListFilter::Tag("rust".into()));

        // Empty tag ignored -> author wins
        let p = parse_route("GET", "/api/articles?tag=&author=alice").unwrap();
        assert_eq!(p.params.filter, ListFilter::Author("alice".into()));

        // URL decoding
        let p = parse_route("GET", "/api/articles?tag=c%2B%2B").unwrap();
        assert_eq!(p.params.filter, ListFilter::Tag("c++".into()));
    }

    #[test]
    fn test_comment_id_validation() {
        // Non-integer ID gives 404 per SPEC
        assert_eq!(
            parse_route("DELETE", "/api/articles/my-slug/comments/abc"),
            Err(RouteError::InvalidCommentId)
        );
        assert_eq!(
            parse_route("DELETE", "/api/articles/my-slug/comments/0"),
            Err(RouteError::InvalidCommentId)
        );
        assert_eq!(
            parse_route("DELETE", "/api/articles/my-slug/comments/-10"),
            Err(RouteError::InvalidCommentId)
        );
    }

    // ==========================================
    // 5. Admit & Auth rules tests
    // ==========================================

    #[test]
    fn test_auth_enforcement() {
        let default_params = RequestParams::default();

        // No Auth: /api/tags ignores invalid auth token
        let res = admit(Route::Tags, &default_params, b"", None, Some("bad.jwt"), DUMMY_CONN, true);
        assert!(matches!(res, Admit::Pg(_)));

        // Auth Optional: /api/profiles/:u
        let mut prof_params = RequestParams::default();
        prof_params.username = Some("alice");

        // Anonymous allowed
        let res = admit(Route::ProfileGet, &prof_params, b"", None, None, DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => assert_eq!(env.viewer, 0),
            _ => panic!("Expected Pg"),
        }

        // Invalid token returns 401
        let res = admit(Route::ProfileGet, &prof_params, b"", None, Some("bad.jwt"), DUMMY_CONN, true);
        match res {
            Admit::Reply(bytes) => {
                let s = std::str::from_utf8(&bytes).unwrap();
                assert!(s.starts_with("HTTP/1.1 401 Unauthorized"));
            }
            _ => panic!("Expected 401 reply"),
        }

        // Valid token passes viewer
        let res = admit(Route::ProfileGet, &prof_params, b"", Some(42), Some("valid.jwt"), DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => assert_eq!(env.viewer, 42),
            _ => panic!("Expected Pg"),
        }

        // Auth Required: /api/user
        // Missing token -> 401
        let res = admit(Route::UserGet, &default_params, b"", None, None, DUMMY_CONN, true);
        assert!(matches!(res, Admit::Reply(_)));

        // Valid token -> allowed
        let res = admit(Route::UserGet, &default_params, b"", Some(10), Some("tok"), DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => {
                assert_eq!(env.viewer, 10);
                assert_eq!(env.token.unwrap().as_ref(), "tok");
            }
            _ => panic!("Expected Pg"),
        }
    }

    /// SPEC lines 30-35 & R2: Only 'Authorization: Token <jwt>' is valid.
    /// 'Bearer <jwt>' or bare '<jwt>' must give 401 on Auth Required and Auth Optional endpoints.
    /// No Auth endpoints (Tags, Register, Login) ignore invalid authorization.
    #[test]
    fn test_authorization_scheme_enforcement() {
        use crate::api::parse_and_admit;
        let default_params = RequestParams::default();

        // 1. Auth Required: GET /api/user
        // Bearer scheme -> 401
        let res = parse_and_admit("GET", "/api/user", b"", None, Some(""), DUMMY_CONN, true);
        match res {
            Admit::Reply(bytes) => {
                let s = std::str::from_utf8(&bytes).unwrap();
                assert!(s.starts_with("HTTP/1.1 401 Unauthorized"));
            }
            _ => panic!("Expected 401 for empty/sentinel token"),
        }

        let res = parse_and_admit("GET", "/api/user", b"", None, Some("Bearer eyJhbGci..."), DUMMY_CONN, true);
        match res {
            Admit::Reply(bytes) => {
                let s = std::str::from_utf8(&bytes).unwrap();
                assert!(s.starts_with("HTTP/1.1 401 Unauthorized"));
            }
            _ => panic!("Expected 401 for Bearer scheme"),
        }

        // Even if viewer was passed with Bearer token, defense-in-depth rejects it
        let res = admit(Route::UserGet, &default_params, b"", Some(42), Some("Bearer eyJhbGci..."), DUMMY_CONN, true);
        match res {
            Admit::Reply(bytes) => {
                let s = std::str::from_utf8(&bytes).unwrap();
                assert!(s.starts_with("HTTP/1.1 401 Unauthorized"));
            }
            _ => panic!("Expected 401 for Bearer scheme with viewer"),
        }

        // Valid Token scheme with prefix is sanitized
        let res = admit(Route::UserGet, &default_params, b"", Some(42), Some("Token my.valid.jwt"), DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => {
                assert_eq!(env.viewer, 42);
                assert_eq!(env.token.unwrap().as_ref(), "my.valid.jwt");
            }
            _ => panic!("Expected Pg with clean token"),
        }

        // 2. Auth Optional: GET /api/articles
        // No header -> anonymous 200
        let res = parse_and_admit("GET", "/api/articles", b"", None, None, DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => assert_eq!(env.viewer, 0),
            _ => panic!("Expected anonymous Pg"),
        }

        // Bearer scheme / bare token (sentinel "") -> 401 (header present but invalid)
        let res = parse_and_admit("GET", "/api/articles", b"", None, Some(""), DUMMY_CONN, true);
        match res {
            Admit::Reply(bytes) => {
                let s = std::str::from_utf8(&bytes).unwrap();
                assert!(s.starts_with("HTTP/1.1 401 Unauthorized"));
            }
            _ => panic!("Expected 401 for invalid header on auth optional endpoint"),
        }

        let res = parse_and_admit("GET", "/api/articles", b"", None, Some("Bearer token"), DUMMY_CONN, true);
        match res {
            Admit::Reply(bytes) => {
                let s = std::str::from_utf8(&bytes).unwrap();
                assert!(s.starts_with("HTTP/1.1 401 Unauthorized"));
            }
            _ => panic!("Expected 401 for Bearer scheme on auth optional endpoint"),
        }

        // Valid token on auth optional -> passes viewer
        let res = parse_and_admit("GET", "/api/articles", b"", Some(99), Some("valid.jwt"), DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => assert_eq!(env.viewer, 99),
            _ => panic!("Expected Pg with viewer 99"),
        }

        // 3. No Auth: GET /api/tags
        // Invalid or bearer token is completely ignored
        let res = parse_and_admit("GET", "/api/tags", b"", None, Some(""), DUMMY_CONN, true);
        assert!(matches!(res, Admit::Pg(_)));

        let res = parse_and_admit("GET", "/api/tags", b"", None, Some("Bearer whatever"), DUMMY_CONN, true);
        assert!(matches!(res, Admit::Pg(_)));
    }

    // ==========================================
    // 6. Body parsing & validation tests
    // ==========================================

    #[test]
    fn test_admit_register_validation() {
        let params = RequestParams::default();

        // Valid register creates KdfJob::Hash
        let body = b"{\"user\":{\"username\":\"u1\",\"email\":\"u1@test.com\",\"password\":\"secret\"}}";
        let res = admit(Route::UsersRegister, &params, body, None, None, DUMMY_CONN, true);
        match res {
            Admit::Kdf(KdfJob::Hash { password, then }) => {
                assert_eq!(password.as_ref(), "secret");
                match then.job {
                    Job::Register { username, email, .. } => {
                        assert_eq!(username.as_ref(), "u1");
                        assert_eq!(email.as_ref(), "u1@test.com");
                    }
                    _ => panic!("Expected Job::Register"),
                }
            }
            _ => panic!("Expected KdfJob::Hash"),
        }

        // Password over 72 bytes gives 422
        let long_pw = "p".repeat(73);
        let body = format!("{{\"user\":{{\"username\":\"u1\",\"email\":\"e\",\"password\":\"{}\"}}}}", long_pw);
        let res = admit(Route::UsersRegister, &params, body.as_bytes(), None, None, DUMMY_CONN, true);
        match res {
            Admit::Reply(b) => assert!(std::str::from_utf8(&b).unwrap().starts_with("HTTP/1.1 422")),
            _ => panic!("Expected 422"),
        }

        // Missing wrapper gives 422
        let body = b"{\"username\":\"u1\",\"email\":\"e\",\"password\":\"p\"}";
        let res = admit(Route::UsersRegister, &params, body, None, None, DUMMY_CONN, true);
        assert!(matches!(res, Admit::Reply(_)));

        // Malformed JSON gives 422
        let body = b"{\"user\":{\"username\":";
        let res = admit(Route::UsersRegister, &params, body, None, None, DUMMY_CONN, true);
        assert!(matches!(res, Admit::Reply(_)));
    }

    #[test]
    fn test_admit_article_create_validation() {
        let params = RequestParams::default();

        // Valid article with tags
        let body = b"{\"article\":{\"title\":\"T\",\"description\":\"D\",\"body\":\"B\",\"tagList\":[\"rust\",\"web\"]}}";
        let res = admit(Route::ArticleCreate, &params, body, Some(1), Some("tok"), DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => match env.job {
                Job::ArticleCreate { title, description, body, tags } => {
                    assert_eq!(title.as_ref(), "T");
                    assert_eq!(description.as_ref(), "D");
                    assert_eq!(body.as_ref(), "B");
                    assert_eq!(tags.len(), 2);
                    assert_eq!(tags[0].as_ref(), "rust");
                }
                _ => panic!("Expected Job::ArticleCreate"),
            },
            _ => panic!("Expected Pg"),
        }

        // tagList item empty string gives 422 per conformance
        let body = b"{\"article\":{\"title\":\"T\",\"description\":\"D\",\"body\":\"B\",\"tagList\":[\"ok\", \"\"]}}";
        let res = admit(Route::ArticleCreate, &params, body, Some(1), Some("tok"), DUMMY_CONN, true);
        assert!(matches!(res, Admit::Reply(_)));
    }

    #[test]
    fn test_admit_comment_create_validation() {
        let mut params = RequestParams::default();
        params.slug = Some("my-slug");

        let body = b"{\"comment\":{\"body\":\"Conformance comment <b>&</b> \\\"quoted\\\" \\u00fcunicode\"}}";
        let res = admit(Route::CommentCreate, &params, body, Some(1), Some("tok"), DUMMY_CONN, true);
        match res {
            Admit::Pg(env) => match env.job {
                Job::CommentCreate { slug, body } => {
                    assert_eq!(slug.as_ref(), "my-slug");
                    assert!(body.contains("\"quoted\""));
                }
                _ => panic!("Expected Job::CommentCreate"),
            },
            _ => panic!("Expected Pg"),
        }

        // Empty body gives 422
        let body = b"{\"comment\":{\"body\":\"\"}}";
        let res = admit(Route::CommentCreate, &params, body, Some(1), Some("tok"), DUMMY_CONN, true);
        assert!(matches!(res, Admit::Reply(_)));
    }

    // ==========================================
    // 7. Golden comparisons vs Conformance
    // ==========================================

    #[test]
    fn test_golden_conformance_article_and_comment() {
        // Golden article from step "article.get.seeded"
        // createdAt: "2024-09-08T07:11:41.147Z"
        // Let's compute PG timestamp for 2024-09-08T07:11:41.147Z:
        // Exact PG timestamp for 2024-09-08T07:11:41.147Z (779094701.147s after 2000-01-01)
        let created_us: i64 = 779_094_701_147_000;

        let art = ArticleRow {
            slug: "headru-tut-thaistex-rer-dai-jaikun-wostailiot-wan-5000",
            title: "Headru Tut Thaistex Rer Dai Jaikun Wostailiot Wan",
            description: "Fufoul ciowemet thox nim steanilon bos drai caicat clan geple vute jozal nox steaboutem.",
            body: Some("Gren ciroun clasior toux bicla rouweathar."),
            tags: &["nain", "nean", "nothiodreal", "titear"],
            created_at_us: created_us,
            updated_at_us: created_us,
            favorited: false,
            favorites_count: 27,
            author: ProfileRow {
                username: "bruxrazaston37996",
                bio: Some("Kionaim diozaithen wor joukio"),
                image: None,
                following: false,
            },
        };

        let mut out = Vec::new();
        render_article(&mut out, &art);
        let s = std::str::from_utf8(&out).unwrap();

        // Exact match of key fields
        assert!(s.contains("\"slug\":\"headru-tut-thaistex-rer-dai-jaikun-wostailiot-wan-5000\""));
        assert!(s.contains("\"createdAt\":\"2024-09-08T07:11:41.147Z\""));
        assert!(s.contains("\"updatedAt\":\"2024-09-08T07:11:41.147Z\""));
        assert!(s.contains("\"tagList\":[\"nain\",\"nean\",\"nothiodreal\",\"titear\"]"));
        assert!(s.contains("\"favoritesCount\":27"));
        assert!(s.contains("\"following\":false"));
        assert!(s.contains("\"image\":null"));

        // Golden comment from step "comments.create"
        let comment = CommentRow {
            id: 12345,
            created_at_us: created_us,
            updated_at_us: created_us,
            body: "Conformance comment <b>&</b> \"quoted\" ünïcode",
            author: ProfileRow {
                username: "conformance_user2",
                bio: Some("Conformance bio 2"),
                image: Some("https://example.com/c.png"),
                following: false,
            },
        };

        out.clear();
        render_comment(&mut out, &comment);
        let c_s = std::str::from_utf8(&out).unwrap();
        assert!(c_s.contains("\"id\":12345"));
        assert!(c_s.contains("\"body\":\"Conformance comment <b>&</b> \\\"quoted\\\" ünïcode\""));
        assert!(c_s.contains("\"username\":\"conformance_user2\""));
        assert!(c_s.contains("\"bio\":\"Conformance bio 2\""));
        assert!(c_s.contains("\"image\":\"https://example.com/c.png\""));
        assert!(c_s.contains("\"following\":false"));
    }

    // ==========================================
    // 8. Performance Microbenchmarks
    // ==========================================

    #[test]
    fn bench_api_performance() {
        use std::time::Instant;

        // 1. Timestamp formatting benchmark
        let mut ts_buf = [0u8; 24];
        let n_ts = 2_000_000;
        let start = Instant::now();
        for i in 0..n_ts {
            format_pg_timestamp(i * 1_000_000, &mut ts_buf);
            std::hint::black_box(&ts_buf);
        }
        let elapsed_ts = start.elapsed();
        let ns_per_ts = elapsed_ts.as_nanos() as f64 / n_ts as f64;
        println!("[BENCH] format_pg_timestamp: {:.2} ns/op ({:.2} M op/s)", ns_per_ts, 1_000.0 / ns_per_ts);

        // 2. Escape JSON string benchmark
        let test_str = "Clean ASCII string without any escapes for typical article slugs or usernames 1234567890";
        let mut out = Vec::with_capacity(256);
        let n_esc = 2_000_000;
        let start = Instant::now();
        for _ in 0..n_esc {
            out.clear();
            escape_json_str(test_str, &mut out);
            std::hint::black_box(&out);
        }
        let elapsed_esc = start.elapsed();
        let ns_per_esc = elapsed_esc.as_nanos() as f64 / n_esc as f64;
        println!("[BENCH] escape_json_str (clean): {:.2} ns/op ({:.2} M op/s)", ns_per_esc, 1_000.0 / ns_per_esc);

        // 3. Route parsing benchmark (mix of static, parameterized, and query)
        let n_routes = 2_000_000;
        let routes_sample = [
            ("GET", "/api/tags"),
            ("GET", "/api/articles?tag=rust&limit=20&offset=40"),
            ("GET", "/api/articles/headru-tut-thaistex-rer-dai-jaikun-wostailiot-wan-5000"),
            ("GET", "/api/profiles/bruxrazaston37996"),
            ("POST", "/api/users/login"),
        ];
        let start = Instant::now();
        for i in 0..n_routes {
            let (m, p) = routes_sample[i % routes_sample.len()];
            let res = parse_route(m, p);
            std::hint::black_box(res).unwrap();
        }
        let elapsed_routes = start.elapsed();
        let ns_per_route = elapsed_routes.as_nanos() as f64 / n_routes as f64;
        println!("[BENCH] parse_route (mixed): {:.2} ns/op ({:.2} M req/s)", ns_per_route, 1_000.0 / ns_per_route);

        // 4. Request admission benchmark
        let login_body = b"{\"user\":{\"email\":\"test@example.com\",\"password\":\"password123\"}}";
        let login_params = RequestParams::default();
        let n_admit = 1_000_000;
        let start = Instant::now();
        for _ in 0..n_admit {
            let res = admit(Route::UsersLogin, &login_params, login_body, None, None, DUMMY_CONN, true);
            std::hint::black_box(res);
        }
        let elapsed_admit = start.elapsed();
        let ns_per_admit = elapsed_admit.as_nanos() as f64 / n_admit as f64;
        println!("[BENCH] admit UsersLogin: {:.2} ns/op ({:.2} M req/s)", ns_per_admit, 1_000.0 / ns_per_admit);

        // 5. Article JSON render benchmark
        let art = ArticleRow {
            slug: "headru-tut-thaistex-rer-dai-jaikun-wostailiot-wan-5000",
            title: "Headru Tut Thaistex Rer Dai Jaikun Wostailiot Wan",
            description: "Fufoul ciowemet thox nim steanilon bos drai caicat clan geple vute jozal nox steaboutem.",
            body: Some("Gren ciroun clasior toux bicla rouweathar. Peaplouco wijidrea rihus jusugio saipiot zeadrouhio kaden dijais thobacal co dim."),
            tags: &["nain", "nean", "nothiodreal", "titear"],
            created_at_us: 779_094_701_147_000,
            updated_at_us: 779_094_701_147_000,
            favorited: false,
            favorites_count: 27,
            author: ProfileRow {
                username: "bruxrazaston37996",
                bio: Some("Kionaim diozaithen wor joukio ta druzaman gruheax"),
                image: None,
                following: false,
            },
        };
        let mut render_buf = Vec::with_capacity(1024);
        let n_render = 1_000_000;
        let start = Instant::now();
        for _ in 0..n_render {
            render_buf.clear();
            render_article(&mut render_buf, &art);
            std::hint::black_box(&render_buf);
        }
        let elapsed_render = start.elapsed();
        let ns_per_render = elapsed_render.as_nanos() as f64 / n_render as f64;
        let bytes_per_sec = (render_buf.len() as f64 * n_render as f64) / elapsed_render.as_secs_f64() / (1024.0 * 1024.0);
        println!("[BENCH] render_article: {:.2} ns/op ({:.2} M req/s, {:.1} MB/s)", ns_per_render, 1_000.0 / ns_per_render, bytes_per_sec);

        // 6. Article List JSON render benchmark (page of 20 articles)
        let articles_batch = vec![art; 20];
        let mut list_buf = Vec::with_capacity(8192);
        let n_list = 100_000;
        let start = Instant::now();
        for _ in 0..n_list {
            list_buf.clear();
            render_article_list(&mut list_buf, &articles_batch, 1000);
            std::hint::black_box(&list_buf);
        }
        let elapsed_list = start.elapsed();
        let ns_per_list = elapsed_list.as_nanos() as f64 / n_list as f64;
        let list_mb_s = (list_buf.len() as f64 * n_list as f64) / elapsed_list.as_secs_f64() / (1024.0 * 1024.0);
        println!("[BENCH] render_article_list (N=20): {:.2} ns/op ({:.2} K pages/s, {:.1} MB/s)", ns_per_list, 1_000_000.0 / ns_per_list, list_mb_s);
    }
}
