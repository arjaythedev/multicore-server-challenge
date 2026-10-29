using Conduit;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Npgsql;

var dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL");
var secret = Environment.GetEnvironmentVariable("JWT_SECRET");

#if DEBUG
dbUrl ??= "postgres://conduit:conduit@127.0.0.1:5433/conduit_cs";
secret ??= "dev-secret";
#endif

if (string.IsNullOrEmpty(dbUrl) || string.IsNullOrEmpty(secret))
{
    Console.Error.WriteLine("DATABASE_URL and JWT_SECRET are required");
    return 1;
}

// Postgres allows 100 connections; stay under 95. Default: 10 per core, capped at 90.
var defaultPool = Math.Min(10 * Environment.ProcessorCount, 90);
if (!int.TryParse(EnvOr("DB_POOL_SIZE", defaultPool.ToString()), out var poolSize) || poolSize <= 0)
{
    Console.Error.WriteLine("DB_POOL_SIZE must be a positive integer");
    return 1;
}

// Automatic prepared statements: the server sends 34 distinct statements, so 64 keeps them all prepared on every connection.
if (!int.TryParse(EnvOr("DB_MAX_AUTO_PREPARE", "64"), out var maxAutoPrepare) || maxAutoPrepare < 0
    || !int.TryParse(EnvOr("DB_AUTO_PREPARE_MIN_USAGES", "5"), out var autoPrepareMinUsages) || autoPrepareMinUsages < 1)
{
    Console.Error.WriteLine("DB_MAX_AUTO_PREPARE must be 0 or more and DB_AUTO_PREPARE_MIN_USAGES 1 or more");
    return 1;
}

// Check our bcrypt against known answers now (every lane count), not on the first login.
try
{
    Bcrypt.SelfTest();
}
catch (Exception e)
{
    Console.Error.WriteLine($"bcrypt is not usable: {e.Message}");
    return 1;
}

var host = EnvOr("HOST", "127.0.0.1");
var port = EnvOr("PORT", "3000");

var builder = WebApplication.CreateSlimBuilder(args);

#if DEBUG
// Local testing: one line per request (Api.Handle), timestamps, Npgsql's SQL logs with LOG_SQL=1.
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.TimestampFormat = "HH:mm:ss.fff ";
});
builder.Logging.SetMinimumLevel(LogLevel.Information);
builder.Logging.AddFilter("Microsoft", LogLevel.Warning);
if (Environment.GetEnvironmentVariable("LOG_SQL") == "1") builder.Logging.AddFilter("Npgsql.Command", LogLevel.Debug);
#else
builder.Logging.SetMinimumLevel(LogLevel.Warning); // no per-request logging
#endif

builder.WebHost.UseUrls($"http://{host}:{port}");
builder.WebHost.ConfigureKestrel(o =>
{
    o.AddServerHeader = false;
    o.ConfigureEndpointDefaults(l => l.Protocols = HttpProtocols.Http1); // HTTP/1.1 only: no h2c upgrade checks
});

builder.Services.AddSingleton(sp => Db.Create(dbUrl, poolSize, maxAutoPrepare, autoPrepareMinUsages, sp.GetRequiredService<ILoggerFactory>()));
builder.Services.AddSingleton(new Auth(secret));
builder.Services.AddSingleton<Api>();

var app = builder.Build();
var api = app.Services.GetRequiredService<Api>();

#if DEBUG
// Say which database this run uses and check it right away, instead of failing on the first request.
var dbUri = new Uri(dbUrl);
app.Logger.LogInformation("database {Host}:{Port}{Path} as {User}, pool {Pool}",
    dbUri.Host, dbUri.Port, dbUri.AbsolutePath, dbUri.UserInfo.Split(':')[0], poolSize);
try
{
    await using var conn = await app.Services.GetRequiredService<NpgsqlDataSource>().OpenConnectionAsync();
    app.Logger.LogInformation("database connection OK (PostgreSQL {Version})", conn.PostgreSqlVersion);
}
catch (Exception e)
{
    app.Logger.LogError("database connection FAILED: {Message}", e.Message);
}
#endif

// No routing framework: one request delegate that dispatches by method and path itself.
app.Run(api.Handle);

Console.WriteLine($"conduit (csharp) listening on http://{host}:{port}, pool {poolSize}");
await app.RunAsync();
return 0;

// Config comes from the environment (SPEC.md "Runtime contract").
static string EnvOr(string name, string fallback)
{
    return Environment.GetEnvironmentVariable(name) is { Length: > 0 } v ? v : fallback;
}
