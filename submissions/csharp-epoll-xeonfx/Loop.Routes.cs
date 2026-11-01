using System;
using System.Threading;

/// <summary>The routes: each request is checked and answered at once (an error), or queued as a read, a write, or a
/// bcrypt job.</summary>
sealed partial class Loop
{
    // what a read is: its part of a batch is Batch.Parts[kind - 1]
    internal const byte KTags = 1, KCurrentUser = 2, KLogin = 3, KProfile = 4, KArticle = 5, KComments = 6, KGlobal = 7,
        KTag = 8, KAuthor = 9, KFavorited = 10, KFeed = 11;
    // what a write is
    const byte WRegister = 20, WUpdateUser = 21, WFollow = 22, WUnfollow = 23, WCreateArticle = 24, WUpdateArticle = 25,
        WDeleteArticle = 26, WFavorite = 27, WUnfavorite = 28, WCreateComment = 29, WDeleteComment = 30;

    /// <summary>The decoded path and query values.</summary>
    byte[] _decoded = new byte[16 << 10];

    void Dispatch(int fd, in HttpRequest r)
    {
        ReadOnlySpan<byte> path = r.Path;
        if (path.IndexOf((byte)'%') >= 0)
        {
            if (_decoded.Length < path.Length + 3 * r.Query.Length) _decoded = new byte[path.Length + 3 * r.Query.Length];
            path = _decoded.AsSpan(0, DecodePath(path, _decoded));
        }
        Route m = global::Route.Match(r.Method, path);
        if (m.Kind == RouteId.NotFound)
        {
            Error(fd, 404, Errors.NotFound);
            return;
        }
        long viewer = Jwt.Viewer(r.HasAuthorization, r.Authorization);
        // a token that was sent must be valid everywhere; one is required everywhere but these reads and sign-in
        bool optional = m.Kind is RouteId.ListArticles or RouteId.GetArticle or RouteId.ListComments or RouteId.GetProfile
            or RouteId.Tags or RouteId.Register or RouteId.Login;
        if (m.Kind is RouteId.Register or RouteId.Login or RouteId.Tags) viewer = Math.Max(viewer, 0); // the token is never read
        if (viewer < 0 || (viewer == 0 && !optional))
        {
            Error(fd, 401, Errors.Unauthorized);
            return;
        }
        ReadOnlySpan<byte> arg = path[m.Arg];
        switch (m.Kind)
        {
            case RouteId.ListArticles: ListArticles(fd, viewer, r.Query, path.Length); break;
            case RouteId.Feed: Feed(fd, viewer, r.Query); break;
            case RouteId.GetArticle: ReadBySlug(fd, KArticle, viewer, arg); break;
            case RouteId.ListComments: ReadBySlug(fd, KComments, viewer, arg); break;
            case RouteId.GetProfile: ReadBySlug(fd, KProfile, viewer, arg); break;
            case RouteId.Tags: Tags(fd); break;
            case RouteId.CreateArticle: CreateArticle(fd, viewer, r.Body); break;
            case RouteId.UpdateArticle: UpdateArticle(fd, viewer, arg, r.Body); break;
            case RouteId.DeleteArticle: WriteBySlug(fd, WDeleteArticle, Statement.DeleteArticle, viewer, arg, Errors.ArticleNotFound); break;
            case RouteId.Favorite: WriteBySlug(fd, WFavorite, Statement.Favorite, viewer, arg, Errors.ArticleNotFound); break;
            case RouteId.Unfavorite: WriteBySlug(fd, WUnfavorite, Statement.Unfavorite, viewer, arg, Errors.ArticleNotFound); break;
            case RouteId.Follow: WriteBySlug(fd, WFollow, Statement.Follow, viewer, arg, Errors.ProfileNotFound); break;
            case RouteId.Unfollow: WriteBySlug(fd, WUnfollow, Statement.Unfollow, viewer, arg, Errors.ProfileNotFound); break;
            case RouteId.CreateComment: CreateComment(fd, viewer, arg, r.Body); break;
            case RouteId.DeleteComment: DeleteComment(fd, viewer, arg, path[m.Id]); break;
            case RouteId.CurrentUser: CurrentUser(fd, viewer, r.Authorization); break;
            case RouteId.UpdateUser: UpdateUser(fd, viewer, r.Authorization, r.Body); break;
            case RouteId.Register: Register(fd, r.Body); break;
            case RouteId.Login: Login(fd, r.Body); break;
        }
    }

    /// <summary>Postgres refuses text holding a NUL byte, and the error would fail the reads batched after it: such a
    /// value never reaches it.</summary>
    static bool HasNul(ReadOnlySpan<byte> s) => s.IndexOf((byte)0) >= 0;

    // ---- reads

    /// <summary>Queues a read for the next batch, or answers 503 when no reader is up.</summary>
    Job? Read(int fd, byte kind, long viewer)
    {
        if (Volatile.Read(ref _hub.LiveReaders) == 0)
        {
            Error(fd, 503, Errors.DatabaseBusy);
            return null;
        }
        return NewJob(fd, kind, viewer);
    }

    void Enqueue(Job job) => _hub.EnqueueRead(job, this);

    void ListArticles(int fd, long viewer, ReadOnlySpan<byte> query, int pathLength)
    {
        if (!Query.TryPage(query, out long limit, out long offset))
        {
            Error(fd, 422, Errors.BadPage);
            return;
        }
        int max = Query.MaxDecodedLength(query.Length);
        if (_decoded.Length < pathLength + max) Array.Resize(ref _decoded, pathLength + max);
        // after the decoded path, which the route's ranges still point into
        Span<byte> filter = _decoded.AsSpan(pathLength, max);
        // the first non-empty filter in the order tag, author, favorited applies
        int n;
        byte kind = (n = Query.Get(query, "tag"u8, filter)) > 0 ? KTag
            : (n = Query.Get(query, "author"u8, filter)) > 0 ? KAuthor
            : (n = Query.Get(query, "favorited"u8, filter)) > 0 ? KFavorited
            : KGlobal;
        if (kind != KGlobal && HasNul(filter[..n]))
        {
            // no tag, author or user has that name
            int at = HeadRoom;
            Json.Raw(_response, ref at, "{\"articles\":[],\"articlesCount\":0}"u8);
            Respond(fd, 200, at);
            return;
        }
        if (Read(fd, kind, viewer) is not Job job) return;
        if (kind != KGlobal) job.SetName(filter[..n]);
        job.Limit = limit;
        job.Offset = offset;
        Enqueue(job);
    }

    void Feed(int fd, long viewer, ReadOnlySpan<byte> query)
    {
        if (!Query.TryPage(query, out long limit, out long offset))
        {
            Error(fd, 422, Errors.BadPage);
            return;
        }
        if (Read(fd, KFeed, viewer) is not Job job) return;
        job.Limit = limit;
        job.Offset = offset;
        Enqueue(job);
    }

    /// <summary>A read by slug or username.</summary>
    void ReadBySlug(int fd, byte kind, long viewer, ReadOnlySpan<byte> name)
    {
        if (HasNul(name))
        {
            Error(fd, 404, kind == KProfile ? Errors.ProfileNotFound : Errors.ArticleNotFound);
            return;
        }
        if (Read(fd, kind, viewer) is not Job job) return;
        job.SetName(name);
        Enqueue(job);
    }

    void Tags(int fd)
    {
        if (Read(fd, KTags, 0) is Job job) Enqueue(job);
    }

    void CurrentUser(int fd, long viewer, ReadOnlySpan<byte> authorization)
    {
        if (Read(fd, KCurrentUser, viewer) is not Job job) return;
        job.SetKeep(Jwt.Presented(authorization));
        Enqueue(job);
    }

    void Login(int fd, ReadOnlySpan<byte> body)
    {
        byte[] scratch = Scratch(body.Length);
        if (!Body.TryRead(body, BodyShape.Login, scratch, out BodyFields f))
        {
            Error(fd, 422, Errors.InvalidBody);
            return;
        }
        if (!f[0].IsRequired || !f[1].IsRequired)
        {
            Error(fd, 422, Errors.LoginFields);
            return;
        }
        ReadOnlySpan<byte> email = f[0].Value(body, scratch), password = f[1].Value(body, scratch);
        // a password bcrypt can't read in full can't be anyone's; an email with a NUL can't be stored
        if (password.Length > Bcrypt.MaxPasswordBytes || HasNul(email))
        {
            Error(fd, 401, Errors.WrongLogin);
            return;
        }
        if (Read(fd, KLogin, 0) is not Job job) return;
        password.CopyTo(job.Password);
        job.PasswordLength = password.Length;
        job.SetName(email);
        Enqueue(job);
    }

    // ---- writes

    /// <summary>A write by slug or username: $1 the viewer, $2 the name.</summary>
    void WriteBySlug(int fd, byte kind, byte statement, long viewer, ReadOnlySpan<byte> name, ReadOnlySpan<byte> notFound)
    {
        if (HasNul(name))
        {
            Error(fd, 404, notFound);
            return;
        }
        Job job = NewJob(fd, kind, viewer);
        job.Bind.Bind(statement);
        job.Bind.Int8(viewer);
        job.Bind.Text(name);
        job.Bind.Execute();
        job.Statements = 1;
        _hub.EnqueueWrite(job, this);
    }

    void CreateArticle(int fd, long viewer, ReadOnlySpan<byte> body)
    {
        byte[] scratch = Scratch(body.Length);
        if (!Body.TryRead(body, BodyShape.CreateArticle, scratch, out BodyFields f))
        {
            Error(fd, 422, Errors.InvalidBody);
            return;
        }
        if (!f[0].IsRequired || !f[1].IsRequired || !f[2].IsRequired || AnyNul(f, 3, body, scratch))
        {
            Error(fd, 422, Errors.ArticleFields);
            return;
        }
        if (f[3].Kind == FieldKind.Invalid || f[3].Kind == FieldKind.Array && TagsHaveNul(body, f[3], scratch))
        {
            Error(fd, 422, Errors.BadTagList);
            return;
        }
        // insert, tags and read-back commit together in the writer's group
        Job job = NewJob(fd, WCreateArticle, viewer);
        Wire w = job.Bind;
        w.Bind(Statement.InsertArticle);
        w.Int8(viewer);
        w.Text(f[0].Value(body, scratch)); w.Text(f[1].Value(body, scratch)); w.Text(f[2].Value(body, scratch));
        w.Execute();
        job.Statements = 2;
        if (f[3].Kind == FieldKind.Array && f[3].Count > 0)
        {
            TagArray(w, Statement.InsertTags, body, f[3], scratch);
            TagArray(w, Statement.InsertArticleTags, body, f[3], scratch);
            job.Statements = 4;
        }
        w.Bind(Statement.InsertedArticle);
        w.Int8(viewer);
        w.Execute();
        _hub.EnqueueWrite(job, this);
    }

    static void TagArray(Wire w, byte statement, ReadOnlySpan<byte> body, in BodyField tagList, Span<byte> scratch)
    {
        w.Bind(statement);
        w.BeginArray();
        var tags = Body.Tags(body, tagList, scratch);
        while (tags.Next(out ReadOnlySpan<byte> tag)) w.Element(tag);
        w.EndArray();
        w.Execute();
    }

    static bool TagsHaveNul(ReadOnlySpan<byte> body, in BodyField tagList, Span<byte> scratch)
    {
        var tags = Body.Tags(body, tagList, scratch);
        while (tags.Next(out ReadOnlySpan<byte> tag))
            if (HasNul(tag)) return true;
        return false;
    }

    /// <summary>Whether any of the first <paramref name="n"/> text fields holds a NUL byte.</summary>
    static bool AnyNul(in BodyFields f, int n, ReadOnlySpan<byte> body, ReadOnlySpan<byte> scratch)
    {
        for (int i = 0; i < n; i++)
            if (f[i].Kind == FieldKind.Text && HasNul(f[i].Value(body, scratch))) return true;
        return false;
    }

    void UpdateArticle(int fd, long viewer, ReadOnlySpan<byte> slug, ReadOnlySpan<byte> body)
    {
        byte[] scratch = Scratch(body.Length);
        if (!Body.TryRead(body, BodyShape.UpdateArticle, scratch, out BodyFields f))
        {
            Error(fd, 422, Errors.InvalidBody);
            return;
        }
        if (!f[0].IsOptional(true) || !f[1].IsOptional(true) || !f[2].IsOptional(true) || AnyNul(f, 3, body, scratch))
        {
            Error(fd, 422, Errors.ArticleUpdateFields);
            return;
        }
        if (HasNul(slug))
        {
            Error(fd, 404, Errors.ArticleNotFound);
            return;
        }
        Job job = NewJob(fd, WUpdateArticle, viewer);
        Wire w = job.Bind;
        w.Bind(Statement.UpdateArticle);
        w.Int8(viewer);
        w.Text(slug);
        for (int i = 0; i < 3; i++) TextOrNull(w, f[i], body, scratch);
        w.Execute();
        job.Statements = 1;
        _hub.EnqueueWrite(job, this);
    }

    static void TextOrNull(Wire w, in BodyField f, ReadOnlySpan<byte> body, ReadOnlySpan<byte> scratch)
    {
        if (f.IsMissing) w.Null();
        else w.Text(f.Value(body, scratch));
    }

    void CreateComment(int fd, long viewer, ReadOnlySpan<byte> slug, ReadOnlySpan<byte> body)
    {
        byte[] scratch = Scratch(body.Length);
        if (!Body.TryRead(body, BodyShape.CreateComment, scratch, out BodyFields f) || !f[0].IsRequired || AnyNul(f, 1, body, scratch))
        {
            Error(fd, 422, Errors.CommentFields);
            return;
        }
        if (HasNul(slug))
        {
            Error(fd, 404, Errors.ArticleNotFound);
            return;
        }
        Job job = NewJob(fd, WCreateComment, viewer);
        Wire w = job.Bind;
        w.Bind(Statement.CreateComment);
        w.Int8(viewer);
        w.Text(f[0].Value(body, scratch));
        w.Text(slug);
        w.Execute();
        job.Statements = 1;
        _hub.EnqueueWrite(job, this);
    }

    void DeleteComment(int fd, long viewer, ReadOnlySpan<byte> slug, ReadOnlySpan<byte> id)
    {
        if (!Query.TryParseUint(id, out long commentId) || HasNul(slug))
        {
            Error(fd, 404, Errors.CommentNotFound);
            return;
        }
        Job job = NewJob(fd, WDeleteComment, viewer);
        Wire w = job.Bind;
        w.Bind(Statement.DeleteComment);
        w.Int8(viewer);
        w.Int8(commentId);
        w.Text(slug);
        w.Execute();
        job.Statements = 1;
        _hub.EnqueueWrite(job, this);
    }

    void Register(int fd, ReadOnlySpan<byte> body)
    {
        byte[] scratch = Scratch(body.Length);
        if (!Body.TryRead(body, BodyShape.Register, scratch, out BodyFields f))
        {
            Error(fd, 422, Errors.InvalidBody);
            return;
        }
        if (!f[0].IsRequired || !f[1].IsRequired || !f[2].IsRequired || AnyNul(f, 2, body, scratch))
        {
            Error(fd, 422, Errors.RegisterFields);
            return;
        }
        ReadOnlySpan<byte> password = f[2].Value(body, scratch);
        if (password.Length > Bcrypt.MaxPasswordBytes)
        {
            Error(fd, 422, Errors.PasswordTooLong);
            return;
        }
        // the insert is encoded now, with room for the hash the bcrypt thread writes into it
        Job job = NewJob(fd, WRegister, 0);
        Wire w = job.Bind;
        w.Bind(Statement.Register);
        w.Text(f[0].Value(body, scratch));
        w.Text(f[1].Value(body, scratch));
        job.HashAt = w.Placeholder(Bcrypt.HashLength);
        w.Execute();
        job.Statements = 1;
        Hash(job, password);
    }

    void UpdateUser(int fd, long viewer, ReadOnlySpan<byte> authorization, ReadOnlySpan<byte> body)
    {
        byte[] scratch = Scratch(body.Length);
        if (!Body.TryRead(body, BodyShape.UpdateUser, scratch, out BodyFields f))
        {
            Error(fd, 422, Errors.InvalidBody);
            return;
        }
        // email, username and password must be non-empty when sent; bio and image may be ""
        if (!f[0].IsOptional(true) || !f[1].IsOptional(true) || !f[2].IsOptional(true) || !f[3].IsOptional(false) || !f[4].IsOptional(false)
            || AnyNul(f, 5, body, scratch))
        {
            Error(fd, 422, Errors.UserFields);
            return;
        }
        ReadOnlySpan<byte> password = f[2].Value(body, scratch);
        if (!f[2].IsMissing && password.Length > Bcrypt.MaxPasswordBytes)
        {
            Error(fd, 422, Errors.PasswordTooLong);
            return;
        }
        Job job = NewJob(fd, WUpdateUser, viewer);
        job.SetKeep(Jwt.Presented(authorization));
        Wire w = job.Bind;
        w.Bind(Statement.UpdateUser);
        w.Int8(viewer);
        TextOrNull(w, f[0], body, scratch); // email
        TextOrNull(w, f[1], body, scratch); // username
        if (f[2].IsMissing) w.Null();
        else job.HashAt = w.Placeholder(Bcrypt.HashLength);
        TextOrNull(w, f[3], body, scratch); // bio
        TextOrNull(w, f[4], body, scratch); // image
        w.Execute();
        job.Statements = 1;
        if (f[2].IsMissing) _hub.EnqueueWrite(job, this);
        else Hash(job, password);
    }

    /// <summary>Hashes the job's new password on a bcrypt thread; its write is queued once the hash is in.</summary>
    void Hash(Job job, ReadOnlySpan<byte> password)
    {
        password.CopyTo(job.Password);
        job.PasswordLength = password.Length;
        job.Hashing = true;
        if (!Passwords.TrySubmit(job)) Refused(job);
    }

    /// <summary>The bcrypt queue is full: 503 at once.</summary>
    void Refused(Job job) => AnswerError(job, 503, Errors.TooManyLogins);

    /// <summary>A bcrypt job came back: a hashed password's write is queued, a login is answered.</summary>
    void AfterBcrypt(Job job)
    {
        if (Conns[job.Fd].Gen != job.Gen)
        {
            Spare(job);
            return;
        }
        if (job.Dropped)
        {
            // it hung up while queued: its check never ran, so there is nothing true to answer
            Close(job.Fd);
            Spare(job);
            return;
        }
        if (job.Hashing)
        {
            // never store the placeholder: a hash that didn't run fails the write
            if (job.Match) _hub.EnqueueWrite(job, this);
            else FailWrite(job, 500, Errors.Internal);
            return;
        }
        Conns[job.Fd].Busy = false;
        if (job.Known && job.Match)
        {
            int at = HeadRoom;
            Json.Raw(Room(at, job.KeepLength), ref at, job.Keep.AsSpan(0, job.KeepLength));
            Respond(job.Fd, 200, at);
        }
        else Error(job.Fd, 401, Errors.WrongLogin);
        Resume(job.Fd, job.Gen);
        Spare(job);
    }
}
