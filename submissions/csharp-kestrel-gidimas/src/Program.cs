using System.Threading.RateLimiting;
using Conduit;
using Conduit.Auth;
using Conduit.Data;
using Conduit.Endpoints;
using Conduit.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Diagnostics;
using Dapper;
using Microsoft.AspNetCore.RateLimiting;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

// Runtime contract (SPEC.md): DATABASE_URL, JWT_SECRET, HOST and PORT come from the environment.
var databaseUrl = config["DATABASE_URL"] ?? throw new InvalidOperationException("DATABASE_URL is not set");
var jwtSecret = config["JWT_SECRET"] ?? throw new InvalidOperationException("JWT_SECRET is not set");
builder.WebHost.UseUrls($"http://{config["HOST"] ?? "0.0.0.0"}:{config["PORT"] ?? "80"}");
builder.WebHost.ConfigureKestrel(kestrel => kestrel.AddServerHeader = false);

// One pooled data source for the app; endpoints open a connection per request and Dapper runs the SQL.
builder.Services.AddSingleton(NpgsqlDataSource.Create(ConnectionStrings.FromUrl(databaseUrl, config.GetValue("DB_POOL_SIZE", 32), config.GetValue("DB_MULTIPLEXING", true))));
DefaultTypeMap.MatchNamesWithUnderscores = true;

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default);
    options.SerializerOptions.Converters.Add(new TimestampConverter());
});

builder.Services.AddSingleton(new TokenService(jwtSecret));
builder.Services
    .AddAuthentication(TokenAuthenticationHandler.SchemeName)
    .AddScheme<AuthenticationSchemeOptions, TokenAuthenticationHandler>(TokenAuthenticationHandler.SchemeName, null);
builder.Services.AddAuthorization();

builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status503ServiceUnavailable;
    options.OnRejected = (context, cancellationToken) =>
    {
        context.HttpContext.Response.Headers.RetryAfter = "1";
        return new ValueTask(context.HttpContext.Response.WriteAsJsonAsync(
            ApiErrors.Body("server busy, retry shortly"), AppJsonContext.Default.ErrorResponse, cancellationToken: cancellationToken));
    };
    options.AddConcurrencyLimiter(RateLimits.PasswordHashing, limiter =>
    {
        // Measured on 8 cores: half the cores shed a third of logins at peak, all of them starve the other requests.
        limiter.PermitLimit = config.GetValue("PASSWORD_HASH_CONCURRENCY", Math.Max(1, Environment.ProcessorCount * 3 / 4));
        limiter.QueueLimit = config.GetValue("PASSWORD_HASH_QUEUE", 64);
        limiter.QueueProcessingOrder = QueueProcessingOrder.OldestFirst;
    });
});

// Malformed or missing JSON bodies fail model binding with BadHttpRequestException; SPEC.md answers those with 422.
builder.Services.Configure<RouteHandlerOptions>(options => options.ThrowOnBadRequest = true);

var app = builder.Build();

app.UseExceptionHandler(errors => errors.Run(context =>
{
    var badRequest = context.Features.Get<IExceptionHandlerFeature>()?.Error is BadHttpRequestException;
    context.Response.StatusCode = badRequest ? StatusCodes.Status422UnprocessableEntity : StatusCodes.Status500InternalServerError;
    return context.Response.WriteAsJsonAsync(
        ApiErrors.Body(badRequest ? "invalid request body" : "internal error"), AppJsonContext.Default.ErrorResponse);
}));

app.UseAuthentication();
app.UseAuthorization();
app.UseRateLimiter();

var api = app.MapGroup("/api");
api.MapUserEndpoints();
api.MapProfileEndpoints();
api.MapArticleEndpoints();
api.MapCommentEndpoints();
api.MapTagEndpoints();
app.MapFallback(() => ApiErrors.NotFound());

app.Run();
