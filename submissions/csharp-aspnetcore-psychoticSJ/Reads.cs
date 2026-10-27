using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using System.Threading.Channels;
using Npgsql;
using NpgsqlTypes;

namespace ConduitChallenge;

sealed class Reads : IAsyncDisposable
{
    enum Shape { Tags, Profile, Article, Comments, Global, Tag, Author, Favorited, Feed, ArticleId }

    sealed class Request(long viewer, string? key, int limit, int offset, CancellationToken cancellationToken)
    {
        public readonly long Viewer = viewer;
        public readonly string? Key = key;
        public readonly int Limit = limit;
        public readonly int Offset = offset;
        public long QueuedAt;
        public readonly TaskCompletionSource<ApiResult> Completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationTokenRegistration Registration;

        public void Register()
        {
            if (cancellationToken.CanBeCanceled)
                Registration = cancellationToken.UnsafeRegister(static state =>
                {
                    var request = (Request)state!;
                    request.Completion.TrySetCanceled(request.Token);
                }, this);
        }

        CancellationToken Token => cancellationToken;

        public void Complete(ApiResult result)
        {
            if (!Completion.TrySetResult(result))
                result.Body?.Dispose();
            Registration.Dispose();
        }

        public void Fail(Exception exception)
        {
            Completion.TrySetException(exception);
            Registration.Dispose();
        }
    }

    sealed class Queue(Shape shape, bool fast)
    {
        public readonly Shape Shape = shape;
        public readonly bool Fast = fast;
        public readonly ConcurrentQueue<Request> Requests = new();
        public int Scheduled;
    }

    const string Inputs = """
        WITH r AS MATERIALIZED (
            SELECT viewer, key, lim, off, ord
            FROM unnest($1::bigint[], $2::text[], $3::int[], $4::int[])
                 WITH ORDINALITY AS input(viewer, key, lim, off, ord)
        )
        """;

    const string Enrichment = """
        SELECT a.id, a.slug, a.title, a.description,
               ARRAY(SELECT t.name FROM article_tags at CROSS JOIN LATERAL (
                         SELECT t.name FROM tags t WHERE t.id = at.tag_id LIMIT 1
                     ) t
                     WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
               a.created_at, a.updated_at,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               a.author_id, u.username, u.bio, u.image
        FROM chosen c CROSS JOIN LATERAL (
            SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id
            FROM articles a WHERE a.id = c.id LIMIT 1
        ) a CROSS JOIN LATERAL (
            SELECT u.username, u.bio, u.image FROM users u WHERE u.id = a.author_id LIMIT 1
        ) u
        """;

    static readonly NpgsqlDbType[] ParameterTypes =
    [
        NpgsqlDbType.Array | NpgsqlDbType.Bigint,
        NpgsqlDbType.Array | NpgsqlDbType.Text,
        NpgsqlDbType.Array | NpgsqlDbType.Integer,
        NpgsqlDbType.Array | NpgsqlDbType.Integer
    ];

    static readonly (string Page, string Count)[] FilteredLists =
    [
        ("SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT id FROM tags WHERE name = r.key) ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off",
         "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT id FROM tags WHERE name = r.key) LIMIT 1000"),
        ("SELECT a.id FROM articles a WHERE a.author_id = (SELECT id FROM users WHERE username = r.key) ORDER BY a.id DESC LIMIT r.lim OFFSET r.off",
         "SELECT 1 FROM articles a WHERE a.author_id = (SELECT id FROM users WHERE username = r.key) LIMIT 1000"),
        ("SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT id FROM users WHERE username = r.key) ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off",
         "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT id FROM users WHERE username = r.key) LIMIT 1000")
    ];

    const string GlobalPage = "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off";
    const string GlobalCount = "SELECT 1 FROM articles a LIMIT 1000";
    const string FeedPage = """
        SELECT x.id FROM follows fo CROSS JOIN LATERAL (
            SELECT a.id FROM articles a WHERE a.author_id = fo.followee_id
            ORDER BY a.id DESC LIMIT (r.lim::bigint + r.off)
        ) x WHERE fo.follower_id = r.viewer ORDER BY x.id DESC LIMIT r.lim OFFSET r.off
        """;
    const string FeedCount = """
        SELECT 1 FROM follows fo CROSS JOIN LATERAL (
            SELECT 1 FROM articles a WHERE a.author_id = fo.followee_id LIMIT 1000
        ) a WHERE fo.follower_id = r.viewer LIMIT 1000
        """;

    static readonly SqlQuery[] Queries =
    [
        Query(Inputs + "SELECT array_agg(r.ord ORDER BY r.ord), ARRAY(SELECT name FROM tags ORDER BY name) FROM r"),
        Query(Inputs + """
            SELECT r.ord, u.username, u.bio, u.image,
                   (fo.present IS NOT NULL)
            FROM r LEFT JOIN LATERAL (
                SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.username = r.key LIMIT 1
            ) u ON true
            LEFT JOIN LATERAL (
                SELECT 1 AS present FROM follows f
                WHERE r.viewer <> 0 AND f.follower_id = r.viewer AND f.followee_id = u.id LIMIT 1
            ) fo ON true ORDER BY r.ord
            """),
        ArticleQuery(false),
        Query(Inputs + """
            SELECT r.ord, a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                   (fo.present IS NOT NULL)
            FROM r LEFT JOIN LATERAL (
                SELECT a.id FROM articles a WHERE a.slug = r.key LIMIT 1
            ) a ON true
            LEFT JOIN LATERAL (
                SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
                FROM comments c WHERE c.article_id = a.id
                ORDER BY c.created_at DESC, c.id DESC LIMIT 100
            ) c ON true
            LEFT JOIN LATERAL (
                SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id LIMIT 1
            ) u ON true
            LEFT JOIN LATERAL (
                SELECT 1 AS present FROM follows f
                WHERE r.viewer <> 0 AND f.follower_id = r.viewer AND f.followee_id = c.author_id LIMIT 1
            ) fo ON true
            ORDER BY r.ord, c.created_at DESC, c.id DESC
            """),
        ListQuery(GlobalPage, GlobalCount),
        FilteredListQuery(0, false),
        FilteredListQuery(1, false),
        FilteredListQuery(2, false),
        ListQuery(FeedPage, FeedCount),
        ArticleQuery(true)
    ];

    static readonly SqlQuery[] BatchedQueries = CreateBatchedQueries();

    static SqlQuery[] CreateBatchedQueries()
    {
        var queries = (SqlQuery[])Queries.Clone();
        queries[(int)Shape.Comments] = BatchedCommentsQuery();
        queries[(int)Shape.Global] = ListQuery(GlobalPage, GlobalCount, pageKeys: "lim, off");
        for (var i = 0; i < FilteredLists.Length; i++)
            queries[(int)Shape.Tag + i] = FilteredListQuery(i, true);
        return queries;
    }

    static SqlQuery FilteredListQuery(int index, bool countByKey) =>
        ListQuery(FilteredLists[index].Page, FilteredLists[index].Count, countByKey,
            pageKeys: countByKey ? "key, lim, off" : null);

    static SqlQuery Query(string sql) => new(sql, ParameterTypes);

    static SqlQuery BatchedCommentsQuery() => Query(Inputs + """
        , article_inputs AS MATERIALIZED (
            SELECT k.key, a.id FROM (SELECT DISTINCT key FROM r) k
            LEFT JOIN LATERAL (
                SELECT a.id FROM articles a WHERE a.slug = k.key LIMIT 1
            ) a ON true
        ), comment_rows AS MATERIALIZED (
            SELECT a.id AS article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id
            FROM article_inputs a CROSS JOIN LATERAL (
                SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id
                FROM comments c WHERE c.article_id = a.id
                ORDER BY c.created_at DESC, c.id DESC LIMIT 100
            ) c
        ), authors AS MATERIALIZED (
            SELECT c.author_id, u.username, u.bio, u.image
            FROM (SELECT DISTINCT author_id FROM comment_rows) c
            CROSS JOIN LATERAL (
                SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id LIMIT 1
            ) u
        ), details AS (
            SELECT c.article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id,
                   u.username, u.bio, u.image
            FROM comment_rows c JOIN authors u ON u.author_id = c.author_id
        )
        SELECT r.ord, a.id, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,
               (fo.present IS NOT NULL)
        FROM r LEFT JOIN article_inputs a ON a.key = r.key
        LEFT JOIN details c ON c.article_id = a.id
        LEFT JOIN LATERAL (
            SELECT 1 AS present FROM follows f
            WHERE r.viewer <> 0 AND f.follower_id = r.viewer AND f.followee_id = c.author_id LIMIT 1
        ) fo ON true
        ORDER BY r.ord, c.created_at DESC, c.id DESC
        """);

    static SqlQuery ArticleQuery(bool byId)
    {
        var column = byId ? "id" : "slug";
        var key = byId ? "r.key::bigint" : "r.key";
        return Query(Inputs + $$"""
            , chosen AS MATERIALIZED (
                SELECT DISTINCT a.id FROM r CROSS JOIN LATERAL (
                    SELECT a.id FROM articles a WHERE a.{{column}} = {{key}} LIMIT 1
                ) a
            ),
            details AS MATERIALIZED (
                SELECT a.id, a.slug, a.title, a.description, a.body,
                       ARRAY(SELECT t.name FROM article_tags at CROSS JOIN LATERAL (
                         SELECT t.name FROM tags t WHERE t.id = at.tag_id LIMIT 1
                     ) t
                             WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
                       a.created_at, a.updated_at,
                       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                       a.author_id, u.username, u.bio, u.image
                FROM chosen c CROSS JOIN LATERAL (
                    SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id
                    FROM articles a WHERE a.id = c.id LIMIT 1
                ) a CROSS JOIN LATERAL (
                    SELECT u.username, u.bio, u.image FROM users u WHERE u.id = a.author_id LIMIT 1
                ) u
            )
            SELECT r.ord, d.slug, d.title, d.description, d.body, d.tag_list, d.created_at, d.updated_at,
                   (fv.present IS NOT NULL),
                   d.favorites_count, d.username, d.bio, d.image,
                   (fo.present IS NOT NULL), d.id
            FROM r JOIN details d ON d.{{column}} = {{key}}
            LEFT JOIN LATERAL (
                SELECT 1 AS present FROM favorites f
                WHERE r.viewer <> 0 AND f.user_id = r.viewer AND f.article_id = d.id LIMIT 1
            ) fv ON true
            LEFT JOIN LATERAL (
                SELECT 1 AS present FROM follows f
                WHERE r.viewer <> 0 AND f.follower_id = r.viewer AND f.followee_id = d.author_id LIMIT 1
            ) fo ON true ORDER BY r.ord
            """);
    }

    static bool IsList(Shape shape) => shape is >= Shape.Global and <= Shape.Feed;

    static SqlQuery ListQuery(string page, string count, bool countByKey = false, string? pageKeys = null)
    {
        var countInput = countByKey ? "count_inputs" : "r";
        var countKey = countByKey ? "key" : "ord";
        var countInputs = countByKey ? ", count_inputs AS MATERIALIZED (SELECT DISTINCT key FROM r)" : "";
        var pageInput = pageKeys is null ? "r" : "page_inputs";
        var pageInputs = pageKeys is null ? "" : $", page_inputs AS MATERIALIZED (SELECT DISTINCT {pageKeys} FROM r)";
        var pageColumns = pageKeys is null ? "r.ord" : "r." + pageKeys.Replace(", ", ", r.");
        var pageJoin = pageKeys is null ? "p.ord = r.ord" : string.Join(" AND ",
            pageKeys.Split(", ").Select(key => $"p.{key} = r.{key}"));
        return Query(Inputs + $$"""
            {{pageInputs}}, pages AS MATERIALIZED (
                SELECT {{pageColumns}}, p.id FROM {{pageInput}} r CROSS JOIN LATERAL (
                    {{page}}
                ) p
            ), chosen AS MATERIALIZED (SELECT DISTINCT id FROM pages),
            details AS MATERIALIZED (
                {{Enrichment}}
            )
            {{countInputs}}, counts AS MATERIALIZED (
                SELECT r.{{countKey}}, (SELECT count(*) FROM (
                    {{count}}
                ) count_rows) AS total FROM {{countInput}} r
            )
            SELECT r.ord, counts.total, d.slug, d.title, d.description, d.tag_list, d.created_at, d.updated_at,
                   (fv.present IS NOT NULL),
                   d.favorites_count, d.username, d.bio, d.image,
                   (fo.present IS NOT NULL), d.id
            FROM r JOIN counts ON counts.{{countKey}} = r.{{countKey}}
            LEFT JOIN pages p ON {{pageJoin}} LEFT JOIN details d ON d.id = p.id
            LEFT JOIN LATERAL (
                SELECT 1 AS present FROM favorites f
                WHERE r.viewer <> 0 AND f.user_id = r.viewer AND f.article_id = d.id LIMIT 1
            ) fv ON true
            LEFT JOIN LATERAL (
                SELECT 1 AS present FROM follows f
                WHERE r.viewer <> 0 AND f.follower_id = r.viewer AND f.followee_id = d.author_id LIMIT 1
            ) fo ON true
            ORDER BY r.ord, p.id DESC
            """);
    }

    readonly Db _db;
    readonly int _batchSize;
    readonly int _hotBatchSize;
    readonly Queue[] _queues;
    readonly Channel<Queue> _ready = Channel.CreateUnbounded<Queue>(new UnboundedChannelOptions { SingleWriter = false, SingleReader = false });
    readonly Channel<Queue> _fastReady = Channel.CreateUnbounded<Queue>(new UnboundedChannelOptions { SingleWriter = false, SingleReader = false });
    readonly SemaphoreSlim _admission;
    readonly SemaphoreSlim _fastAdmission;
    readonly CancellationTokenSource _stop = new();
    readonly Task[] _workers;
    int _disposed;

    public Reads(Db db, int batchSize = 48, int hotBatchSize = 48, int workers = 21)
    {
        if (batchSize is < 1 or > 64)
            throw new ArgumentOutOfRangeException(nameof(batchSize));
        if (hotBatchSize is < 1 or > 64)
            throw new ArgumentOutOfRangeException(nameof(hotBatchSize));
        if (workers < 1 || workers > db.ReadCount)
            throw new ArgumentOutOfRangeException(nameof(workers));
        _db = db;
        _batchSize = batchSize;
        _hotBatchSize = hotBatchSize;
        var fastWorkers = Math.Min(2, workers - 1);
        var fastCapacity = fastWorkers == 0 ? 0 : 512;
        _admission = new SemaphoreSlim(8192 - fastCapacity, 8192 - fastCapacity);
        _fastAdmission = new SemaphoreSlim(Math.Max(1, fastCapacity), Math.Max(1, fastCapacity));
        _queues = Enum.GetValues<Shape>().Select(shape => new Queue(shape, fastWorkers != 0 && shape is Shape.Tags or Shape.Profile)).ToArray();
        _workers = Enumerable.Range(0, workers).Select(i => WorkerAsync(i < fastWorkers ? _fastReady.Reader : _ready.Reader)).ToArray();
    }

    public ValueTask<ApiResult> TagsAsync(CancellationToken cancellationToken) => EnqueueAsync(Shape.Tags, 0, null, 0, 0, cancellationToken);
    public ValueTask<ApiResult> ProfileAsync(long viewer, string name, CancellationToken cancellationToken) => EnqueueAsync(Shape.Profile, viewer, name, 0, 0, cancellationToken);
    public ValueTask<ApiResult> ArticleAsync(long viewer, string slug, CancellationToken cancellationToken) => EnqueueAsync(Shape.Article, viewer, slug, 0, 0, cancellationToken);
    public ValueTask<ApiResult> ArticleByIdAsync(long viewer, long id, CancellationToken cancellationToken) => EnqueueAsync(Shape.ArticleId, viewer, id.ToString(CultureInfo.InvariantCulture), 0, 0, cancellationToken);
    public ValueTask<ApiResult> CommentsAsync(long viewer, string slug, CancellationToken cancellationToken) => EnqueueAsync(Shape.Comments, viewer, slug, 0, 0, cancellationToken);

    public ValueTask<ApiResult> ListAsync(long viewer, string kind, string? key, int limit, int offset, CancellationToken cancellationToken)
    {
        var shape = kind switch
        {
            "global" => Shape.Global,
            "tag" => Shape.Tag,
            "author" => Shape.Author,
            "favorited" => Shape.Favorited,
            "feed" => Shape.Feed,
            _ => throw new ArgumentOutOfRangeException(nameof(kind))
        };
        return EnqueueAsync(shape, viewer, key, limit, offset, cancellationToken);
    }

    async ValueTask<ApiResult> EnqueueAsync(Shape shape, long viewer, string? key, int limit, int offset, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
        var queue = _queues[(int)shape];
        var admission = queue.Fast ? _fastAdmission : _admission;
        var admissionAt = ReadMetrics.Stamp();
        await admission.WaitAsync(cancellationToken);
        ReadMetrics.Record((int)shape, ReadMetrics.Stage.Admission, ReadMetrics.Elapsed(admissionAt));
        if (Volatile.Read(ref _disposed) != 0)
        {
            admission.Release();
            throw new ObjectDisposedException(nameof(Reads));
        }
        var request = new Request(viewer, key, limit, offset, cancellationToken);
        request.Register();
        request.QueuedAt = ReadMetrics.Stamp();
        queue.Requests.Enqueue(request);
        Schedule(queue);
        if (Volatile.Read(ref _disposed) != 0)
            request.Fail(new ObjectDisposedException(nameof(Reads)));
        return await request.Completion.Task;
    }

    void Schedule(Queue queue)
    {
        if (Interlocked.CompareExchange(ref queue.Scheduled, 1, 0) == 0)
            (queue.Fast ? _fastReady : _ready).Writer.TryWrite(queue);
    }

    async Task WorkerAsync(ChannelReader<Queue> ready)
    {
        var capacity = Math.Max(_batchSize, _hotBatchSize);
        var batch = new Request[capacity];
        var bodies = new PooledBuffer?[capacity];
        var writers = new Utf8JsonWriter?[capacity];
        var counts = new long[capacity];
        var viewersBySize = new long[capacity + 1][];
        var keysBySize = new string?[capacity + 1][];
        var limitsBySize = new int[capacity + 1][];
        var offsetsBySize = new int[capacity + 1][];
        using var idleOutput = new PooledBuffer(1);
        using var shared = new BatchJson();
        try
        {
            await foreach (var queue in ready.ReadAllAsync(_stop.Token))
            {
                var admission = queue.Fast ? _fastAdmission : _admission;
                var size = 0;
                var batchLimit = queue.Shape is Shape.Tags or Shape.Article or Shape.Comments or Shape.Global ? _hotBatchSize : _batchSize;
                while (size < batchLimit && queue.Requests.TryDequeue(out var request))
                {
                    if (request.Completion.Task.IsCompleted)
                    {
                        request.Registration.Dispose();
                        admission.Release();
                    }
                    else
                    {
                        ReadMetrics.Record((int)queue.Shape, ReadMetrics.Stage.Queue, ReadMetrics.Elapsed(request.QueuedAt));
                        batch[size++] = request;
                    }
                }
                Volatile.Write(ref queue.Scheduled, 0);
                if (!queue.Requests.IsEmpty)
                    Schedule(queue);
                if (size == 0)
                    continue;
                ReadMetrics.Batch((int)queue.Shape, size);
                var viewers = viewersBySize[size] ??= new long[size];
                var keys = keysBySize[size] ??= new string?[size];
                var limits = limitsBySize[size] ??= new int[size];
                var offsets = offsetsBySize[size] ??= new int[size];
                for (var i = 0; i < size; i++)
                {
                    viewers[i] = batch[i].Viewer;
                    keys[i] = batch[i].Key;
                    limits[i] = batch[i].Limit;
                    offsets[i] = batch[i].Offset;
                }
                try
                {
                    await ExecuteAsync(queue.Shape, batch, size, viewers, keys, limits, offsets, bodies, writers, counts, idleOutput, shared, _stop.Token);
                }
                catch (Exception exception)
                {
                    for (var i = 0; i < size; i++)
                        batch[i].Fail(exception);
                }
                finally
                {
                    Array.Clear(keys);
                    Array.Clear(batch, 0, size);
                    admission.Release(size);
                }
            }
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        finally
        {
            foreach (var writer in writers) writer?.Dispose();
        }
    }

    async Task ExecuteAsync(Shape shape, Request[] batch, int size, long[] viewers, string?[] keys, int[] limits, int[] offsets,
        PooledBuffer?[] bodies, Utf8JsonWriter?[] writers, long[] counts, PooledBuffer idleOutput, BatchJson shared, CancellationToken cancellationToken)
    {
        try
        {
            if (shape == Shape.Tags)
                Begin(0, "tags");
            var started = ReadMetrics.Stamp();
            await using (var session = await _db.ReadAsync(cancellationToken))
            {
                ReadMetrics.Record((int)shape, ReadMetrics.Stage.Connection, ReadMetrics.Elapsed(started));
                started = ReadMetrics.Stamp();
                var command = await session.CommandAsync((size == 1 ? Queries : BatchedQueries)[(int)shape], cancellationToken);
                DbSession.Set(command, 0, viewers);
                DbSession.Set(command, 1, keys);
                DbSession.Set(command, 2, limits);
                DbSession.Set(command, 3, offsets);
                await using var reader = await command.ExecuteReaderAsync(cancellationToken);
                ReadMetrics.Record((int)shape, ReadMetrics.Stage.Execute, ReadMetrics.Elapsed(started));
                started = ReadMetrics.Stamp();
                while (await reader.ReadAsync(cancellationToken))
                {
                    if (shape == Shape.Tags)
                    {
                        var names = reader.GetFieldValue<string[]>(1);
                        foreach (var name in names) writers[0]!.WriteStringValue(name);
                        continue;
                    }
                    var i = checked((int)reader.GetInt64(0) - 1);
                    switch (shape)
                    {
                        case Shape.Profile:
                            if (!reader.IsDBNull(1))
                            {
                                var writer = Begin(i, null);
                                writer.WritePropertyName("profile");
                                Json.Profile(writer, reader.GetString(1), Text(reader, 2), Text(reader, 3), reader.GetBoolean(4));
                            }
                            break;
                        case Shape.Article:
                        case Shape.ArticleId:
                        {
                            var writer = Begin(i, null);
                            writer.WritePropertyName("article");
                            if (size == 1) Json.Article(writer, reader, 1);
                            else shared.Article(writer, reader, 1, true, reader.GetInt64(reader.FieldCount - 1), i, bodies, writers);
                            break;
                        }
                        case Shape.Comments:
                            if (!reader.IsDBNull(1))
                            {
                                var writer = bodies[i] is null ? Begin(i, "comments") : writers[i]!;
                                if (!reader.IsDBNull(2))
                                {
                                    if (size == 1) Json.Comment(writer, reader, 2);
                                    else shared.Comment(writer, reader, 2, i, bodies, writers);
                                }
                            }
                            break;
                        default:
                        {
                            var writer = bodies[i] is null ? Begin(i, "articles") : writers[i]!;
                            counts[i] = reader.GetInt64(1);
                            if (!reader.IsDBNull(2))
                            {
                                if (size == 1) Json.Article(writer, reader, 2, false);
                                else shared.Article(writer, reader, 2, false, reader.GetInt64(reader.FieldCount - 1), i, bodies, writers);
                            }
                            break;
                        }
                    }
                }
                ReadMetrics.Record((int)shape, ReadMetrics.Stage.ReadEncode, ReadMetrics.Elapsed(started));
            }
            shared.Clear();
            started = ReadMetrics.Stamp();
            if (shape == Shape.Tags)
            {
                var writer = writers[0]!;
                writer.WriteEndArray();
                writer.WriteEndObject();
                writer.Flush();
                writer.Reset(idleOutput);
                var encoded = bodies[0]!.WrittenMemory;
                for (var i = 1; i < size; i++)
                {
                    var copy = new PooledBuffer(encoded.Length);
                    bodies[i] = copy;
                    encoded.Span.CopyTo(copy.GetSpan(encoded.Length));
                    copy.Advance(encoded.Length);
                }
                for (var i = 0; i < size; i++)
                {
                    var body = bodies[i]!;
                    bodies[i] = null;
                    batch[i].Complete(new ApiResult(200, body));
                }
                ReadMetrics.Record((int)shape, ReadMetrics.Stage.FinishEncode, ReadMetrics.Elapsed(started));
                return;
            }
            for (var i = 0; i < size; i++)
            {
                if (bodies[i] is not null && writers[i] is { } writer)
                {
                    if (shape == Shape.Tags || shape == Shape.Comments || IsList(shape))
                        writer.WriteEndArray();
                    if (IsList(shape))
                        writer.WriteNumber("articlesCount", counts[i]);
                    writer.WriteEndObject();
                    writer.Flush();
                    writer.Reset(idleOutput);
                    var body = bodies[i]!;
                    bodies[i] = null;
                    batch[i].Complete(new ApiResult(200, body));
                }
                else
                    batch[i].Complete(Json.Error(404, "Not found"));
            }
            ReadMetrics.Record((int)shape, ReadMetrics.Stage.FinishEncode, ReadMetrics.Elapsed(started));
        }
        finally
        {
            shared.Clear();
            for (var i = 0; i < size; i++)
            {
                writers[i]?.Reset(idleOutput);
                bodies[i]?.Dispose();
                bodies[i] = null;
                counts[i] = 0;
            }
        }

        Utf8JsonWriter Begin(int index, string? array)
        {
            var buffer = new PooledBuffer(IsList(shape) ? 8192 : 2048);
            bodies[index] = buffer;
            var writer = writers[index];
            if (writer is null) writers[index] = writer = new Utf8JsonWriter(buffer);
            else writer.Reset(buffer);
            writer.WriteStartObject();
            if (array is not null)
                writer.WriteStartArray(array);
            return writer;
        }
    }

    static string? Text(NpgsqlDataReader reader, int index) => reader.IsDBNull(index) ? null : reader.GetString(index);

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
            return;
        _ready.Writer.TryComplete();
        _fastReady.Writer.TryComplete();
        _stop.Cancel();
        await Task.WhenAll(_workers);
        foreach (var queue in _queues)
            while (queue.Requests.TryDequeue(out var request))
            {
                request.Fail(new ObjectDisposedException(nameof(Reads)));
                (queue.Fast ? _fastAdmission : _admission).Release();
            }
        _stop.Dispose();
        await ReadMetrics.StopAsync();
    }
}
