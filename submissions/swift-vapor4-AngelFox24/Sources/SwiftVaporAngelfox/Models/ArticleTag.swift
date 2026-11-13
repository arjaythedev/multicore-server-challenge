import Fluent

/// Join row between an article and a tag. As with `Follow`, the real primary
/// key is composite, so `article_id` is exposed as the model id and `tag_id`
/// is a parent. This model is mainly used for reading tags in bulk.
final class ArticleTag: Model, @unchecked Sendable {
    static let schema = "article_tags"

    @ID(custom: "article_id", generatedBy: .user)
    var id: Int?

    @Parent(key: "tag_id")
    var tag: Tag

    init() {}

    init(articleID: Int, tagID: Int) {
        self.id = articleID
        self.$tag.id = tagID
    }
}
