import Fluent
import FluentPostgresDriver
import Foundation
import JWT
import NIOSSL
import Vapor

/// Configures the application with Vapor + Fluent defaults. There is no
/// caching or query tuning here on purpose: this is the out-of-the-box baseline.
func configure(_ app: Application) async throws {
    // RealWorld errors always use {"errors":{"body":[...]}}. This has to sit
    // inside Vapor's default ErrorMiddleware so it sees thrown errors before
    // that middleware converts them to its own JSON shape.
    app.middleware.use(APIErrorMiddleware(), at: .end)

    // The challenge requires bcrypt cost 10.
    app.passwords.use(.bcrypt(cost: 10))

    let jwtSecret = Environment.get("JWT_SECRET") ?? "conduit-dev-secret"
    app.jwt.signers.use(.hs256(key: jwtSecret))

    app.databases.use(
        DatabaseConfigurationFactory.postgres(configuration: try postgresConfiguration()),
        as: .psql
    )

    app.migrations.add(CreateUser())
    app.migrations.add(CreateTag())
    app.migrations.add(CreateArticle())
    app.migrations.add(CreateFollow())
    app.migrations.add(CreateArticleTag())
    app.migrations.add(CreateFavorite())
    app.migrations.add(CreateComment())

    // The challenge starts the binary without CLI arguments and supplies
    // HOST/PORT (and DATABASE_URL/JWT_SECRET) through the environment.
    if let hostname = Environment.get("HOST") {
        app.http.server.configuration.hostname = hostname
    }
    if let port = Environment.get("PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    try routes(app)
}

private func postgresConfiguration() throws -> SQLPostgresConfiguration {
    // The benchmark contract is a single DATABASE_URL. Disable TLS for it
    // because Postgres runs on the same box.
    if let rawURL = Environment.get("DATABASE_URL"), let url = URL(string: rawURL) {
        return SQLPostgresConfiguration(
            hostname: url.host ?? "localhost",
            port: url.port ?? SQLPostgresConfiguration.ianaPortNumber,
            username: url.user ?? "conduit",
            password: url.password,
            database: url.path.split(separator: "/").last.map(String.init),
            tls: .disable
        )
    }

    // Local development / docker-compose defaults from the Vapor template.
    return SQLPostgresConfiguration(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: Environment.get("DATABASE_NAME") ?? "vapor_database",
        tls: .prefer(try .init(configuration: .clientDefault))
    )
}
