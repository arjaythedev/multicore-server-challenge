import Fluent
import Vapor

struct TagController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("api", "tags").get(use: self.index)
    }

    @Sendable
    func index(req: Request) async throws -> TagsResponse {
        let tags = try await Tag.query(on: req.db)
            .sort(\.$name)
            .all()
        return TagsResponse(tags: tags.map(\.name))
    }
}
