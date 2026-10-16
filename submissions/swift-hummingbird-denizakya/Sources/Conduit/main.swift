// Conduit (RealWorld) API server in Swift + Hummingbird, for the multicore server challenge (SPEC.md).
import Crypto
import Foundation
import Hummingbird
import HummingbirdCore
import HTTPTypes
import PostgresNIO

let env = ProcessInfo.processInfo.environment
func envOr(_ name: String, _ fallback: String) -> String {
    guard let v = env[name], !v.isEmpty else { return fallback }
    return v
}

guard let dbURLString = env["DATABASE_URL"], !dbURLString.isEmpty,
      let jwtSecret = env["JWT_SECRET"], !jwtSecret.isEmpty else {
    FileHandle.standardError.write("DATABASE_URL and JWT_SECRET are required\n".data(using: .utf8)!)
    exit(1)
}
guard let dbURL = URL(string: dbURLString), let dbHost = dbURL.host else {
    FileHandle.standardError.write("cannot parse DATABASE_URL: \(dbURLString)\n".data(using: .utf8)!)
    exit(1)
}
let poolSize = Int(envOr("DB_POOL_SIZE", "10")) ?? 10

var dbConfig = PostgresClient.Configuration(
    host: dbHost,
    port: dbURL.port ?? 5432,
    username: dbURL.user ?? "conduit",
    password: dbURL.password,
    database: dbURL.path.split(separator: "/").last.map(String.init),
    tls: .disable
)
dbConfig.options.maximumConnections = poolSize
let db = PostgresClient(configuration: dbConfig)

let app = App(db: db, secret: SymmetricKey(data: Data(jwtSecret.utf8)))

let router = Router(context: BasicRequestContext.self)
router.post("api/users") { request, ctx in try await handle(request) { try await app.register(request, ctx) } }
router.post("api/users/login") { request, ctx in try await handle(request) { try await app.login(request, ctx) } }
router.get("api/user") { request, ctx in try await handle(request) { try await app.currentUser(request, ctx) } }
router.put("api/user") { request, ctx in try await handle(request) { try await app.updateUser(request, ctx) } }

router.get("api/profiles/:username") { request, ctx in try await handle(request) { try await app.getProfile(request, ctx) } }
router.post("api/profiles/:username/follow") { request, ctx in try await handle(request) { try await app.follow(request, ctx, follow: true) } }
router.delete("api/profiles/:username/follow") { request, ctx in try await handle(request) { try await app.follow(request, ctx, follow: false) } }

router.get("api/articles") { request, ctx in try await handle(request) { try await app.listArticles(request, ctx) } }
router.get("api/articles/feed") { request, ctx in try await handle(request) { try await app.feed(request, ctx) } }
router.post("api/articles") { request, ctx in try await handle(request) { try await app.createArticle(request, ctx) } }
router.get("api/articles/:slug") { request, ctx in try await handle(request) { try await app.getArticle(request, ctx) } }
router.put("api/articles/:slug") { request, ctx in try await handle(request) { try await app.updateArticleHandler(request, ctx) } }
router.delete("api/articles/:slug") { request, ctx in try await handle(request) { try await app.deleteArticle(request, ctx) } }
router.post("api/articles/:slug/favorite") { request, ctx in try await handle(request) { try await app.favorite(request, ctx, fav: true) } }
router.delete("api/articles/:slug/favorite") { request, ctx in try await handle(request) { try await app.favorite(request, ctx, fav: false) } }
router.get("api/articles/:slug/comments") { request, ctx in try await handle(request) { try await app.listComments(request, ctx) } }
router.post("api/articles/:slug/comments") { request, ctx in try await handle(request) { try await app.createComment(request, ctx) } }
router.delete("api/articles/:slug/comments/:id") { request, ctx in try await handle(request) { try await app.deleteComment(request, ctx) } }

router.get("api/tags") { request, ctx in try await handle(request) { try await app.tags(request, ctx) } }

// Anything else (unknown path, or a known path with another method) is a JSON 404.
for method: HTTPRequest.Method in [.get, .post, .put, .delete, .patch, .head, .options, .trace, .connect] {
    router.on("**", method: method) { _, _ in errorResponse(.notFound, "not found") }
}

let server = Application(
    router: router,
    server: .http1(configuration: .init(idleTimeout: .seconds(75))),
    configuration: .init(address: .hostname(envOr("HOST", "127.0.0.1"), port: Int(envOr("PORT", "3000")) ?? 3000)),
    services: [db]
)
print("conduit (swift/hummingbird) listening on \(envOr("HOST", "127.0.0.1")):\(envOr("PORT", "3000")), pool \(poolSize)")
try await server.runService()
