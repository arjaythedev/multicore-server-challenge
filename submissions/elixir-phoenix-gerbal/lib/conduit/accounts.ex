defmodule Conduit.Accounts do
  @moduledoc "Users: signing up, logging in, and reading and updating the current user."

  import Ecto.Changeset

  alias Conduit.Accounts.Token
  alias Conduit.Accounts.User
  alias Conduit.Repo

  @doc "Gets a user by id, or nil."
  @spec get_user(pos_integer()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc "Signs up a new user."
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Checks an email and password. Both must be non-empty strings (`{:error, changeset}` otherwise), and an unknown
  email or a wrong password is `{:error, :unauthorized}`.
  """
  @spec authenticate(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def authenticate(attrs) do
    types = %{email: :string, password: :string}

    with {:ok, %{email: email, password: password}} <-
           {%{}, types}
           |> cast(attrs, Map.keys(types), trim_values: fn _type, value -> value end)
           |> validate_required(Map.keys(types))
           |> apply_action(:login) do
      user = Repo.get_by(User, email: email)

      if User.valid_password?(user, password) do
        {:ok, user}
      else
        {:error, :unauthorized}
      end
    end
  end

  @doc "Updates a user's email, username, password, bio or image."
  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @doc "Issues a fresh token for a user."
  @spec sign_token(User.t()) :: String.t()
  def sign_token(%User{id: id}), do: Token.sign(id)

  @doc "Verifies a token, giving the user id it was issued for."
  @spec verify_token(String.t()) :: {:ok, pos_integer()} | :error
  defdelegate verify_token(token), to: Token, as: :fetch_user_id
end
