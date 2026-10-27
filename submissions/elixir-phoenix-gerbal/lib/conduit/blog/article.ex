defmodule Conduit.Blog.Article do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  alias Conduit.Accounts.User
  alias Conduit.Blog.Tag

  @type t :: %__MODULE__{}

  schema "articles" do
    field :slug, :string
    field :title, :string
    field :description, :string
    field :body, :string

    # Set by queries: the article's favorite count, and whether the current viewer favorited it.
    field :favorites_count, :integer, virtual: true, default: 0
    field :favorited, :boolean, virtual: true, default: false

    # Tag names: given when publishing, and set (sorted) by queries that load articles.
    field :tag_list, {:array, :string}, virtual: true, default: []

    belongs_to :author, User
    many_to_many :tags, Tag, join_through: "article_tags", preload_order: [asc: :name]

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at)
  end

  @doc """
  A changeset for publishing. Title, description and body must be non-empty strings (whitespace counts, as in
  SPEC.md, so values aren't trimmed before the blank check); `tag_list` is an optional list of non-empty names.

  The slug embeds the id, so both are assigned inside the insert's transaction from the id sequence.
  """
  def create_changeset(article, attrs) do
    article
    |> cast(attrs, [:title, :description, :body], trim_values: fn _type, value -> value end)
    |> validate_required([:title, :description, :body])
    # Cast on its own because by default Ecto drops blank items from string arrays, and they must be an error.
    |> cast(attrs, [:tag_list], empty_values: [])
    |> validate_change(:tag_list, fn :tag_list, names ->
      if Enum.all?(names, &(is_binary(&1) and &1 != "")) do
        []
      else
        [tag_list: "can't contain blank tags"]
      end
    end)
    |> prepare_changes(&assign_id_and_slug/1)
  end

  @doc "A changeset for editing. Absent or `null` fields are unchanged; a new title gives a new slug."
  def update_changeset(article, attrs) do
    attrs = Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

    article
    |> cast(attrs, [:title, :description, :body], empty_values: [], force_changes: true)
    |> validate_length(:title, min: 1)
    |> validate_length(:description, min: 1)
    |> validate_length(:body, min: 1)
    |> put_slug()
  end

  @doc """
  The slug for a title and id: runs of anything but ASCII letters and digits become `-`, then it is lowercased,
  trimmed of `-` and suffixed with `-<id>`. Byte-identical to SPEC.md's SLUGIFY in SQL.
  """
  def slug(title, id) do
    base = title |> String.replace(~r/[^A-Za-z0-9]+/, "-") |> String.downcase() |> String.trim("-")
    "#{base}-#{id}"
  end

  defp assign_id_and_slug(changeset) do
    %{rows: [[id]]} = changeset.repo.query!("SELECT nextval(pg_get_serial_sequence('articles', 'id'))")

    changeset
    |> put_change(:id, id)
    |> put_change(:slug, slug(get_field(changeset, :title), id))
  end

  defp put_slug(%Ecto.Changeset{valid?: true, changes: %{title: title}} = changeset),
    do: put_change(changeset, :slug, slug(title, changeset.data.id))

  defp put_slug(changeset), do: changeset
end
