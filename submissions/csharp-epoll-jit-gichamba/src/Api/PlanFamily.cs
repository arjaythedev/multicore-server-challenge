using Conduit.Dispatch;
using Conduit.Json;
using Conduit.Pg;

namespace Conduit.Api;

/// <summary>
/// The batch planner. One batch carries every article read (the four lists, the feed, single articles) and every comments
/// read, and answers them in two round trips on one connection: phase A runs one statement per kind present, over
/// distinct keys only (one global page per limit and offset, one count per tag, one comment read per slug); phase B
/// enriches every distinct article phase A found, once, and reads the viewers' favorited and following flags. Requests
/// share only what their own batch read from Postgres; nothing outlives the batch. The statements are in <see cref="PlanSql"/>.
/// </summary>
public sealed class PlanFamily : ReadFamily {
    /// <summary>The phase A statements, in the order of <see cref="PlanSql.All"/>.</summary>
    private enum Kind { Global, Tag, Author, Favorited, Feed, Slug, Comments }

    /// <summary>The phase B statements: article enrichment, the tags table, and the favorite and follow flags.</summary>
    private enum Step { Articles, TagTable, Flags }

    /// <summary>Prepared statement names of the phase A statements, by <see cref="Kind"/>.</summary>
    private static readonly string[] KindNames =
        [PlanSql.GlobalName, PlanSql.TagName, PlanSql.AuthorName, PlanSql.FavoritedName, PlanSql.FeedName, PlanSql.SlugName, PlanSql.CommentsName];

    /// <summary>Creates the planner. It has no settings: the statements are fixed.</summary>
    public PlanFamily() : base(ReadKinds.Plan, "plan") {
    }

    /// <inheritdoc />
    public override bool OwnsBatch => true;

    /// <inheritdoc />
    public override bool UsesEveryConnection => true;

    /// <inheritdoc />
    public override string Sql => PlanSql.Global;

    /// <inheritdoc />
    public override uint[] ParamOids => PlanSql.All[0].Oids;

    /// <inheritdoc />
    public override IEnumerable<(string Name, string Sql, uint[] Oids)> Statements => PlanSql.All;

    /// <summary>Not used: the planner encodes its batches in <see cref="PrepareBatch"/>.</summary>
    public override void Encode(PgParams p, ReadOnlySpan<ReadJob> jobs) => throw new NotSupportedException();

    /// <summary>Not used: rows go to <see cref="OnBatchRow"/>.</summary>
    public override void OnRow(ReadJob job, in PgRow row) => throw new NotSupportedException();

    /// <summary>Not used: jobs are answered in <see cref="FinishBatch"/>.</summary>
    public override int Complete(ReadJob job) => throw new NotSupportedException();

    /// <inheritdoc />
    protected internal override void PrepareBatch(ReadBatch batch) {
        Plan plan = new(batch.Count);
        batch.State = plan;
        for (int i = 0; i < batch.Count; i++) {
            plan.Asks[i] = plan.AskOf(batch.Jobs[i]);
        }

        for (int k = 0; k <= (int)Kind.Comments; k++) {
            if (plan.Has((Kind)k)) {
                plan.Order.Add((Kind)k);
                plan.Encode((Kind)k, batch.Statement(KindNames[k]));
            }
        }
    }

    /// <inheritdoc />
    protected internal override void OnBatchRow(ReadBatch batch, int statementIndex, in PgRow row) {
        Plan plan = (Plan)batch.State!;
        if (plan.PhaseB) {
            plan.ReadPhaseB(statementIndex, row);
        } else {
            plan.ReadPhaseA(plan.Order[statementIndex], row);
        }
    }

    /// <inheritdoc />
    protected internal override bool ContinueBatch(ReadBatch batch) {
        Plan plan = (Plan)batch.State!;
        if (plan.PhaseB) {
            return false;
        }

        plan.CollectPhaseB(batch);
        if (plan.Articles.Count == 0 && plan.FavoritePairs.Count == 0 && plan.FollowPairs.Count == 0) {
            return false;
        }

        plan.PhaseB = true;
        batch.ClearStatements();
        if (plan.Articles.Count > 0) {
            PgParams p = batch.Statement(PlanSql.ArticlesName);
            p.AddInt8Array(plan.Articles.List.ToArray());
            p.AddInt8Array(plan.Authors.ToArray());
            plan.PhaseBOrder.Add(Step.Articles);
            batch.Statement(PlanSql.TagTableName);
            plan.PhaseBOrder.Add(Step.TagTable);
        }
        if (plan.FavoritePairs.Count + plan.FollowPairs.Count > 0) {
            PgParams p = batch.Statement(PlanSql.FlagsName);
            p.AddInt8Array(plan.FavoritePairs.List.Select(x => x.Item1).ToArray());
            p.AddInt8Array(plan.FavoritePairs.List.Select(x => x.Item2).ToArray());
            p.AddInt8Array(plan.FollowPairs.List.Select(x => x.Item1).ToArray());
            p.AddInt8Array(plan.FollowPairs.List.Select(x => x.Item2).ToArray());
            plan.PhaseBOrder.Add(Step.Flags);
        }
        return true;
    }

    /// <inheritdoc />
    protected internal override void FinishBatch(ReadBatch batch, bool failed) {
        Plan? plan = batch.State as Plan;
        for (int i = 0; i < batch.Count; i++) {
            ReadJob job = batch.Jobs[i];
            try {
                if (failed || plan is null) {
                    job.Fail(500, "internal error");
                } else {
                    plan.Answer(job, plan.Asks[i]);
                }
            } catch (Exception) {
                try {
                    job.ResetResult();
                    job.Fail(500, "internal error");
                } catch (Exception) {
                    // The client is gone; there is no one left to answer.
                }
            }
        }
    }

    /// <summary>What one job asked phase A for: its kind, its count key and its page key. For slugs and comments the page key is the slug key and the count key is 0.</summary>
    private readonly record struct Ask(Kind Kind, int Count, int Page);

    /// <summary>An article row of phase A. Text is kept as the UTF-8 bytes of the result, copied out of the row.</summary>
    private sealed class ArticleRow {
        /// <summary>Article id.</summary>
        public readonly long Id;
        /// <summary>Id of the author.</summary>
        public readonly long AuthorId;
        /// <summary>Slug bytes.</summary>
        public readonly byte[] Slug;
        /// <summary>Title bytes.</summary>
        public readonly byte[] Title;
        /// <summary>Description bytes.</summary>
        public readonly byte[] Description;
        /// <summary>Creation time in the wire format of <see cref="PgBinary.ReadTimestamptz"/>.</summary>
        public readonly long CreatedAt;
        /// <summary>Update time in the same format.</summary>
        public readonly long UpdatedAt;
        /// <summary>Body bytes; null unless the row was read with the body.</summary>
        public readonly byte[]? Body;

        /// <summary>Reads an article row: id, author_id, slug, title, description, created_at, updated_at and, when <paramref name="withBody"/>, body.</summary>
        public ArticleRow(in PgRow row, bool withBody) {
            Id = PgBinary.ReadInt8(row[1]);
            AuthorId = PgBinary.ReadInt8(row[2]);
            Slug = row[3].ToArray();
            Title = row[4].ToArray();
            Description = row[5].ToArray();
            CreatedAt = PgBinary.ReadTimestamptz(row[6]);
            UpdatedAt = PgBinary.ReadTimestamptz(row[7]);
            Body = withBody ? row[8].ToArray() : null;
        }
    }

    /// <summary>A comment row of phase A, with its author's profile fields as bytes.</summary>
    private sealed class CommentRow {
        /// <summary>Comment id.</summary>
        public readonly long Id;
        /// <summary>Body bytes.</summary>
        public readonly byte[] Body;
        /// <summary>Creation time in the wire format of <see cref="PgBinary.ReadTimestamptz"/>.</summary>
        public readonly long CreatedAt;
        /// <summary>Update time in the same format.</summary>
        public readonly long UpdatedAt;
        /// <summary>Id of the comment's author.</summary>
        public readonly long AuthorId;
        /// <summary>Author's username bytes.</summary>
        public readonly byte[] Username;
        /// <summary>Author's bio bytes; null when NULL.</summary>
        public readonly byte[]? Bio;
        /// <summary>Author's image bytes; null when NULL.</summary>
        public readonly byte[]? Image;

        /// <summary>Reads a comment row: n, id, body, created_at, updated_at, author_id, username, bio, image.</summary>
        public CommentRow(in PgRow row) {
            Id = PgBinary.ReadInt8(row[1]);
            Body = row[2].ToArray();
            CreatedAt = PgBinary.ReadTimestamptz(row[3]);
            UpdatedAt = PgBinary.ReadTimestamptz(row[4]);
            AuthorId = PgBinary.ReadInt8(row[5]);
            Username = row[6].ToArray();
            Bio = row.IsNull(7) ? null : row[7].ToArray();
            Image = row.IsNull(8) ? null : row[8].ToArray();
        }
    }

    /// <summary>What phase B read about one article: its tag ids, favorites count and author fields.</summary>
    private sealed class Enrichment {
        /// <summary>Tag ids in no order.</summary>
        public readonly int[] TagIds;
        /// <summary>Number of favorites.</summary>
        public readonly long Favorites;
        /// <summary>Author's username bytes.</summary>
        public readonly byte[] Username;
        /// <summary>Author's bio bytes; null when NULL.</summary>
        public readonly byte[]? Bio;
        /// <summary>Author's image bytes; null when NULL.</summary>
        public readonly byte[]? Image;

        /// <summary>Reads a phase B article row: id, tag ids, favorites count, username, bio, image.</summary>
        public Enrichment(in PgRow row) {
            TagIds = ArticleJson.ReadInt4Array(row[1]);
            Favorites = PgBinary.ReadInt8(row[2]);
            Username = row[3].ToArray();
            Bio = row.IsNull(4) ? null : row[4].ToArray();
            Image = row.IsNull(5) ? null : row[5].ToArray();
        }
    }

    /// <summary>Distinct keys of one statement, in order of first use. A key's position is its 0-based index; SQL numbers it from 1.</summary>
    private sealed class Keys<T> where T : notnull {
        /// <summary>Position of each key.</summary>
        private readonly Dictionary<T, int> _at = [];

        /// <summary>The keys in order of first use.</summary>
        public List<T> List { get; } = [];

        /// <summary>Number of distinct keys.</summary>
        public int Count => List.Count;

        /// <summary>Returns the position of <paramref name="key"/>, adding it at the end when it is new.</summary>
        public int Index(T key) {
            if (!_at.TryGetValue(key, out int i)) {
                i = List.Count;
                _at.Add(key, i);
                List.Add(key);
            }
            return i;
        }

        /// <summary>Finds the position of <paramref name="key"/> without adding it.</summary>
        public bool TryGet(T key, out int index) => _at.TryGetValue(key, out index);
    }

    /// <summary>The counts and pages of one list kind.</summary>
    private sealed class Lists {
        /// <summary>Distinct filters to count (viewers, as text, for the feed).</summary>
        public readonly Keys<string> CountKeys = new();
        /// <summary>Distinct pages: filter, limit and offset.</summary>
        public readonly Keys<(string Key, int Limit, long Offset)> PageKeys = new();
        /// <summary>The capped count of each count key.</summary>
        public long[] Counts = [];
        /// <summary>The rows of each page, by page key.</summary>
        public List<ArticleRow>[] Pages = [];
    }

    /// <summary>One batch's keys, rows and flags. Created by <see cref="PrepareBatch"/> and kept in the batch state.</summary>
    private sealed class Plan {
        /// <summary>What each job of the batch asked for, by job position.</summary>
        public readonly Ask[] Asks;
        /// <summary>The kinds present in the batch, in statement order. A phase A statement index is a position here.</summary>
        public readonly List<Kind> Order = [];
        /// <summary>The phase B statements sent, in order. A phase B statement index is a position here.</summary>
        public readonly List<Step> PhaseBOrder = [];
        /// <summary>True once the batch is in phase B.</summary>
        public bool PhaseB;

        /// <summary>The counts and pages of Global, Tag, Author, Favorited and Feed, by kind. The feed's count keys are viewers, kept as text.</summary>
        private readonly Lists[] _lists = [new(), new(), new(), new(), new()];
        /// <summary>Distinct slugs of single-article requests.</summary>
        private readonly Keys<string> _slugs = new();
        /// <summary>Distinct slugs of comment requests.</summary>
        private readonly Keys<string> _commentSlugs = new();
        /// <summary>The article of each slug key; null when no article has the slug.</summary>
        private ArticleRow?[] _bySlug = [];
        /// <summary>The comments of each comment slug key; null when no article has the slug.</summary>
        private List<CommentRow>?[] _comments = [];

        /// <summary>Distinct article ids of the whole batch, for phase B.</summary>
        public readonly Keys<long> Articles = new();
        /// <summary>The author id of each article in <see cref="Articles"/>, by position.</summary>
        public readonly List<long> Authors = [];
        /// <summary>Distinct (viewer, article) pairs to check for favorites.</summary>
        public readonly Keys<(long, long)> FavoritePairs = new();
        /// <summary>Distinct (viewer, author) pairs to check for follows.</summary>
        public readonly Keys<(long, long)> FollowPairs = new();
        /// <summary>What phase B read about each article in <see cref="Articles"/>, by position.</summary>
        private Enrichment?[] _enriched = [];
        /// <summary>The (viewer, article) pairs phase B found to be favorites.</summary>
        private readonly HashSet<(long, long)> _favorited = [];
        /// <summary>Position of each tag id in the database's name order.</summary>
        private readonly Dictionary<int, int> _tagRank = [];
        /// <summary>Tag names in the database's name order.</summary>
        private readonly List<byte[]> _tagNames = [];
        /// <summary>The (viewer, user) pairs phase B found to be follows.</summary>
        private readonly HashSet<(long, long)> _following = [];

        /// <summary>Creates the plan for a batch of <paramref name="jobs"/> jobs.</summary>
        public Plan(int jobs) => Asks = new Ask[jobs];

        /// <summary>Registers the keys that <paramref name="job"/> needs and returns where its answer will be. Throws for a request kind the planner does not serve.</summary>
        public Ask AskOf(ReadJob job) {
            switch (job.Kind) {
                case ReadKinds.Article:
                    return new Ask(Kind.Slug, 0, _slugs.Index(job.Key ?? ""));
                case ReadKinds.Comments:
                    return new Ask(Kind.Comments, 0, _commentSlugs.Index(job.Key ?? ""));
                default:
                    Kind kind = job.Kind switch {
                        ReadKinds.List => Kind.Global,
                        ReadKinds.ListTag => Kind.Tag,
                        ReadKinds.ListAuthor => Kind.Author,
                        ReadKinds.ListFav => Kind.Favorited,
                        ReadKinds.Feed => Kind.Feed,
                        _ => throw new InvalidOperationException("the planner does not serve request kind " + job.Kind),
                    };
                    string key = kind switch {
                        Kind.Global => "",
                        Kind.Feed => job.Viewer.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        _ => job.Key ?? "",
                    };
                    Lists l = _lists[(int)kind];
                    return new Ask(kind, l.CountKeys.Index(key), l.PageKeys.Index((key, job.Limit, job.Offset)));
            }
        }

        /// <summary>True when some job of the batch needs the phase A statement of <paramref name="kind"/>.</summary>
        public bool Has(Kind kind) => kind switch {
            Kind.Slug => _slugs.Count > 0,
            Kind.Comments => _commentSlugs.Count > 0,
            _ => _lists[(int)kind].PageKeys.Count > 0,
        };

        /// <summary>Adds the parameters of the statement of <paramref name="kind"/> to <paramref name="p"/> and sizes its result storage.</summary>
        public void Encode(Kind kind, PgParams p) {
            switch (kind) {
                case Kind.Slug:
                    p.AddTextArray(_slugs.List.ToArray());
                    _bySlug = new ArticleRow?[_slugs.Count];
                    return;
                case Kind.Comments:
                    p.AddTextArray(_commentSlugs.List.ToArray());
                    _comments = new List<CommentRow>?[_commentSlugs.Count];
                    return;
            }

            Lists l = _lists[(int)kind];
            l.Counts = new long[l.CountKeys.Count];
            l.Pages = new List<ArticleRow>[l.PageKeys.Count];
            for (int i = 0; i < l.Pages.Length; i++) {
                l.Pages[i] = [];
            }

            long[] limits = [.. l.PageKeys.List.Select(x => (long)x.Limit)];
            long[] offsets = [.. l.PageKeys.List.Select(x => x.Offset)];
            if (kind == Kind.Global) {
                p.AddInt8Array(limits);
                p.AddInt8Array(offsets);
            } else if (kind == Kind.Feed) {
                p.AddInt8Array(l.CountKeys.List.Select(ParseViewer).ToArray());
                p.AddInt8Array(l.PageKeys.List.Select(x => ParseViewer(x.Key)).ToArray());
                p.AddInt8Array(limits);
                p.AddInt8Array(offsets);
            } else {
                p.AddTextArray(l.CountKeys.List.ToArray());
                p.AddTextArray(l.PageKeys.List.Select(x => x.Key).ToArray());
                p.AddInt8Array(limits);
                p.AddInt8Array(offsets);
            }
        }

        /// <summary>Parses a feed key. The feed's keys are viewer ids written as text, so the five list kinds share one key type.</summary>
        private static long ParseViewer(string key) => long.Parse(key, System.Globalization.CultureInfo.InvariantCulture);

        /// <summary>
        /// Stores a phase A row of <paramref name="kind"/>. Column 0 is the key's 1-based position n. In a list a row with n &lt;= 0
        /// is a count row; a positive n is a page row.
        /// </summary>
        public void ReadPhaseA(Kind kind, in PgRow row) {
            long n = PgBinary.ReadInt8(row[0]);
            switch (kind) {
                case Kind.Slug:
                    _bySlug[n - 1] = new ArticleRow(row, withBody: true);
                    return;
                case Kind.Comments:
                    List<CommentRow> list = _comments[n - 1] ??= [];
                    if (!row.IsNull(1)) {
                        list.Add(new CommentRow(row));
                    }
                    return;
            }

            Lists l = _lists[(int)kind];
            if (n <= 0) {
                // A filtered list's count row carries -n, the count key's 1-based position. The global list has one
                // count key, the empty filter, and its single count row carries 0.
                l.Counts[n == 0 ? 0 : -n - 1] = PgBinary.ReadInt8(row[1]);
            } else {
                l.Pages[n - 1].Add(new ArticleRow(row, withBody: false));
            }
        }

        /// <summary>Orders every page newest first and collects the distinct articles and flag pairs of the whole batch.</summary>
        public void CollectPhaseB(ReadBatch batch) {
            foreach (Lists l in _lists) {
                foreach (List<ArticleRow> page in l.Pages) {
                    page.Sort((x, y) => y.Id.CompareTo(x.Id));
                }
            }

            for (int i = 0; i < batch.Count; i++) {
                long viewer = batch.Jobs[i].Viewer;
                Ask ask = Asks[i];
                switch (ask.Kind) {
                    case Kind.Slug:
                        if (_bySlug[ask.Page] is { } a) {
                            Add(a, viewer, follow: true);
                        }
                        break;
                    case Kind.Comments:
                        if (viewer != 0 && _comments[ask.Page] is { } comments) {
                            foreach (CommentRow c in comments) {
                                FollowPairs.Index((viewer, c.AuthorId));
                            }
                        }
                        break;
                    default:
                        foreach (ArticleRow r in _lists[(int)ask.Kind].Pages[ask.Page]) {
                            Add(r, viewer, follow: ask.Kind != Kind.Feed);
                        }
                        break;
                }
            }
            _enriched = new Enrichment?[Articles.Count];
        }

        /// <summary>
        /// Adds article <paramref name="a"/> and its author to the phase B keys. For a signed-in viewer it also adds the favorite
        /// pair and, when <paramref name="follow"/>, the follow pair.
        /// </summary>
        private void Add(ArticleRow a, long viewer, bool follow) {
            if (Articles.Index(a.Id) == Authors.Count) {
                Authors.Add(a.AuthorId);
            }
            if (viewer != 0) {
                FavoritePairs.Index((viewer, a.Id));
                if (follow) {
                    FollowPairs.Index((viewer, a.AuthorId));
                }
            }
        }

        /// <summary>Stores a phase B row of the statement at <paramref name="statementIndex"/> in <see cref="PhaseBOrder"/>.</summary>
        public void ReadPhaseB(int statementIndex, in PgRow row) {
            switch (PhaseBOrder[statementIndex]) {
                case Step.Articles:
                    if (Articles.TryGet(PgBinary.ReadInt8(row[0]), out int at)) {
                        _enriched[at] = new Enrichment(row);
                    }
                    return;
                case Step.TagTable:
                    if (!row.IsNull(0)) {
                        int[] ids = ArticleJson.ReadInt4Array(row[0]);
                        byte[]?[] names = PgBinary.ReadTextArrayBytes(row[1]);
                        for (int i = 0; i < ids.Length; i++) {
                            _tagRank[ids[i]] = _tagNames.Count;
                            _tagNames.Add(names[i] ?? []);
                        }
                    }
                    return;
            }

            (long, long) pair = (PgBinary.ReadInt8(row[1]), PgBinary.ReadInt8(row[2]));
            (PgBinary.ReadInt8(row[0]) == 0 ? _favorited : _following).Add(pair);
        }

        /// <summary>Builds the response of <paramref name="job"/> from the stored rows and sends it, or sends 404 when its article is missing.</summary>
        public void Answer(ReadJob job, Ask ask) {
            JsonWriter w = job.Out.Body;
            long viewer = job.Viewer;
            switch (ask.Kind) {
                case Kind.Slug:
                    if (_bySlug[ask.Page] is not { } a || Enriched(a) is not { } e) {
                        job.Fail(404, "article not found");
                        return;
                    }

                    w.StartObject();
                    w.PropertyName("article"u8);
                    WriteArticle(w, a, e, viewer, feed: false);
                    w.EndObject();
                    job.Respond(200);
                    return;
                case Kind.Comments:
                    if (_comments[ask.Page] is not { } comments) {
                        job.Fail(404, "article not found");
                        return;
                    }

                    comments.Sort((x, y) => x.CreatedAt != y.CreatedAt ? y.CreatedAt.CompareTo(x.CreatedAt) : y.Id.CompareTo(x.Id));
                    w.StartObject();
                    w.PropertyName("comments"u8);
                    w.StartArray();
                    foreach (CommentRow c in comments) {
                        w.StartObject();
                        w.PropertyName("id"u8);
                        w.WriteLong(c.Id);
                        w.PropertyName("createdAt"u8);
                        w.WriteTimestamp(c.CreatedAt);
                        w.PropertyName("updatedAt"u8);
                        w.WriteTimestamp(c.UpdatedAt);
                        w.PropertyName("body"u8);
                        w.WriteString(c.Body);
                        w.PropertyName("author"u8);
                        WriteProfile(w, c.Username, c.Bio, c.Image, viewer != 0 && _following.Contains((viewer, c.AuthorId)));
                        w.EndObject();
                    }
                    w.EndArray();
                    w.EndObject();
                    job.Respond(200);
                    return;
            }

            Lists l = _lists[(int)ask.Kind];
            w.StartObject();
            w.PropertyName("articlesCount"u8);
            w.WriteLong(l.Counts[ask.Count]);
            w.PropertyName("articles"u8);
            w.StartArray();
            foreach (ArticleRow r in l.Pages[ask.Page]) {
                if (Enriched(r) is { } e) {
                    WriteArticle(w, r, e, viewer, feed: ask.Kind == Kind.Feed);
                }
            }
            w.EndArray();
            w.EndObject();
            job.Respond(200);
        }

        /// <summary>The phase B data of article <paramref name="a"/>, or null when phase B did not return it.</summary>
        private Enrichment? Enriched(ArticleRow a) => Articles.TryGet(a.Id, out int at) ? _enriched[at] : null;

        /// <summary>Writes the Article object in the field order of <see cref="ArticleJson.WriteArticle"/>. With <paramref name="feed"/> every author is followed, since the feed holds only followed authors.</summary>
        private void WriteArticle(JsonWriter w, ArticleRow a, Enrichment e, long viewer, bool feed) {
            w.StartObject();
            w.PropertyName("slug"u8);
            w.WriteString(a.Slug);
            w.PropertyName("title"u8);
            w.WriteString(a.Title);
            w.PropertyName("description"u8);
            w.WriteString(a.Description);
            if (a.Body is not null) {
                w.PropertyName("body"u8);
                w.WriteString(a.Body);
            }
            w.PropertyName("createdAt"u8);
            w.WriteTimestamp(a.CreatedAt);
            w.PropertyName("updatedAt"u8);
            w.WriteTimestamp(a.UpdatedAt);
            w.PropertyName("tagList"u8);
            w.StartArray();
            WriteTags(w, e.TagIds);
            w.EndArray();
            w.PropertyName("favorited"u8);
            w.WriteBool(viewer != 0 && _favorited.Contains((viewer, a.Id)));
            w.PropertyName("favoritesCount"u8);
            w.WriteLong(e.Favorites);
            w.PropertyName("author"u8);
            WriteProfile(w, e.Username, e.Bio, e.Image, feed || (viewer != 0 && _following.Contains((viewer, a.AuthorId))));
            w.EndObject();
        }

        /// <summary>Writes the names of <paramref name="tagIds"/> in the database's name order. A tag missing from the table is left out.</summary>
        private void WriteTags(JsonWriter w, int[] tagIds) {
            Span<int> ranks = tagIds.Length <= 64 ? stackalloc int[64] : new int[tagIds.Length];
            int n = 0;
            foreach (int id in tagIds) {
                if (_tagRank.TryGetValue(id, out int rank)) {
                    ranks[n++] = rank;
                }
            }
            ranks = ranks[..n];
            ranks.Sort();
            foreach (int rank in ranks) {
                w.WriteString(_tagNames[rank]);
            }
        }

        /// <summary>Writes a Profile object from bytes already read.</summary>
        private static void WriteProfile(JsonWriter w, byte[] username, byte[]? bio, byte[]? image, bool following) {
            w.StartObject();
            w.PropertyName("username"u8);
            w.WriteString(username);
            w.PropertyName("bio"u8);
            WriteNullable(w, bio);
            w.PropertyName("image"u8);
            WriteNullable(w, image);
            w.PropertyName("following"u8);
            w.WriteBool(following);
            w.EndObject();
        }

        /// <summary>Writes <paramref name="text"/> as a JSON string, or null when it is null.</summary>
        private static void WriteNullable(JsonWriter w, byte[]? text) {
            if (text is null) {
                w.WriteNull();
            } else {
                w.WriteString(text);
            }
        }
    }
}
