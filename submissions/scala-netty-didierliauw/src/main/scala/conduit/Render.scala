package conduit

import java.nio.charset.StandardCharsets.UTF_8

/** Response bodies, written as compact JSON from Postgres's rows (`SPEC.md`, "Formats"). */
object Render:
  private def bytes(s: String) = s.getBytes(UTF_8)

  private val ArticleOpen = bytes("""{"article":""")
  private val ArticlesOpen = bytes("""{"articles":[""")
  private val ArticlesCount = bytes("""],"articlesCount":""")
  private val CommentOpen = bytes("""{"comment":""")
  private val CommentsOpen = bytes("""{"comments":[""")
  private val ProfileOpen = bytes("""{"profile":""")
  private val UserOpen = bytes("""{"user":""")
  private val TagsOpen = bytes("""{"tags":[""")
  private val ErrorOpen = bytes("""{"errors":{"body":[""")
  private val SlugKey = bytes("""{"slug":""")
  private val TitleKey = bytes(""","title":""")
  private val DescriptionKey = bytes(""","description":""")
  private val BodyKey = bytes(""","body":""")
  private val TagListKey = bytes(""","tagList":""")
  private val CreatedAtKey = bytes(""","createdAt":""")
  private val UpdatedAtKey = bytes(""","updatedAt":""")
  private val FavoritedKey = bytes(""","favorited":""")
  private val FavoritesCountKey = bytes(""","favoritesCount":""")
  private val AuthorKey = bytes(""","author":""")
  private val UsernameKey = bytes("""{"username":""")
  private val BioKey = bytes(""","bio":""")
  private val ImageKey = bytes(""","image":""")
  private val FollowingKey = bytes(""","following":""")
  private val IdKey = bytes("""{"id":""")
  private val EmailKey = bytes("""{"email":""")
  private val TokenKey = bytes(""","token":""")
  private val UserUsernameKey = bytes(""","username":""")

  def articleOpen(out: Out): Unit = out.bytes(ArticleOpen)
  def articlesOpen(out: Out): Unit = out.bytes(ArticlesOpen)
  def articlesClose(out: Out, count: Long): Unit = out.bytes(ArticlesCount).long(count).byte('}')
  def commentOpen(out: Out): Unit = out.bytes(CommentOpen)
  def commentsOpen(out: Out): Unit = out.bytes(CommentsOpen)
  def tagsOpen(out: Out): Unit = out.bytes(TagsOpen)
  def close(out: Out): Unit = out.byte('}')
  def arrayClose(out: Out): Unit = out.byte(']').byte('}')

  /** An article from the row's columns at `at` on: slug, title, description, body (`withBody`), created_at,
    * updated_at, tag_list, favorites_count, favorited, then the author's username, bio, image and following.
    */
  def article(out: Out, row: PgRow, at: Int, withBody: Boolean): Unit =
    out.bytes(SlugKey)
    row.text(at, out)
    out.bytes(TitleKey)
    row.text(at + 1, out)
    out.bytes(DescriptionKey)
    row.text(at + 2, out)
    var i = at + 3
    if withBody then
      out.bytes(BodyKey)
      row.text(i, out)
      i += 1
    out.bytes(TagListKey)
    row.textArray(i + 2, out)
    out.bytes(CreatedAtKey)
    row.timestamp(i, out)
    out.bytes(UpdatedAtKey)
    row.timestamp(i + 1, out)
    out.bytes(FavoritedKey).bool(row.bool(i + 4))
    out.bytes(FavoritesCountKey).long(row.int8(i + 3))
    out.bytes(AuthorKey)
    profile(out, row, i + 5, row.bool(i + 8))
    out.byte('}')

  /** What [[article]] writes of an article that is the same for every viewer, from the row's slug, title,
    * description, created_at, updated_at, tag_list, favorites_count, username, bio and image at `at` on: up to
    * `favorited`'s value, then (from the length it returns) up to `following`'s. A viewer's article is the first part,
    * its `favorited`, the second, its `following`, then `}}`.
    */
  def sharedArticle(out: Out, row: PgRow, at: Int): Int =
    out.bytes(SlugKey)
    row.text(at, out)
    out.bytes(TitleKey)
    row.text(at + 1, out)
    out.bytes(DescriptionKey)
    row.text(at + 2, out)
    out.bytes(TagListKey)
    row.textArray(at + 5, out)
    out.bytes(CreatedAtKey)
    row.timestamp(at + 3, out)
    out.bytes(UpdatedAtKey)
    row.timestamp(at + 4, out)
    out.bytes(FavoritedKey)
    val split = out.length
    out.bytes(FavoritesCountKey).long(row.int8(at + 6))
    out.bytes(AuthorKey).bytes(UsernameKey)
    row.text(at + 7, out)
    out.bytes(BioKey)
    row.textOrNull(at + 8, out)
    out.bytes(ImageKey)
    row.textOrNull(at + 9, out)
    out.bytes(FollowingKey)
    split

  /** A profile from the row's username, bio and image at `at` on. */
  def profile(out: Out, row: PgRow, at: Int, following: Boolean): Unit =
    out.bytes(UsernameKey)
    row.text(at, out)
    out.bytes(BioKey)
    row.textOrNull(at + 1, out)
    out.bytes(ImageKey)
    row.textOrNull(at + 2, out)
    out.bytes(FollowingKey).bool(following)
    out.byte('}')

  def profileResponse(out: Out, row: PgRow, following: Boolean): Unit =
    out.bytes(ProfileOpen)
    profile(out, row, 0, following)
    out.byte('}')

  /** A comment from the row's id, body, created_at, updated_at, username, bio and image, with `following`. */
  def comment(out: Out, row: PgRow, following: Boolean): Unit =
    out.bytes(IdKey).long(row.int8(0))
    out.bytes(CreatedAtKey)
    row.timestamp(2, out)
    out.bytes(UpdatedAtKey)
    row.timestamp(3, out)
    out.bytes(BodyKey)
    row.text(1, out)
    out.bytes(AuthorKey)
    profile(out, row, 4, following)
    out.byte('}')

  /** A user, from the row's id, username, email, bio and image, with `token`. */
  def user(out: Out, row: PgRow, token: String): Unit =
    out.bytes(UserOpen)
    out.bytes(EmailKey)
    row.text(2, out)
    out.bytes(TokenKey).jsonString(token)
    out.bytes(UserUsernameKey)
    row.text(1, out)
    out.bytes(BioKey)
    row.textOrNull(3, out)
    out.bytes(ImageKey)
    row.textOrNull(4, out)
    out.byte('}').byte('}')

  def error(out: Out, message: String): Unit =
    out.reset()
    out.bytes(ErrorOpen).jsonString(message).byte(']').byte('}').byte('}')
