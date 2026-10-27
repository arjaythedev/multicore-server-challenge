using System.Text;
using Conduit.Auth;
using Conduit.Dispatch;
using Conduit.Http;

namespace Conduit.Api;

/// <summary>
/// Routes each request, applies the auth rules and body checks of SPEC.md, and queues read jobs and write jobs on their
/// dispatchers. Checks that need no database (token, body shape, empty fields) are answered here with 401 or 422; the
/// rest (404, 403, unique clashes) come from the statements.
/// </summary>
public sealed class ApiHandler : IRequestHandler {
    /// <summary>The result of checking an Authorization header.</summary>
    private enum TokenCheck {
        /// <summary>No Authorization header was sent.</summary>
        Missing,
        /// <summary>A valid, unexpired token.</summary>
        Ok,
        /// <summary>A header that is malformed, badly signed or expired.</summary>
        Invalid,
    }

    /// <summary>Queue for read jobs.</summary>
    private readonly IReadQueue _reads;
    /// <summary>The read families that routes pick from.</summary>
    private readonly ReadFamilies _families;
    /// <summary>The token key: the UTF-8 bytes of the JWT secret.</summary>
    private readonly byte[] _key;
    /// <summary>Clock in Unix seconds, for token expiry and for new tokens.</summary>
    private readonly Func<long> _nowUnix;
    /// <summary>Queue for write jobs; null when there are no write routes.</summary>
    private readonly IWriteQueue? _writes;
    /// <summary>Password hasher; null when there is none.</summary>
    private readonly IPasswords? _passwords;
    /// <summary>Signs a token for a user id at the current clock time. Write jobs that issue a token carry it.</summary>
    private readonly Func<long, byte[]> _sign;

    /// <summary>
    /// Creates the handler. <paramref name="nowUnix"/> is the clock for token expiry; null uses the system clock.
    /// <paramref name="writes"/> takes the write jobs and <paramref name="passwords"/> hashes new passwords. Without
    /// <paramref name="writes"/> every write route answers 404; register and user update also need <paramref name="passwords"/>.
    /// </summary>
    public ApiHandler(Settings settings, IReadQueue reads, ReadFamilies families, Func<long>? nowUnix = null,
        IWriteQueue? writes = null, IPasswords? passwords = null) {
        _reads = reads;
        _writes = writes;
        _passwords = passwords;
        _families = families;
        _key = Encoding.UTF8.GetBytes(settings.JwtSecret);
        _nowUnix = nowUnix ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        _sign = id => Jwt.Sign(id, _nowUnix(), _key);
    }

    /// <inheritdoc />
    public void Handle(Connection conn, in HttpRequest request) => Process(new ConnectionClient(conn), request);

    /// <summary>Handles one request for <paramref name="client"/>. Public so tests can use a fake client.</summary>
    public void Process(IClient client, in HttpRequest request) {
        try {
            RouteMatch match = Router.Match(request.Method, request.Path, request.Query);
            switch (match.Route) {
                case Route.Tags:
                    // SPEC.md gives this route no auth, so the Authorization header is not read at all.
                    _reads.Enqueue(new ReadJob(_families.Tags, client));
                    break;

                case Route.GetUser: {
                        TokenCheck auth = Check(request.Authorization, out long viewer);
                        if (auth != TokenCheck.Ok) {
                            Reply(client, 401, "authentication required");
                            break;
                        }
                        _reads.Enqueue(new ReadJob(_families.User, client) {
                            Viewer = viewer,
                            Token = request.Authorization[6..].ToArray(),
                        });
                        break;
                    }

                case Route.GetProfile: {
                        TokenCheck auth = Check(request.Authorization, out long viewer);
                        if (auth == TokenCheck.Invalid) {
                            Reply(client, 401, "invalid token");
                            break;
                        }
                        _reads.Enqueue(new ReadJob(_families.Profile, client) {
                            Viewer = auth == TokenCheck.Ok ? viewer : 0,
                            Key = Encoding.UTF8.GetString(match.Username),
                        });
                        break;
                    }

                case Route.ListArticles: {
                        TokenCheck auth = Check(request.Authorization, out long viewer);
                        if (auth == TokenCheck.Invalid) {
                            Reply(client, 401, "invalid token");
                            break;
                        }
                        if (match.QueryInvalid) {
                            Reply(client, 422, "invalid limit or offset");
                            break;
                        }

                        (int kind, string? key) = ListFilter(match);
                        if (key is not null && key.Contains('\0')) {
                            // No such tag or user can exist, and a NUL would fail the whole batch in Postgres.
                            ReplyEmptyList(client);
                            break;
                        }
                        _reads.Enqueue(new ReadJob(_families.Plan, client) {
                            Kind = kind,
                            Viewer = auth == TokenCheck.Ok ? viewer : 0,
                            Key = key,
                            Limit = match.Limit,
                            Offset = match.Offset,
                        });
                        break;
                    }

                case Route.Feed: {
                        TokenCheck auth = Check(request.Authorization, out long viewer);
                        if (auth != TokenCheck.Ok) {
                            Reply(client, 401, "authentication required");
                            break;
                        }
                        if (match.QueryInvalid) {
                            Reply(client, 422, "invalid limit or offset");
                            break;
                        }
                        _reads.Enqueue(new ReadJob(_families.Plan, client) {
                            Kind = ReadKinds.Feed,
                            Viewer = viewer,
                            Limit = match.Limit,
                            Offset = match.Offset,
                        });
                        break;
                    }

                case Route.GetArticle:
                case Route.ListComments: {
                        TokenCheck auth = Check(request.Authorization, out long viewer);
                        if (auth == TokenCheck.Invalid) {
                            Reply(client, 401, "invalid token");
                            break;
                        }
                        _reads.Enqueue(new ReadJob(_families.Plan, client) {
                            Kind = match.Route == Route.GetArticle ? ReadKinds.Article : ReadKinds.Comments,
                            Viewer = auth == TokenCheck.Ok ? viewer : 0,
                            Key = Encoding.UTF8.GetString(match.Slug),
                        });
                        break;
                    }

                case Route.Register when _writes is not null && _passwords is not null:
                    Register(client, request);
                    break;

                case Route.Login:
                    Login(client, request);
                    break;

                case Route.UpdateUser when _writes is not null && _passwords is not null:
                    UpdateUser(client, request);
                    break;

                case Route.CreateArticle when _writes is not null:
                    CreateArticle(client, request);
                    break;

                case Route.UpdateArticle when _writes is not null:
                    UpdateArticle(client, request, Encoding.UTF8.GetString(match.Slug));
                    break;

                case Route.DeleteArticle when _writes is not null:
                case Route.Favorite when _writes is not null:
                case Route.Unfavorite when _writes is not null: {
                        if (RequireAuth(client, request, out long viewer)) {
                            WriteOp op = match.Route == Route.DeleteArticle ? WriteOps.DeleteArticle
                                : match.Route == Route.Favorite ? WriteOps.Favorite : WriteOps.Unfavorite;
                            _writes.Enqueue(new WriteJob(op, client) { Viewer = viewer, Slug = Encoding.UTF8.GetString(match.Slug) });
                        }
                        break;
                    }

                case Route.CreateComment when _writes is not null:
                    CreateComment(client, request, Encoding.UTF8.GetString(match.Slug));
                    break;

                case Route.DeleteComment when _writes is not null: {
                        if (RequireAuth(client, request, out long viewer)) {
                            _writes.Enqueue(new WriteJob(WriteOps.DeleteComment, client) {
                                Viewer = viewer,
                                Slug = Encoding.UTF8.GetString(match.Slug),
                                CommentId = match.CommentId,
                            });
                        }
                        break;
                    }

                case Route.Follow when _writes is not null:
                case Route.Unfollow when _writes is not null: {
                        if (RequireAuth(client, request, out long viewer)) {
                            _writes.Enqueue(new WriteJob(match.Route == Route.Follow ? WriteOps.Follow : WriteOps.Unfollow, client) {
                                Viewer = viewer,
                                Username = Encoding.UTF8.GetString(match.Username),
                            });
                        }
                        break;
                    }

                default:
                    Reply(client, 404, "not found");
                    break;
            }
        } catch (Exception) {
            Reply(client, 500, "internal error");
        }
    }

    /// <summary>POST /api/users: validates the body, hashes the password on a bcrypt thread, then queues the insert.</summary>
    private void Register(IClient client, in HttpRequest request) {
        JsonField[] f = new JsonField[3];
        if (!JsonBody.TryRead(request.Body, "user", ["username", "email", "password"], f)
            || !f[0].IsFilledText || !f[1].IsFilledText || !IsPassword(f[2])) {
            Reply(client, 422, "username, email and password are required");
            return;
        }
        string username = f[0].Text!, email = f[1].Text!;
        HashThen(client, f[2].Text!, hash => _writes!.Enqueue(new WriteJob(WriteOps.Register, client) {
            Username = username,
            Email = email,
            PasswordHash = hash,
            Signer = _sign,
        }));
    }

    /// <summary>POST /api/users/login: queues a read of the user row. <see cref="LoginFamily"/> checks the password.</summary>
    private void Login(IClient client, in HttpRequest request) {
        JsonField[] f = new JsonField[2];
        if (!JsonBody.TryRead(request.Body, "user", ["email", "password"], f) || !f[0].IsFilledText || !f[1].IsFilledText) {
            Reply(client, 422, "email and password are required");
            return;
        }
        _reads.Enqueue(new ReadJob(_families.Login, client) {
            Key = f[0].Text,
            State = new LoginState(Encoding.UTF8.GetBytes(f[1].Text!)),
        });
    }

    /// <summary>PUT /api/user: absent or null fields stay unchanged. A new password is hashed before the job is queued.</summary>
    private void UpdateUser(IClient client, in HttpRequest request) {
        if (!RequireAuth(client, request, out long viewer)) {
            return;
        }

        JsonField[] f = new JsonField[5];
        if (!JsonBody.TryRead(request.Body, "user", ["email", "username", "password", "bio", "image"], f)
            || !IsOptionalFilled(f[0]) || !IsOptionalFilled(f[1])
            || (f[2].Kind is not (JsonKind.Absent or JsonKind.Null) && !IsPassword(f[2]))
            || !IsOptionalText(f[3]) || !IsOptionalText(f[4])) {
            Reply(client, 422, "invalid user fields");
            return;
        }
        WriteJob job = new(WriteOps.UpdateUser, client) {
            Viewer = viewer,
            Email = f[0].Text,
            Username = f[1].Text,
            Bio = f[3].Text,
            Image = f[4].Text,
            Token = request.Authorization[6..].ToArray(),
        };
        if (f[2].Kind == JsonKind.Text) {
            HashThen(client, f[2].Text!, hash => {
                job.PasswordHash = hash;
                _writes!.Enqueue(job);
            });
        } else {
            _writes!.Enqueue(job);
        }
    }

    /// <summary>POST /api/articles: needs a token, title, description and body. Tags are sorted and made distinct.</summary>
    private void CreateArticle(IClient client, in HttpRequest request) {
        if (!RequireAuth(client, request, out long viewer)) {
            return;
        }

        JsonField[] f = new JsonField[4];
        if (!JsonBody.TryRead(request.Body, "article", ["title", "description", "body", "tagList"], f)
            || !f[0].IsFilledText || !f[1].IsFilledText || !f[2].IsFilledText
            || f[3].Kind is JsonKind.Text or JsonKind.Other) {
            Reply(client, 422, "title, description and body are required");
            return;
        }
        _writes!.Enqueue(new WriteJob(WriteOps.CreateArticle, client) {
            Viewer = viewer,
            Title = f[0].Text,
            Description = f[1].Text,
            Body = f[2].Text,
            Tags = f[3].Items is { Length: > 0 } items ? SortedDistinct(items) : [],
        });
    }

    /// <summary>PUT /api/articles/:slug: needs a token. Absent or null fields stay unchanged.</summary>
    private void UpdateArticle(IClient client, in HttpRequest request, string slug) {
        if (!RequireAuth(client, request, out long viewer)) {
            return;
        }

        JsonField[] f = new JsonField[3];
        if (!JsonBody.TryRead(request.Body, "article", ["title", "description", "body"], f)
            || !IsOptionalFilled(f[0]) || !IsOptionalFilled(f[1]) || !IsOptionalFilled(f[2])) {
            Reply(client, 422, "invalid article fields");
            return;
        }
        _writes!.Enqueue(new WriteJob(WriteOps.UpdateArticle, client) {
            Viewer = viewer,
            Slug = slug,
            Title = f[0].Text,
            Description = f[1].Text,
            Body = f[2].Text,
        });
    }

    /// <summary>POST /api/articles/:slug/comments: a bad body is 422 even when the article does not exist.</summary>
    private void CreateComment(IClient client, in HttpRequest request, string slug) {
        if (!RequireAuth(client, request, out long viewer)) {
            return;
        }

        JsonField[] f = new JsonField[1];
        if (!JsonBody.TryRead(request.Body, "comment", ["body"], f) || !f[0].IsFilledText) {
            Reply(client, 422, "body is required");
            return;
        }
        _writes!.Enqueue(new WriteJob(WriteOps.CreateComment, client) { Viewer = viewer, Slug = slug, Body = f[0].Text });
    }

    /// <summary>
    /// Hashes <paramref name="password"/> on a bcrypt thread, then runs <paramref name="next"/> with the hash on that thread.
    /// A failed hash, or a failure in <paramref name="next"/>, answers 500 and stores nothing.
    /// </summary>
    private void HashThen(IClient client, string password, Action<string> next) {
        _passwords!.Hash(Encoding.UTF8.GetBytes(password), hash => {
            try {
                if (hash.StartsWith('*')) {
                    // crypt_blowfish's failure marker; storing it would lock the account out.
                    Reply(client, 500, "internal error");
                    return;
                }

                next(hash);
            } catch (Exception) {
                Reply(client, 500, "internal error");
            }
        });
    }

    /// <summary>
    /// The request kind and filter value of an article list. Only the first filter present applies: tag, then author,
    /// then favorited. No filter is the global list, with no key.
    /// </summary>
    private static (int Kind, string? Key) ListFilter(in RouteMatch match) {
        if (!match.Tag.IsEmpty) {
            return (ReadKinds.ListTag, Encoding.UTF8.GetString(match.Tag));
        }
        if (!match.Author.IsEmpty) {
            return (ReadKinds.ListAuthor, Encoding.UTF8.GetString(match.Author));
        }
        if (!match.Favorited.IsEmpty) {
            return (ReadKinds.ListFav, Encoding.UTF8.GetString(match.Favorited));
        }

        return (ReadKinds.List, null);
    }

    /// <summary>Returns true with the user id when the request carries a valid token. Otherwise answers 401 and returns false.</summary>
    private bool RequireAuth(IClient client, in HttpRequest request, out long viewer) {
        if (Check(request.Authorization, out viewer) == TokenCheck.Ok) {
            return true;
        }

        Reply(client, 401, "authentication required");
        return false;
    }

    /// <summary>
    /// True for a non-empty password of at most 72 UTF-8 bytes. bcrypt reads at most 72 bytes of key, so a longer
    /// password would be cut without a word; the conformance suite expects it refused. Login does not check this: it
    /// verifies whatever it is given, as bcrypt itself does.
    /// </summary>
    private static bool IsPassword(JsonField f) => f.IsFilledText && Encoding.UTF8.GetByteCount(f.Text!) <= 72;

    /// <summary>True when the field is absent, null, or a non-empty string.</summary>
    private static bool IsOptionalFilled(JsonField f) => f.Kind is JsonKind.Absent or JsonKind.Null || f.IsFilledText;

    /// <summary>True when the field is absent, null, or any string. An empty bio is a value.</summary>
    private static bool IsOptionalText(JsonField f) => f.Kind is JsonKind.Absent or JsonKind.Null or JsonKind.Text;

    /// <summary>Returns a copy of <paramref name="items"/> in ordinal order with duplicates removed.</summary>
    private static string[] SortedDistinct(string[] items) {
        string[] copy = [.. items];
        Array.Sort(copy, StringComparer.Ordinal);
        return [.. copy.Distinct()];
    }

    /// <summary>Checks an Authorization header of the form "Token &lt;jwt&gt;". Ok sets <paramref name="userId"/>.</summary>
    private TokenCheck Check(ReadOnlySpan<byte> header, out long userId) {
        userId = 0;
        if (header.IsEmpty) {
            return TokenCheck.Missing;
        }

        if (!header.StartsWith("Token "u8)) {
            return TokenCheck.Invalid;
        }

        return Jwt.Verify(header[6..], _key, _nowUnix(), out userId) == JwtStatus.Ok ? TokenCheck.Ok : TokenCheck.Invalid;
    }

    /// <summary>Sends 200 with no articles and an articlesCount of 0.</summary>
    private static void ReplyEmptyList(IClient client) {
        ResponseWriter w = ResponseWriter.Rent();
        try {
            w.Body.StartObject();
            w.Body.PropertyName("articles"u8);
            w.Body.StartArray();
            w.Body.EndArray();
            w.Body.PropertyName("articlesCount"u8);
            w.Body.WriteLong(0);
            w.Body.EndObject();
            client.Send(w.Finish(200));
        } finally {
            ResponseWriter.Return(w);
        }
    }

    /// <summary>Sends an error body with <paramref name="message"/> and <paramref name="status"/>.</summary>
    private static void Reply(IClient client, int status, string message) {
        ResponseWriter w = ResponseWriter.Rent();
        try {
            w.WriteError(message);
            client.Send(w.Finish(status));
        } finally {
            ResponseWriter.Return(w);
        }
    }
}
