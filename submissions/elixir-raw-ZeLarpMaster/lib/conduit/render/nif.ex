defmodule Conduit.Render.Nif do
  @moduledoc false
  # native/conduit_render_nif.c: JSON bodies straight from raw DataRow column data (Conduit.Pg.query_raw/2). Each
  # raises badarg on rows that don't have the expected columns.
  @on_load :load

  def load, do: :erlang.load_nif(:filename.join(:code.priv_dir(:conduit), ~c"conduit_render"), 0)

  @doc "List rows (count, then a bodyless article) -> `{\"articles\":[...],\"articlesCount\":n}`."
  def list(_rows), do: :erlang.nif_error(:not_loaded)

  @doc "An article row (with body) -> `{\"article\":{...}}`."
  def article(_row), do: :erlang.nif_error(:not_loaded)

  @doc "Comment rows (article id, then a comment; NULL comment = none) -> `{\"comments\":[...]}`."
  def comments(_rows), do: :erlang.nif_error(:not_loaded)

  @doc "A profile row (id, username, bio, image, following) -> `{\"profile\":{...}}`."
  def profile(_row), do: :erlang.nif_error(:not_loaded)

  @doc "The tags row (one text[]) -> `{\"tags\":[...]}`."
  def tags(_row), do: :erlang.nif_error(:not_loaded)

  @doc """
  An article row (as list/1's after the count, or article/1's with `with_body` 1) -> `{a, b, c}`: its JSON is
  `a <> favorited <> b <> following <> c` (the row's booleans are placeholders).
  """
  def article_parts(_row, _with_body), do: :erlang.nif_error(:not_loaded)

  @doc "A comment row (as comments/1's without the article id) -> `{a, c}`: its JSON is `a <> following <> c`."
  def comment_parts(_row), do: :erlang.nif_error(:not_loaded)

  @doc """
  A plan_articles row (Conduit.Sql) and nil, or plan_slug's body column -> `{id, author id, {a, b, c}}`: the pieces
  article_parts/2 gives for that article without or with its body.
  """
  def plan_article(_row, _body), do: :erlang.nif_error(:not_loaded)

  @doc "A plan_comments row -> `{ordinal, author id, {a, c}}` (comment_parts/1's pieces) or `{ordinal, :none}`."
  def plan_comment(_row), do: :erlang.nif_error(:not_loaded)

  # ------------------------------------------------------------------ whole plans (Conduit.Plan, PLAN_NIF=1)
  # A context for one plan, usable only by the process that made it: the plan's raw rows go in as they arrive and
  # each request's finished body comes out.

  @doc "A new plan context."
  def plan_new, do: :erlang.nif_error(:not_loaded)

  @doc """
  Adds a chunk's raw rows: `table` 0-6 a phase A statement's (Conduit.Plan's kinds in order; ordinal i is slot
  `base + i - 1` of that kind), 7 plan_articles, 8 plan_favs, 9 plan_follows, 10 plan_counts (before any
  article: from then on each article's favorite count is its plan_counts row's). `:ok`; raises on malformed rows.
  """
  def plan_add(_plan, _table, _base, _rows), do: :erlang.nif_error(:not_loaded)

  @doc "`{all, chunks}`: phase A's distinct article ids as encoded int8[] parameters, all and in chunks of `chunk`."
  def plan_ids(_plan, _chunk), do: :erlang.nif_error(:not_loaded)

  @doc "`{n, param}`: the distinct authors of the articles and comments added, as an encoded int8[] parameter."
  def plan_authors(_plan), do: :erlang.nif_error(:not_loaded)

  @doc """
  `[{ref, kind, slot, viewer}]` -> the messages answering them, in order: `{ref, {:ok, body}}` (body nil: no such
  article) or `{ref, :fallback}` (something the body needs is missing from the plan).
  """
  def plan_bodies(_plan, _reqs), do: :erlang.nif_error(:not_loaded)
end
