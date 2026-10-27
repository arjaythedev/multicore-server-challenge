defmodule Conduit.Accounts.User do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :username, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :password_hash, :string, redact: true
    field :bio, :string
    field :image, :string

    # Whether the current viewer follows this user. Set by queries that know the viewer.
    field :following, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime_usec, inserted_at: :created_at, updated_at: false)
  end

  @doc """
  A changeset for signing up: username, email and password must be non-empty strings. Whitespace counts, as in
  SPEC.md, so values aren't trimmed before the blank check.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password], trim_values: fn _type, value -> value end)
    |> validate_required([:username, :email, :password])
    |> validate_password()
    |> unique_constraints()
  end

  @doc """
  A changeset for updating the profile and credentials.

  Fields that are absent or `null` are left unchanged. Email, username and password can't be blank; bio and image
  can be set to the empty string.
  """
  def update_changeset(user, attrs) do
    attrs = Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

    user
    |> cast(attrs, [:username, :email, :password, :bio, :image], empty_values: [])
    |> validate_length(:username, min: 1)
    |> validate_length(:email, min: 1)
    |> validate_password()
    |> unique_constraints()
  end

  @doc "Whether `password` matches the user's stored hash. Runs a dummy check when there is no user."
  def valid_password?(%__MODULE__{password_hash: hash}, password) when is_binary(hash),
    do: Bcrypt.verify_pass(password, hash)

  def valid_password?(_user, _password), do: Bcrypt.no_user_verify()

  # bcrypt only uses the first 72 bytes, so longer passwords are rejected rather than silently truncated.
  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 1, max: 72, count: :bytes)
    |> hash_password()
  end

  defp hash_password(%Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset) do
    changeset
    |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
    |> delete_change(:password)
  end

  defp hash_password(changeset), do: changeset

  defp unique_constraints(changeset) do
    changeset
    |> unique_constraint(:username, name: :users_username_key, message: "has already been taken")
    |> unique_constraint(:email, name: :users_email_key, message: "has already been taken")
  end
end
