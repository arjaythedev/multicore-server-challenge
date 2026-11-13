import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: UserController())
    try app.register(collection: ProfileController())
    try app.register(collection: ArticleController())
    try app.register(collection: CommentController())
    try app.register(collection: TagController())
}
