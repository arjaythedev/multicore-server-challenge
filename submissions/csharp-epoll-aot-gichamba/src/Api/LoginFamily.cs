using Conduit.Auth;
using Conduit.Dispatch;
using Conduit.Json;
using Conduit.Pg;

namespace Conduit.Api;

/// <summary>The password a login presented, and the user row the read found. Set as <see cref="ReadJob.State"/>.</summary>
public sealed class LoginState {
    /// <summary>Creates the state for a request that presented <paramref name="password"/> (UTF-8 bytes).</summary>
    public LoginState(byte[] password) => Password = password;

    /// <summary>The presented password.</summary>
    public byte[] Password { get; }

    /// <summary>The user id from the row.</summary>
    internal long Id;
    /// <summary>The username from the row.</summary>
    internal string Username = "";
    /// <summary>The email from the row.</summary>
    internal string Email = "";
    /// <summary>The bio, or null when the column is NULL.</summary>
    internal string? Bio;
    /// <summary>The image URL, or null when the column is NULL.</summary>
    internal string? Image;
    /// <summary>The stored bcrypt hash.</summary>
    internal string? Hash;
}

/// <summary>
/// POST /api/users/login. The user row is read by email through the read dispatcher; then the password is checked with
/// bcrypt on a bcrypt thread, and only then is the answer sent. No row or a wrong password is 401.
/// </summary>
public sealed class LoginFamily : ReadFamily {
    /// <summary>Checks the password; null makes every login answer 500.</summary>
    private readonly IPasswords? _passwords;
    /// <summary>The token signing key.</summary>
    private readonly byte[] _key;
    /// <summary>Clock in Unix seconds for the token claims.</summary>
    private readonly Func<long> _nowUnix;

    /// <summary>
    /// Creates the family. <paramref name="passwords"/> checks the password; with null every login answers 500.
    /// <paramref name="key"/> signs the token and <paramref name="nowUnix"/> is the clock for its claims.
    /// </summary>
    public LoginFamily(IPasswords? passwords, byte[] key, Func<long> nowUnix) : base(ReadKinds.Login, "login") {
        _passwords = passwords;
        _key = key;
        _nowUnix = nowUnix;
    }

    /// <inheritdoc />
    public override string Sql =>
        "SELECT r.i, x.id, x.username, x.email, x.bio, x.image, x.password_hash FROM unnest($1::int8[], $2::text[]) AS r(i, k) " +
        "CROSS JOIN LATERAL (SELECT u.id, u.username, u.email, u.bio, u.image, u.password_hash FROM users u WHERE u.email = r.k) x";

    /// <inheritdoc />
    public override uint[] ParamOids => [PgOid.Int8Array, PgOid.TextArray];

    /// <inheritdoc />
    public override void Encode(PgParams p, ReadOnlySpan<ReadJob> jobs) {
        AddIndexes(p, jobs.Length);
        AddKeys(p, jobs);
    }

    /// <inheritdoc />
    public override void OnRow(ReadJob job, in PgRow row) {
        if (job.Rows++ > 0 || job.State is not LoginState st) {
            return;
        }

        st.Id = PgBinary.ReadInt8(row[1]);
        st.Username = PgBinary.ReadText(row[2]);
        st.Email = PgBinary.ReadText(row[3]);
        st.Bio = row.IsNull(4) ? null : PgBinary.ReadText(row[4]);
        st.Image = row.IsNull(5) ? null : PgBinary.ReadText(row[5]);
        st.Hash = PgBinary.ReadText(row[6]);
    }

    /// <inheritdoc />
    public override int Complete(ReadJob job) {
        if (_passwords is null || job.State is not LoginState st) {
            return Error(job, 500, "internal error");
        }

        if (job.Rows == 0) {
            return Error(job, 401, "invalid email or password");
        }

        _passwords.Verify(st.Password, st.Hash!, ok => Answer(job, st, ok));
        return Deferred;
    }

    /// <summary>Runs on a bcrypt thread. Sends the user with a token for a good password, 401 otherwise. A failure resets the response and answers 500.</summary>
    private void Answer(ReadJob job, LoginState st, bool ok) {
        try {
            if (!ok) {
                job.Fail(401, "invalid email or password");
                return;
            }
            JsonWriter w = job.Out.Body;
            w.StartObject();
            w.PropertyName("user"u8);
            w.StartObject();
            w.PropertyName("email"u8);
            w.WriteString(st.Email);
            w.PropertyName("token"u8);
            w.WriteString(Jwt.Sign(st.Id, _nowUnix(), _key));
            w.PropertyName("username"u8);
            w.WriteString(st.Username);
            w.PropertyName("bio"u8);
            if (st.Bio is null) {
                w.WriteNull();
            } else {
                w.WriteString(st.Bio);
            }

            w.PropertyName("image"u8);
            if (st.Image is null) {
                w.WriteNull();
            } else {
                w.WriteString(st.Image);
            }

            w.EndObject();
            w.EndObject();
            job.Respond(200);
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
