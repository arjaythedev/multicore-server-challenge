# Builds the API's JSON objects from records. Records come from the prepared statements that select exactly these
# columns (Article::BY_SLUG, ArticleListing, Comment::THREAD, User::PROFILE), with the author's profile columns
# prefixed. Sequel models answer record[:column] for every selected column, computed ones included.
module ConduitJson
  extend self

  # RFC 3339 in UTC with exactly three fractional digits, truncated.
  def timestamp(time) = time.utc.iso8601(3)

  def user(user, token:)
    { email: user[:email], token:, username: user[:username], bio: user[:bio], image: user[:image] }
  end

  def profile(user, following:)
    { username: user[:username], bio: user[:bio], image: user[:image], following: }
  end

  def author(record)
    { username: record[:author_username], bio: record[:author_bio], image: record[:author_image],
      following: record[:following] }
  end

  def article(article)
    json = {
      slug: article[:slug], title: article[:title], description: article[:description],
      tagList: article[:tag_list].to_a, createdAt: timestamp(article[:created_at]),
      updatedAt: timestamp(article[:updated_at]), favorited: article[:favorited],
      favoritesCount: article[:favorites_count], author: author(article)
    }
    article.values.key?(:body) ? json.merge(body: article[:body]) : json
  end

  def comment(comment, author:)
    { id: comment[:id], createdAt: timestamp(comment[:created_at]), updatedAt: timestamp(comment[:updated_at]),
      body: comment[:body], author: }
  end
end
