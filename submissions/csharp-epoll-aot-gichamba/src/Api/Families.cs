using Conduit.Dispatch;
using Conduit.Json;
using Conduit.Pg;

namespace Conduit.Api;

/// <summary>
/// GET /api/tags. The answer is the same for everyone, so one execution, read live, answers every request waiting in
/// the batch.
/// </summary>
public sealed class TagsFamily : ReadFamily {
    /// <summary>Creates the family.</summary>
    public TagsFamily() : base(ReadKinds.Tags, "tags") { }

    /// <inheritdoc />
    public override bool Broadcast => true;

    /// <inheritdoc />
    public override string Sql => "SELECT name FROM tags ORDER BY name";

    /// <inheritdoc />
    public override uint[] ParamOids => [];

    /// <summary>The statement takes no parameters.</summary>
    public override void Encode(PgParams p, ReadOnlySpan<ReadJob> jobs) {
    }

    /// <inheritdoc />
    public override void OnRow(ReadJob job, in PgRow row) {
        if (job.Rows++ == 0) {
            Begin(job);
        }

        job.Out.Body.WriteString(row[First]);
    }

    /// <inheritdoc />
    public override int Complete(ReadJob job) {
        if (job.Rows == 0) {
            Begin(job);  // no tags at all
        }

        job.Out.Body.EndArray();
        job.Out.Body.EndObject();
        return 200;
    }

    /// <summary>Writes <c>{"tags":[</c>, which goes before the first name.</summary>
    private static void Begin(ReadJob job) {
        job.Out.Body.StartObject();
        job.Out.Body.PropertyName("tags"u8);
        job.Out.Body.StartArray();
    }
}

/// <summary>GET /api/user: the signed-in user's row.</summary>
public sealed class UserFamily : ReadFamily {
    /// <summary>Creates the family.</summary>
    public UserFamily() : base(ReadKinds.User, "user") { }

    /// <inheritdoc />
    public override string Sql =>
        "SELECT r.i, x.email, x.username, x.bio, x.image FROM unnest($1::int8[], $2::int8[]) AS r(i, v) " +
        "CROSS JOIN LATERAL (SELECT u.email, u.username, u.bio, u.image FROM users u WHERE u.id = r.v) x";

    /// <inheritdoc />
    public override uint[] ParamOids => [PgOid.Int8Array, PgOid.Int8Array];

    /// <inheritdoc />
    public override void Encode(PgParams p, ReadOnlySpan<ReadJob> jobs) {
        AddIndexes(p, jobs.Length);
        AddViewers(p, jobs);
    }

    /// <inheritdoc />
    public override void OnRow(ReadJob job, in PgRow row) {
        if (job.Rows++ > 0) {
            return;
        }

        JsonWriter w = job.Out.Body;
        w.StartObject();
        w.PropertyName("user"u8);
        w.StartObject();
        w.PropertyName("email"u8);
        w.WriteString(row[1]);
        w.PropertyName("token"u8);
        w.WriteString(job.Token);
        w.PropertyName("username"u8);
        w.WriteString(row[2]);
        w.PropertyName("bio"u8);
        Nullable(w, row, 3);
        w.PropertyName("image"u8);
        Nullable(w, row, 4);
        w.EndObject();
        w.EndObject();
    }

    /// <inheritdoc />
    public override int Complete(ReadJob job) => job.Rows > 0 ? 200 : Error(job, 401, "user not found");

    /// <summary>Writes the text in <paramref name="column"/> of <paramref name="row"/> as a JSON string, or null when the column is NULL.</summary>
    internal static void Nullable(Json.JsonWriter w, in PgRow row, int column) {
        if (row.IsNull(column)) {
            w.WriteNull();
        } else {
            w.WriteString(row[column]);
        }
    }
}

/// <summary>GET /api/profiles/:username, with the viewer's following flag.</summary>
public sealed class ProfileFamily : ReadFamily {
    /// <summary>Creates the family.</summary>
    public ProfileFamily() : base(ReadKinds.Profile, "profile") { }

    /// <inheritdoc />
    public override string Sql =>
        "SELECT r.i, x.username, x.bio, x.image, x.following FROM unnest($1::int8[], $2::int8[], $3::text[]) AS r(i, v, k) " +
        "CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image, " +
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) AS following " +
        "FROM users u WHERE u.username = r.k) x";

    /// <inheritdoc />
    public override uint[] ParamOids => [PgOid.Int8Array, PgOid.Int8Array, PgOid.TextArray];

    /// <inheritdoc />
    public override void Encode(PgParams p, ReadOnlySpan<ReadJob> jobs) {
        AddIndexes(p, jobs.Length);
        AddViewers(p, jobs);
        AddKeys(p, jobs);
    }

    /// <inheritdoc />
    public override void OnRow(ReadJob job, in PgRow row) {
        if (job.Rows++ > 0) {
            return;
        }

        JsonWriter w = job.Out.Body;
        w.StartObject();
        w.PropertyName("profile"u8);
        w.StartObject();
        w.PropertyName("username"u8);
        w.WriteString(row[1]);
        w.PropertyName("bio"u8);
        UserFamily.Nullable(w, row, 2);
        w.PropertyName("image"u8);
        UserFamily.Nullable(w, row, 3);
        w.PropertyName("following"u8);
        w.WriteBool(PgBinary.ReadBool(row[4]));
        w.EndObject();
        w.EndObject();
    }

    /// <inheritdoc />
    public override int Complete(ReadJob job) => job.Rows > 0 ? 200 : Error(job, 404, "profile not found");
}

/// <summary>The read families this build serves. To add one, write its class, add a property here and list it in <see cref="All"/>.</summary>
public sealed class ReadFamilies {
    /// <summary>Builds every family. The JWT secret in <paramref name="settings"/> signs the tokens login issues.</summary>
    private ReadFamilies(Settings settings, IPasswords? passwords, Func<long>? nowUnix) {
        Tags = new TagsFamily();
        User = new UserFamily();
        Profile = new ProfileFamily();
        Plan = new PlanFamily();
        Login = new LoginFamily(passwords, System.Text.Encoding.UTF8.GetBytes(settings.JwtSecret),
            nowUnix ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds()));
        All = [Tags, Plan, Profile, User, Login];
    }

    /// <summary>GET /api/tags.</summary>
    public TagsFamily Tags { get; }

    /// <summary>GET /api/user.</summary>
    public UserFamily User { get; }

    /// <summary>GET /api/profiles/:username.</summary>
    public ProfileFamily Profile { get; }

    /// <summary>The article lists, the feed, single articles and comments; a job's <see cref="ReadJob.Kind"/> says which.</summary>
    public PlanFamily Plan { get; }

    /// <summary>POST /api/users/login.</summary>
    public LoginFamily Login { get; }

    /// <summary>Every family, for the dispatcher and for preparing statements.</summary>
    public IReadOnlyList<ReadFamily> All { get; }

    /// <summary>
    /// Builds the families for <paramref name="settings"/>. <paramref name="passwords"/> lets login check passwords
    /// (without it login answers 500); <paramref name="nowUnix"/> is the clock for issued tokens, the system clock when null.
    /// </summary>
    public static ReadFamilies Create(Settings settings, IPasswords? passwords = null, Func<long>? nowUnix = null) =>
        new(settings, passwords, nowUnix);
}
