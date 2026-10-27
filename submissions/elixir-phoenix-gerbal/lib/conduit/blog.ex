defmodule Conduit.Blog do
  @moduledoc """
  Articles, the personal feed, favorites, comments and tags.

  Functions that return articles or comments take the viewer's id (nil when anonymous) to fill in `favorited` and
  the author's `following`.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Conduit.Accounts.User
  alias Conduit.Blog.Article
  alias Conduit.Blog.Comment
  alias Conduit.Blog.Favorite
  alias Conduit.Blog.Tag
  alias Conduit.Profiles.Follow
  alias Conduit.Repo
  alias Conduit.Types.PlainInteger

  # articlesCount stops counting here: an exact total of a big list costs a scan, and the UI only pages through it.
  @count_cap 1000
  @max_comments 100

  # Lists leave out the body, which only a single article shows, authors leave out email and password hash, and
  # comments leave out their article and author ids.
  @summary_fields [:id, :slug, :title, :description, :author_id, :created_at, :updated_at]
  @article_fields [:body | @summary_fields]
  @author_fields [:id, :username, :bio, :image]
  @comment_fields [:id, :body, :created_at, :updated_at]

  ## Article lists

  @doc """
  Lists articles newest first, with the total count (capped at #{@count_cap}).

  `params` takes `limit` (1..100, default 20), `offset` (default 0) and one of the filters `tag`, `author` and
  `favorited` (the first non-empty one applies). Invalid paging is `{:error, changeset}`.
  """
  @spec list_articles(map(), pos_integer() | nil) ::
          {:ok, %{articles: [Article.t()], count: non_neg_integer()}} | {:error, Ecto.Changeset.t()}
  def list_articles(params, viewer_id) do
    with {:ok, opts} <- list_options(params) do
      matching = opts |> filter() |> matching_ids()
      count = count_query(matching)

      page_query =
        from i in subquery(matching),
          order_by: [desc: i.id],
          limit: ^opts.limit,
          offset: ^opts.offset,
          select: {i.id, subquery(count)}

      page = list_page(page_query, count, opts.offset, viewer_id)
      {:ok, page}
    end
  end

  @doc "Lists the newest articles by authors `viewer_id` follows, with the same paging as `list_articles/2`."
  @spec feed(map(), pos_integer()) ::
          {:ok, %{articles: [Article.t()], count: non_neg_integer()}} | {:error, Ecto.Changeset.t()}
  def feed(params, viewer_id) do
    with {:ok, %{limit: limit, offset: offset}} <- list_options(params) do
      # Each followed author's newest `limit + offset` articles are enough to fill the page, so the newest page is
      # merged from short index walks instead of sorting everything the followed authors ever wrote.
      latest_by_author =
        from a in Article,
          where: a.author_id == parent_as(:follow).followee_id,
          order_by: [desc: a.id],
          limit: ^(limit + offset),
          select: %{id: a.id}

      followees = from f in Follow, where: f.follower_id == ^viewer_id, select: f.followee_id
      followed = from a in Article, where: a.author_id in subquery(followees), select: %{id: a.id}
      count = count_query(followed)

      page_query =
        from f in Follow,
          as: :follow,
          where: f.follower_id == ^viewer_id,
          inner_lateral_join: a in subquery(latest_by_author),
          on: true,
          order_by: [desc: a.id],
          limit: ^limit,
          offset: ^offset,
          select: {a.id, subquery(count)}

      page = list_page(page_query, count, offset, viewer_id)
      {:ok, page}
    end
  end

  defp list_options(params) do
    types = %{limit: PlainInteger, offset: PlainInteger, tag: :string, author: :string, favorited: :string}

    # Present-but-empty `limit` or `offset` is invalid, so nothing counts as empty while casting.
    {%{limit: 20, offset: 0}, types}
    |> cast(params, Map.keys(types), empty_values: [])
    |> validate_number(:limit, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    # The feed limits each followed author to `limit + offset` articles, which must fit in a bigint.
    |> validate_number(:offset, less_than_or_equal_to: 2 ** 63 - 101)
    |> apply_action(:list)
  end

  defp filter(opts) do
    Enum.find_value([:tag, :author, :favorited], fn key ->
      value = Map.get(opts, key)

      if value not in [nil, ""] do
        {key, value}
      end
    end)
  end

  # The ids of the articles a filter matches, read from the narrowest index: a tag's or a user's favorites' entries
  # in their join table walk (tag_id, article_id) and (user_id, article_id) newest first, without joining `articles`.
  # An unknown tag or username matches nothing.
  defp matching_ids(nil), do: from(a in Article, select: %{id: a.id})

  defp matching_ids({:tag, name}) do
    tag_id = from t in Tag, where: t.name == ^name, select: t.id
    from at in "article_tags", where: at.tag_id == subquery(tag_id), select: %{id: at.article_id}
  end

  defp matching_ids({:author, username}) do
    from a in Article, where: a.author_id == subquery(user_id(username)), select: %{id: a.id}
  end

  defp matching_ids({:favorited, username}) do
    from f in Favorite, where: f.user_id == subquery(user_id(username)), select: %{id: f.article_id}
  end

  defp user_id(username), do: from(u in User, where: u.username == ^username, select: u.id)

  # The capped count of the articles a list matches, as a query for a scalar subquery.
  defp count_query(matching), do: from(m in subquery(limit(matching, @count_cap)), select: count())

  # Lists pick a page of ids first and then load just those articles, so the per-article subqueries for counts and
  # the viewer run for the page only. Each id comes with the capped count (`page` selects `{id, subquery(count)}`), an
  # uncorrelated scalar subquery that Postgres runs once. The articles are a second statement: with the page's
  # `LIMIT` and `OFFSET` as parameters Postgres can't reuse a generic plan for the big article query, and planning it
  # on every call cost more than running it. Loaded by an id list, it is planned once per connection.
  defp list_page(page_query, count, offset, viewer_id) do
    case Repo.all(page_query) do
      [] when offset == 0 ->
        %{articles: [], count: 0}

      # Past the last page there is no row to carry the count.
      [] ->
        %{articles: [], count: Repo.one(count)}

      [{_id, count} | _] = rows ->
        ids = Enum.map(rows, &elem(&1, 0))

        articles =
          viewer_id
          |> articles_query(@summary_fields)
          |> where([a], a.id in ^ids)
          |> order_by([a], desc: a.id)
          |> Repo.all()

        %{articles: articles, count: count}
    end
  end

  # Articles with their author, tag names, favorite count, and the viewer's `favorited` and `following`.
  #
  # Tag names are aggregated in the same query rather than preloaded, which would cost a second round trip.
  defp articles_query(viewer_id, fields \\ @article_fields) do
    favorites = from f in Favorite, where: f.article_id == parent_as(:article).id

    # Each tag's name by primary key. `limit: 1` keeps Postgres from flattening the lateral join into a plain join with
    # `tags`, which it planned as a hash join over a scan of all the tags, once per article: that made the tag names
    # 70% of a list page's article statement (0.36 -> 0.23 ms per page with the lookups, in pgbench).
    tag_name = from t in Tag, where: t.id == parent_as(:article_tag).tag_id, limit: 1, select: %{name: t.name}

    tag_names =
      from at in "article_tags",
        as: :article_tag,
        inner_lateral_join: t in subquery(tag_name),
        on: true,
        where: at.article_id == parent_as(:article).id,
        select: fragment("coalesce(array_agg(? ORDER BY ?), '{}')", t.name, t.name)

    from a in Article,
      as: :article,
      join: u in assoc(a, :author),
      as: :author,
      # The viewer's favorite of the article and follow of its author, if any: at most one row each (primary keys).
      left_join: vf in Favorite,
      on: vf.article_id == a.id and vf.user_id == ^(viewer_id || 0),
      left_join: vfo in Follow,
      on: vfo.followee_id == u.id and vfo.follower_id == ^(viewer_id || 0),
      select:
        merge(struct(a, ^fields), %{
          tag_list: subquery(tag_names),
          favorites_count: subquery(from f in favorites, select: count()),
          favorited: not is_nil(vf.user_id),
          author: merge(struct(u, @author_fields), %{following: not is_nil(vfo.follower_id)})
        })
  end

  ## Single articles

  @doc "Gets an article by slug."
  @spec get_article(String.t(), pos_integer() | nil) :: {:ok, Article.t()} | {:error, :not_found}
  def get_article(slug, viewer_id) do
    viewer_id
    |> articles_query()
    |> where([a], a.slug == ^slug)
    |> Repo.one()
    |> fetch()
  end

  # Writes return the article as it is after them. It can be gone by then, deleted by its author in another request.
  defp reload_article(id, viewer_id) do
    viewer_id
    |> articles_query()
    |> where([a], a.id == ^id)
    |> Repo.one()
    |> fetch()
  end

  @doc "Publishes an article by `author_id`, creating any tags that don't exist yet."
  @spec create_article(pos_integer(), map()) :: {:ok, Article.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def create_article(author_id, attrs) do
    changeset = Article.create_changeset(%Article{author_id: author_id}, attrs)
    names = (get_field(changeset, :tag_list) || []) |> Enum.uniq() |> Enum.sort()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:article, changeset)
      |> link_tags(names)

    case Repo.transact(multi) do
      {:ok, %{article: article}} -> reload_article(article.id, author_id)
      {:error, :article, changeset, _changes} -> {:error, changeset}
    end
  end

  # Upserts the tags and links them to the new article in one statement each, as SPEC.md's SQL does, rather than
  # an insert per tag. Names are sorted so concurrent upserts take row locks in the same order.
  defp link_tags(multi, []), do: multi

  defp link_tags(multi, names) do
    rows = Enum.map(names, &%{name: &1})

    multi
    |> Ecto.Multi.insert_all(:tags, Tag, rows, on_conflict: :nothing, conflict_target: :name)
    |> Ecto.Multi.insert_all(:article_tags, "article_tags", fn %{article: article} ->
      from t in Tag, where: t.name in ^names, select: %{article_id: type(^article.id, :id), tag_id: t.id}
    end)
  end

  @doc "Edits an article. Only its author may."
  @spec update_article(String.t(), pos_integer(), map()) ::
          {:ok, Article.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def update_article(slug, user_id, attrs) do
    with {:ok, article} <- fetch_own_article(slug, user_id),
         # force: an edit always bumps updated_at, even when nothing else changed.
         {:ok, article} <-
           article |> Article.update_changeset(attrs) |> Repo.update(force: true, stale_error_field: :id) |> gone() do
      reload_article(article.id, user_id)
    end
  end

  @doc "Deletes an article, with its comments, tags links and favorites. Only its author may."
  @spec delete_article(String.t(), pos_integer()) :: :ok | {:error, :not_found | :forbidden}
  def delete_article(slug, user_id) do
    with {:ok, article} <- fetch_own_article(slug, user_id),
         # A concurrent delete that got there first leaves nothing to delete, which is still a 204 in SPEC.md.
         {:ok, _article} <- Repo.delete(article, allow_stale: true) do
      :ok
    end
  end

  defp fetch_own_article(slug, user_id) do
    with {:ok, article} <- Article |> Repo.get_by(slug: slug) |> fetch(),
         :ok <- authorize(article, user_id) do
      {:ok, article}
    end
  end

  ## Favorites

  @doc "Favorites an article. Favoriting it twice is fine."
  @spec favorite_article(String.t(), pos_integer()) :: {:ok, Article.t()} | {:error, :not_found}
  def favorite_article(slug, user_id) do
    # SPEC.md's lookup and insert in one statement: the favorite comes from the article's row, so an unknown slug
    # inserts nothing and the read after it is the 404. FOR KEY SHARE is the lock the foreign key check takes anyway,
    # taken here as the article is read, so an article deleted meanwhile is skipped rather than failing that check.
    # The read is by slug, where SPEC.md's is by id: they differ only if the author retitles the article in between.
    favorite =
      from a in Article,
        where: a.slug == ^slug,
        lock: "FOR KEY SHARE",
        select: %{user_id: type(^user_id, :id), article_id: a.id}

    Repo.insert_all(Favorite, favorite, on_conflict: :nothing)
    get_article(slug, user_id)
  end

  @doc "Removes a favorite."
  @spec unfavorite_article(String.t(), pos_integer()) :: {:ok, Article.t()} | {:error, :not_found}
  def unfavorite_article(slug, user_id) do
    # As for a favorite: the article's id comes from its slug inside the delete, and the read after it is the 404.
    article_id = from a in Article, where: a.slug == ^slug, select: a.id
    favorite = from f in Favorite, where: f.user_id == ^user_id and f.article_id in subquery(article_id)
    Repo.delete_all(favorite)
    get_article(slug, user_id)
  end

  ## Comments

  @doc "Lists an article's newest #{@max_comments} comments, newest first."
  @spec list_comments(String.t(), pos_integer() | nil) :: {:ok, [Comment.t()]} | {:error, :not_found}
  def list_comments(slug, viewer_id) do
    newest =
      from c in Comment,
        where: c.article_id == parent_as(:article).id,
        order_by: [desc: c.created_at, desc: c.id],
        limit: @max_comments,
        select: struct(c, [:author_id | @comment_fields])

    # One statement: the article by slug, left-joined to its newest comments, so an article without comments is still
    # a row (with a nil comment) and an unknown slug is no row at all.
    query =
      from a in Article,
        as: :article,
        where: a.slug == ^slug,
        left_lateral_join: c in subquery(newest),
        on: true,
        left_join: u in User,
        on: u.id == c.author_id,
        left_join: fo in Follow,
        on: fo.followee_id == u.id and fo.follower_id == ^(viewer_id || 0),
        order_by: [desc: c.created_at, desc: c.id],
        select: {struct(c, @comment_fields), struct(u, @author_fields), not is_nil(fo.follower_id)}

    case Repo.all(query) do
      [] ->
        {:error, :not_found}

      rows ->
        comments = for {%Comment{} = c, author, following} <- rows, do: %{c | author: %{author | following: following}}
        {:ok, comments}
    end
  end

  @doc "Comments on an article as `author_id`."
  @spec create_comment(String.t(), pos_integer(), map()) ::
          {:ok, Comment.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def create_comment(slug, author_id, attrs) do
    changeset = Comment.changeset(%Comment{author_id: author_id}, attrs)

    # A bad body is a 422 even on an unknown article: SPEC.md checks the body before it runs any statement.
    with :ok <- validate(changeset),
         {:ok, {article_id, author}} <- fetch_article_id_and_author(slug, author_id),
         {:ok, comment} <- changeset |> put_change(:article_id, article_id) |> Repo.insert() |> gone() do
      # SPEC.md answers with the author's `following` false, the field's default, whoever the commenter follows.
      comment = %{comment | author: author}
      {:ok, comment}
    end
  end

  # The article's id and the commenter's profile in one statement.
  defp fetch_article_id_and_author(slug, author_id) do
    query =
      from a in Article,
        join: u in User,
        on: u.id == ^author_id,
        where: a.slug == ^slug,
        select: {a.id, struct(u, @author_fields)}

    query |> Repo.one() |> fetch()
  end

  @doc "Deletes a comment on the article `slug`. Only its author may."
  @spec delete_comment(String.t(), String.t(), pos_integer()) :: :ok | {:error, :not_found | :forbidden}
  def delete_comment(slug, comment_id, user_id) do
    with {:ok, id} <- parse_id(comment_id),
         {:ok, comment} <- fetch_comment(id, slug),
         :ok <- authorize(comment, user_id),
         {:ok, _comment} <- Repo.delete(comment, allow_stale: true) do
      :ok
    end
  end

  defp fetch_comment(id, slug) do
    query = from c in Comment, join: a in assoc(c, :article), where: c.id == ^id and a.slug == ^slug
    query |> Repo.one() |> fetch()
  end

  ## Tags

  @doc "All tag names, sorted."
  @spec list_tags() :: [String.t()]
  def list_tags do
    # One row, the names aggregated by Postgres: every home page lists all the tags, and decoding and loading them
    # one row each cost ~25% more app CPU than one array.
    query = from t in Tag, select: fragment("coalesce(array_agg(? ORDER BY ?), '{}')", t.name, t.name)
    Repo.one(query)
  end

  ## Helpers

  # Only plain digits that fit in a bigint can be a comment id, as for `limit` and `offset`.
  defp parse_id(id) do
    case PlainInteger.cast(id) do
      {:ok, n} when n > 0 -> {:ok, n}
      _ -> {:error, :not_found}
    end
  end

  # The article a write read first can be deleted by another request before the write lands: the one under a new
  # comment, or the one being edited. The write then breaks a foreign key or finds its row stale, and gets the 404 it
  # would have got a moment later. Validation errors stay a changeset.
  defp gone({:error, %Ecto.Changeset{errors: errors}} = error) do
    if Enum.any?(errors, fn {_field, {_message, info}} -> info[:stale] || info[:constraint] == :foreign end) do
      {:error, :not_found}
    else
      error
    end
  end

  defp gone(result), do: result

  defp validate(%Ecto.Changeset{valid?: true}), do: :ok
  defp validate(changeset), do: {:error, changeset}

  defp authorize(%{author_id: author_id}, user_id) when author_id == user_id, do: :ok
  defp authorize(_resource, _user_id), do: {:error, :forbidden}

  defp fetch(nil), do: {:error, :not_found}
  defp fetch(value), do: {:ok, value}
end
