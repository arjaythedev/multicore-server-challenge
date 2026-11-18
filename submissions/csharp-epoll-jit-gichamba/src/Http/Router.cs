namespace Conduit.Http;

/// <summary>The 19 API endpoints of SPEC.md, plus NotFound for anything else.</summary>
public enum Route {
    /// <summary>No endpoint matches the method and path.</summary>
    NotFound,
    /// <summary>POST /api/users.</summary>
    Register,
    /// <summary>POST /api/users/login.</summary>
    Login,
    /// <summary>GET /api/user.</summary>
    GetUser,
    /// <summary>PUT /api/user.</summary>
    UpdateUser,
    /// <summary>GET /api/profiles/{username}.</summary>
    GetProfile,
    /// <summary>POST /api/profiles/{username}/follow.</summary>
    Follow,
    /// <summary>DELETE /api/profiles/{username}/follow.</summary>
    Unfollow,
    /// <summary>GET /api/articles, with optional filters and paging.</summary>
    ListArticles,
    /// <summary>GET /api/articles/feed.</summary>
    Feed,
    /// <summary>GET /api/articles/{slug}.</summary>
    GetArticle,
    /// <summary>POST /api/articles.</summary>
    CreateArticle,
    /// <summary>PUT /api/articles/{slug}.</summary>
    UpdateArticle,
    /// <summary>DELETE /api/articles/{slug}.</summary>
    DeleteArticle,
    /// <summary>POST /api/articles/{slug}/favorite.</summary>
    Favorite,
    /// <summary>DELETE /api/articles/{slug}/favorite.</summary>
    Unfavorite,
    /// <summary>GET /api/articles/{slug}/comments.</summary>
    ListComments,
    /// <summary>POST /api/articles/{slug}/comments.</summary>
    CreateComment,
    /// <summary>DELETE /api/articles/{slug}/comments/{id}.</summary>
    DeleteComment,
    /// <summary>GET /api/tags.</summary>
    Tags,
}

/// <summary>
/// The result of routing one request. The spans point into the request buffer (or, for a value
/// that needed percent-decoding, into a small array), so the handler copies what it keeps.
/// </summary>
public readonly ref struct RouteMatch {
    /// <summary>Creates a match; every part except the route is optional.</summary>
    public RouteMatch(Route route, ReadOnlySpan<byte> slug = default, ReadOnlySpan<byte> username = default,
        long commentId = 0, int limit = 0, long offset = 0, ReadOnlySpan<byte> tag = default,
        ReadOnlySpan<byte> author = default, ReadOnlySpan<byte> favorited = default, bool queryInvalid = false) {
        Route = route;
        Slug = slug;
        Username = username;
        CommentId = commentId;
        Limit = limit;
        Offset = offset;
        Tag = tag;
        Author = author;
        Favorited = favorited;
        QueryInvalid = queryInvalid;
    }

    /// <summary>The matched route.</summary>
    public Route Route { get; }
    /// <summary>The article slug, for routes under /api/articles/{slug}.</summary>
    public ReadOnlySpan<byte> Slug { get; }
    /// <summary>The profile username, for routes under /api/profiles/{username}.</summary>
    public ReadOnlySpan<byte> Username { get; }
    /// <summary>The comment id of DeleteComment.</summary>
    public long CommentId { get; }
    /// <summary>The page size for ListArticles and Feed (default 20, 1 to 100).</summary>
    public int Limit { get; }
    /// <summary>The page offset for ListArticles and Feed (default 0).</summary>
    public long Offset { get; }
    /// <summary>The tag filter of ListArticles; empty when absent or empty.</summary>
    public ReadOnlySpan<byte> Tag { get; }
    /// <summary>The author filter of ListArticles; empty when absent or empty.</summary>
    public ReadOnlySpan<byte> Author { get; }
    /// <summary>The favorited-by filter of ListArticles; empty when absent or empty.</summary>
    public ReadOnlySpan<byte> Favorited { get; }
    /// <summary>True when limit or offset on ListArticles or Feed is not an integer in range; the answer is 422.</summary>
    public bool QueryInvalid { get; }
}

/// <summary>Maps method and path to a <see cref="Route"/> and reads the paging and filter parameters.</summary>
public static class Router {
    /// <summary>
    /// Routes one request. Path parameters are percent-decoded; the query is split on '&amp;',
    /// the first occurrence of a name wins, and '+' in a query value means a space.
    /// A slug or username that decodes to a NUL byte gives NotFound.
    /// </summary>
    public static RouteMatch Match(ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query) {
        RouteMatch match = MatchRoute(method, path, query);
        // A NUL byte cannot be stored in Postgres text and would fail a whole read batch: no such slug or user exists.
        if (match.Slug.IndexOf((byte)0) >= 0 || match.Username.IndexOf((byte)0) >= 0) {
            return NotFound;
        }

        return match;
    }

    /// <summary>Routes by method and by the segments after <c>/api/</c>; the query is read only for the article list and feed.</summary>
    private static RouteMatch MatchRoute(ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query) {
        if (!path.StartsWith("/api/"u8)) {
            return new RouteMatch(Route.NotFound);
        }

        ReadOnlySpan<byte> rest = path[5..];
        bool more = Split(rest, out ReadOnlySpan<byte> seg, out rest);
        bool isGet = method.SequenceEqual("GET"u8);
        bool isPost = method.SequenceEqual("POST"u8);
        bool isPut = method.SequenceEqual("PUT"u8);
        bool isDelete = method.SequenceEqual("DELETE"u8);

        if (seg.SequenceEqual("tags"u8)) {
            return !more && isGet ? new RouteMatch(Route.Tags) : NotFound;
        }

        if (seg.SequenceEqual("user"u8)) {
            if (more) {
                return NotFound;
            }

            if (isGet) {
                return new RouteMatch(Route.GetUser);
            }

            return isPut ? new RouteMatch(Route.UpdateUser) : NotFound;
        }

        if (seg.SequenceEqual("users"u8)) {
            if (!more) {
                return isPost ? new RouteMatch(Route.Register) : NotFound;
            }

            bool more2 = Split(rest, out ReadOnlySpan<byte> s2, out _);
            return !more2 && isPost && s2.SequenceEqual("login"u8) ? new RouteMatch(Route.Login) : NotFound;
        }

        if (seg.SequenceEqual("profiles"u8)) {
            if (!more) {
                return NotFound;
            }

            bool more2 = Split(rest, out ReadOnlySpan<byte> name, out rest);
            if (name.IsEmpty) {
                return NotFound;
            }

            if (!more2) {
                return isGet ? new RouteMatch(Route.GetProfile, username: Decode(name, false)) : NotFound;
            }

            bool more3 = Split(rest, out ReadOnlySpan<byte> s3, out _);
            if (more3 || !s3.SequenceEqual("follow"u8)) {
                return NotFound;
            }

            if (isPost) {
                return new RouteMatch(Route.Follow, username: Decode(name, false));
            }

            return isDelete ? new RouteMatch(Route.Unfollow, username: Decode(name, false)) : NotFound;
        }

        if (seg.SequenceEqual("articles"u8)) {
            return MatchArticles(method, rest, more, query);
        }

        return NotFound;
    }

    /// <summary>The no-match result.</summary>
    private static RouteMatch NotFound => new(Route.NotFound);

    /// <summary>Routes the paths under <c>/api/articles</c>: the list, the feed, one article, its favorite and its comments.</summary>
    private static RouteMatch MatchArticles(ReadOnlySpan<byte> method, ReadOnlySpan<byte> rest, bool more, ReadOnlySpan<byte> query) {
        bool isGet = method.SequenceEqual("GET"u8);
        bool isPost = method.SequenceEqual("POST"u8);
        bool isPut = method.SequenceEqual("PUT"u8);
        bool isDelete = method.SequenceEqual("DELETE"u8);

        if (!more) {
            if (isPost) {
                return new RouteMatch(Route.CreateArticle);
            }

            return isGet ? List(query) : NotFound;
        }

        bool more2 = Split(rest, out ReadOnlySpan<byte> slugRaw, out rest);
        if (slugRaw.IsEmpty) {
            return NotFound;
        }

        if (!more2) {
            if (isGet && slugRaw.SequenceEqual("feed"u8)) {
                RouteMatch m = List(query);
                return new RouteMatch(Route.Feed, limit: m.Limit, offset: m.Offset, queryInvalid: m.QueryInvalid);
            }
            ReadOnlySpan<byte> slug = Decode(slugRaw, false);
            if (isGet) {
                return new RouteMatch(Route.GetArticle, slug: slug);
            }

            if (isPut) {
                return new RouteMatch(Route.UpdateArticle, slug: slug);
            }

            return isDelete ? new RouteMatch(Route.DeleteArticle, slug: slug) : NotFound;
        }

        bool more3 = Split(rest, out ReadOnlySpan<byte> sub, out rest);
        ReadOnlySpan<byte> slugValue = Decode(slugRaw, false);
        if (sub.SequenceEqual("favorite"u8)) {
            if (more3) {
                return NotFound;
            }

            if (isPost) {
                return new RouteMatch(Route.Favorite, slug: slugValue);
            }

            return isDelete ? new RouteMatch(Route.Unfavorite, slug: slugValue) : NotFound;
        }

        if (sub.SequenceEqual("comments"u8)) {
            if (!more3) {
                if (isGet) {
                    return new RouteMatch(Route.ListComments, slug: slugValue);
                }

                return isPost ? new RouteMatch(Route.CreateComment, slug: slugValue) : NotFound;
            }
            bool more4 = Split(rest, out ReadOnlySpan<byte> idText, out _);
            if (more4 || !isDelete || !TryParseId(idText, out long id)) {
                return NotFound;
            }

            return new RouteMatch(Route.DeleteComment, slug: slugValue, commentId: id);
        }

        return NotFound;
    }

    /// <summary>Parses limit, offset and the three filters of a list query.</summary>
    private static RouteMatch List(ReadOnlySpan<byte> query) {
        int limit = 20;
        long offset = 0L;
        bool invalid = false;
        ReadOnlySpan<byte> tag = default, author = default, favorited = default;
        bool sawLimit = false;
        bool sawOffset = false;
        bool sawTag = false;
        bool sawAuthor = false;
        bool sawFavorited = false;

        while (!query.IsEmpty) {
            int amp = query.IndexOf((byte)'&');
            ReadOnlySpan<byte> pair = amp < 0 ? query : query[..amp];
            query = amp < 0 ? default : query[(amp + 1)..];

            int eq = pair.IndexOf((byte)'=');
            ReadOnlySpan<byte> key = eq < 0 ? pair : pair[..eq];
            ReadOnlySpan<byte> value = eq < 0 ? default : pair[(eq + 1)..];

            if (key.SequenceEqual("limit"u8)) {
                if (sawLimit) {
                    continue;
                }

                sawLimit = true;
                if (!TryParseInt(value, out long l) || l < 1 || l > 100) {
                    invalid = true;
                } else {
                    limit = (int)l;
                }
            } else if (key.SequenceEqual("offset"u8)) {
                if (sawOffset) {
                    continue;
                }

                sawOffset = true;
                if (!TryParseInt(value, out offset)) {
                    invalid = true;
                }
            } else if (key.SequenceEqual("tag"u8) && !sawTag) {
                sawTag = true;
                tag = Decode(value, true);
            } else if (key.SequenceEqual("author"u8) && !sawAuthor) {
                sawAuthor = true;
                author = Decode(value, true);
            } else if (key.SequenceEqual("favorited"u8) && !sawFavorited) {
                sawFavorited = true;
                favorited = Decode(value, true);
            }
        }

        return new RouteMatch(Route.ListArticles, limit: limit, offset: offset, tag: tag, author: author, favorited: favorited, queryInvalid: invalid);
    }

    /// <summary>Splits off the first '/'-separated segment. Returns true when another segment follows in <paramref name="tail"/>.</summary>
    private static bool Split(ReadOnlySpan<byte> s, out ReadOnlySpan<byte> head, out ReadOnlySpan<byte> tail) {
        int slash = s.IndexOf((byte)'/');
        if (slash < 0) {
            head = s;
            tail = default;
            return false;
        }
        head = s[..slash];
        tail = s[(slash + 1)..];
        return true;
    }

    /// <summary>Digits only, at most int.MaxValue; leading zeros are fine.</summary>
    private static bool TryParseInt(ReadOnlySpan<byte> s, out long value) {
        value = 0;
        if (s.IsEmpty) {
            return false;
        }

        foreach (byte c in s) {
            if (c < (byte)'0' || c > (byte)'9') {
                return false;
            }

            value = value * 10 + (c - '0');
            if (value > int.MaxValue) {
                return false;
            }
        }
        return true;
    }

    /// <summary>Digits only, 1 to 18 of them, so the value always fits a long.</summary>
    private static bool TryParseId(ReadOnlySpan<byte> s, out long value) {
        value = 0;
        if (s.IsEmpty || s.Length > 18) {
            return false;
        }

        foreach (byte c in s) {
            if (c < (byte)'0' || c > (byte)'9') {
                return false;
            }

            value = value * 10 + (c - '0');
        }
        return true;
    }

    /// <summary>
    /// Returns the value unchanged when it has nothing to decode; otherwise a decoded copy
    /// (a rare, allocating path). A malformed %-escape is kept as written.
    /// </summary>
    private static ReadOnlySpan<byte> Decode(ReadOnlySpan<byte> s, bool plusIsSpace) {
        if (s.IndexOf((byte)'%') < 0 && !(plusIsSpace && s.IndexOf((byte)'+') >= 0)) {
            return s;
        }

        byte[] o = new byte[s.Length];
        int n = 0;
        for (int i = 0; i < s.Length; i++) {
            byte c = s[i];
            if (c == '%' && i + 2 < s.Length && Hex(s[i + 1]) >= 0 && Hex(s[i + 2]) >= 0) {
                o[n++] = (byte)(Hex(s[i + 1]) * 16 + Hex(s[i + 2]));
                i += 2;
            } else if (c == '+' && plusIsSpace) {
                o[n++] = (byte)' ';
            } else {
                o[n++] = c;
            }
        }
        return o.AsSpan(0, n);
    }

    /// <summary>The value of a hex digit, or -1 if <paramref name="c"/> is not one.</summary>
    private static int Hex(byte c) => c switch {
        >= (byte)'0' and <= (byte)'9' => c - '0',
        >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => c - 'A' + 10,
        _ => -1,
    };
}
