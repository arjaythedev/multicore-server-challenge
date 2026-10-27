using System.Globalization;

namespace Conduit;

/// <summary>A startup setting is missing or has a value we do not accept. The message names the variable.</summary>
public sealed class ConfigException : Exception {
    /// <summary>Creates the exception for <paramref name="variable"/> with a reason.</summary>
    public ConfigException(string variable, string reason)
        : base($"{variable}: {reason}") {
    }
}

/// <summary>Reads <see cref="Settings"/> from environment variables, once at startup.</summary>
public static class Config {
    /// <summary>The most Postgres connections the process may hold: the rules allow 95 of the server's 100.</summary>
    public const int MaxPgConnections = 95;

    /// <summary>
    /// Builds the settings from <paramref name="getenv"/>. A variable that is unset or empty keeps the default from
    /// <see cref="Settings"/>. A value out of range, or more Postgres connections than the rules allow, throws
    /// <see cref="ConfigException"/> naming the variable.
    /// </summary>
    public static Settings Load(Func<string, string?> getenv) {
        string? Get(string name) {
            string? v = getenv(name);
            return string.IsNullOrEmpty(v) ? null : v;
        }

        Settings s = new() {
            DatabaseUrl = Get("DATABASE_URL") ?? throw new ConfigException("DATABASE_URL", "is required"),
            JwtSecret = Get("JWT_SECRET") ?? throw new ConfigException("JWT_SECRET", "is required"),
        };

        if (Get("HOST") is { } host) {
            s = s with { Host = host };
        }

        s = Int(Get, "PORT", 1, 65535, s, (x, v) => x with { Port = v });
        s = Int(Get, "HTTP_LOOPS", 1, 64, s, (x, v) => x with { HttpLoops = v });
        s = Int(Get, "PG_READ", 1, 95, s, (x, v) => x with { PgRead = v });
        s = Int(Get, "PG_WRITE", 1, 95, s, (x, v) => x with { PgWrite = v });
        s = Int(Get, "PG_DEPTH", 1, 64, s, (x, v) => x with { PgDepth = v });
        s = Int(Get, "BATCH_MAX", 1, 4096, s, (x, v) => x with { BatchMax = v });
        s = Int(Get, "GATHER_MS", 0, 1000, s, (x, v) => x with { GatherMs = v });
        s = Int(Get, "BCRYPT_LANES", 1, 16, s, (x, v) => x with { BcryptLanes = v });
        s = Int(Get, "BCRYPT_THREADS", 1, 64, s, (x, v) => x with { BcryptThreads = v });
        s = Int(Get, "BCRYPT_WAIT_MS", 0, 60_000, s, (x, v) => x with { BcryptWaitMs = v });
        s = Int(Get, "STATS_SECONDS", 1, 3600, s, (x, v) => x with { StatsSeconds = v });
        if (s.PgRead + s.PgWrite > MaxPgConnections) {
            throw new ConfigException("PG_READ", $"PG_READ ({s.PgRead}) plus PG_WRITE ({s.PgWrite}) is {s.PgRead + s.PgWrite} connections, more than the {MaxPgConnections} the rules allow");
        }

        return s;
    }

    /// <summary>Applies integer variable <paramref name="name"/> when set. It must be plain digits from <paramref name="min"/> to <paramref name="max"/>.</summary>
    private static Settings Int(Func<string, string?> get, string name, int min, int max, Settings s, Func<Settings, int, Settings> apply) {
        string? text = get(name);
        if (text is null) {
            return s;
        }

        if (!int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out int v) || v < min || v > max) {
            throw new ConfigException(name, $"unknown value '{text}', expected an integer from {min} to {max}");
        }

        return apply(s, v);
    }
}
