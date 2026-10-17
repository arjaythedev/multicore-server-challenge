using System;
using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Server.Kestrel.Core;

namespace Conduit;

public static class Program
{
    public static void Main(string[] args)
    {
        string dbUrl = Environment.GetEnvironmentVariable("DATABASE_URL") ?? "";
        string secret = Environment.GetEnvironmentVariable("JWT_SECRET") ?? "";
        if (dbUrl.Length == 0 || secret.Length == 0)
        {
            Console.Error.WriteLine("DATABASE_URL and JWT_SECRET are required");
            Environment.Exit(1);
        }
        string host = Env("HOST", "127.0.0.1");
        int port = int.Parse(Env("PORT", "3000"));
        int cores = Environment.ProcessorCount;
        int poolSize = int.Parse(Env("DB_POOL_SIZE", (4 * cores).ToString()));
        // One per two cores. Under load jobs queue up and a worker runs up to four interleaved, so fewer threads
        // spend less CPU per hash; but when every core is busy each thread gets only its share of the CPU, and
        // logins grow with the cores: at 4 cores one thread let two thirds of the logins fail, two kept up.
        int bcryptThreads = int.Parse(Env("BCRYPT_THREADS", Math.Max(1, cores / 2).ToString()));
        bool multiplexing = Env("DB_MULTIPLEXING", "1") != "0";

        Jwt.Init(secret);
        Db.Init(dbUrl, poolSize, multiplexing);
        Passwords.Init(bcryptThreads);

        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions { Args = args });
        builder.WebHost.UseKestrelCore().ConfigureKestrel(o =>
        {
            o.AddServerHeader = false;
            // Browsers (and the load generator's users) keep one idle connection for up to a 70 s think time,
            // and Nginx's upstream keep-alive is 60 s: idle connections stay open well past both.
            o.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(10);
            o.Limits.MaxRequestBodySize = 1 << 20;
            o.ConfigureEndpointDefaults(l => l.Protocols = HttpProtocols.Http1);
            if (IPAddress.TryParse(host, out var ip)) o.Listen(ip, port);
            else if (host == "localhost") o.ListenLocalhost(port);
            else o.ListenAnyIP(port);
        });

        var app = builder.Build();
        app.Run(Router.Handle);
        Console.WriteLine($"conduit (c#) listening on {host}:{port}, db pool {poolSize}{(multiplexing ? " multiplexed" : "")}, bcrypt threads {bcryptThreads}");
        app.Run();
    }

    static string Env(string name, string fallback)
    {
        string? v = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrEmpty(v) ? fallback : v;
    }
}
