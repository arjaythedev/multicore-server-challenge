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
end
