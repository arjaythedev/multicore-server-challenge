using System;
using System.Text;

/// <summary>What a request is for. <see cref="NotFound"/> is a 404 before any endpoint runs.</summary>
enum RouteId : byte
{
    NotFound,
    ListArticles,     // GET    /api/articles
    CreateArticle,    // POST   /api/articles
    Feed,             // GET    /api/articles/feed
    GetArticle,       // GET    /api/articles/{slug}
    UpdateArticle,    // PUT    /api/articles/{slug}
    DeleteArticle,    // DELETE /api/articles/{slug}
    ListComments,     // GET    /api/articles/{slug}/comments
    CreateComment,    // POST   /api/articles/{slug}/comments
    DeleteComment,    // DELETE /api/articles/{slug}/comments/{id}
    Favorite,         // POST   /api/articles/{slug}/favorite
    Unfavorite,       // DELETE /api/articles/{slug}/favorite
    Tags,             // GET    /api/tags
    CurrentUser,      // GET    /api/user
    UpdateUser,       // PUT    /api/user
    GetProfile,       // GET    /api/profiles/{username}
    Follow,           // POST   /api/profiles/{username}/follow
    Unfollow,         // DELETE /api/profiles/{username}/follow
    Register,         // POST   /api/users
    Login,            // POST   /api/users/login
}

/// <summary>A matched route and where its slug or username (<see cref="Arg"/>) and comment id (<see cref="Id"/>)
/// lie in the path.</summary>
readonly struct Route
{
    public readonly RouteId Kind;
    public readonly Range Arg, Id;

    Route(RouteId kind, Range arg = default, Range id = default)
    {
        Kind = kind;
        Arg = arg;
        Id = id;
    }

    static readonly Route NotFound = default;

    /// <summary>
    /// Routes <paramref name="method"/> and <paramref name="path"/> (decoded, as Kestrel's Request.Path, without
    /// the query) the way Router.Dispatch does: under "/api/", at most four non-empty segments, segments compared
    /// case-sensitively, methods ASCII case-insensitively (HttpMethods.IsGet and the rest ignore case).
    /// </summary>
    public static Route Match(ReadOnlySpan<byte> method, ReadOnlySpan<byte> path)
    {
        if (!path.StartsWith("/api/"u8)) return NotFound;
        ReadOnlySpan<byte> rest = path[5..];
        Span<Range> seg = stackalloc Range[4];
        int n = 0, start = 0;
        while (true)
        {
            int slash = rest[start..].IndexOf((byte)'/');
            int end = slash < 0 ? rest.Length : start + slash;
            if (end == start) return NotFound; // an empty segment
            if (n == seg.Length) return NotFound; // deeper than any route
            seg[n++] = new Range(start, end);
            if (slash < 0) break;
            start = end + 1;
        }

        Verb v = Parse(method);
        ReadOnlySpan<byte> s0 = rest[seg[0]];
        // ranges are into the path, not into rest
        Range a1 = n > 1 ? Shift(seg[1]) : default;

        if (s0.SequenceEqual("articles"u8))
        {
            if (n == 1) return v switch { Verb.Get => new(RouteId.ListArticles), Verb.Post => new(RouteId.CreateArticle), _ => NotFound };
            if (n == 2)
                return v switch
                {
                    Verb.Get => rest[seg[1]].SequenceEqual("feed"u8) ? new(RouteId.Feed) : new(RouteId.GetArticle, a1),
                    Verb.Put => new(RouteId.UpdateArticle, a1),
                    Verb.Delete => new(RouteId.DeleteArticle, a1),
                    _ => NotFound,
                };
            ReadOnlySpan<byte> s2 = rest[seg[2]];
            if (n == 3 && s2.SequenceEqual("comments"u8))
                return v switch { Verb.Get => new(RouteId.ListComments, a1), Verb.Post => new(RouteId.CreateComment, a1), _ => NotFound };
            if (n == 3 && s2.SequenceEqual("favorite"u8))
                return v switch { Verb.Post => new(RouteId.Favorite, a1), Verb.Delete => new(RouteId.Unfavorite, a1), _ => NotFound };
            if (n == 4 && s2.SequenceEqual("comments"u8) && v == Verb.Delete) return new(RouteId.DeleteComment, a1, Shift(seg[3]));
            return NotFound;
        }
        if (n == 1 && s0.SequenceEqual("tags"u8)) return v == Verb.Get ? new(RouteId.Tags) : NotFound;
        if (n == 1 && s0.SequenceEqual("user"u8))
            return v switch { Verb.Get => new(RouteId.CurrentUser), Verb.Put => new(RouteId.UpdateUser), _ => NotFound };
        if (s0.SequenceEqual("profiles"u8))
        {
            if (n == 2) return v == Verb.Get ? new(RouteId.GetProfile, a1) : NotFound;
            if (n == 3 && rest[seg[2]].SequenceEqual("follow"u8))
                return v switch { Verb.Post => new(RouteId.Follow, a1), Verb.Delete => new(RouteId.Unfollow, a1), _ => NotFound };
            return NotFound;
        }
        if (s0.SequenceEqual("users"u8) && v == Verb.Post)
        {
            if (n == 1) return new(RouteId.Register);
            if (n == 2 && rest[seg[1]].SequenceEqual("login"u8)) return new(RouteId.Login);
        }
        return NotFound;
    }

    static Range Shift(Range r) => new(r.Start.Value + 5, r.End.Value + 5);

    enum Verb : byte { Other, Get, Post, Put, Delete }

    static Verb Parse(ReadOnlySpan<byte> m) =>
        Ascii.EqualsIgnoreCase(m, "GET"u8) ? Verb.Get
        : Ascii.EqualsIgnoreCase(m, "POST"u8) ? Verb.Post
        : Ascii.EqualsIgnoreCase(m, "PUT"u8) ? Verb.Put
        : Ascii.EqualsIgnoreCase(m, "DELETE"u8) ? Verb.Delete
        : Verb.Other;
}
