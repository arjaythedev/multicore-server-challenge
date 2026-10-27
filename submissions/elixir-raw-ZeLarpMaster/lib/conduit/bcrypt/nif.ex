defmodule Conduit.Bcrypt.Nif do
  @moduledoc false
  # native/conduit_bcrypt_nif.c. hash/2 runs on a dirty CPU scheduler.
  @on_load :load

  def load, do: :erlang.load_nif(:filename.join(:code.priv_dir(:conduit), ~c"conduit_bcrypt"), 0)

  @doc "1-4 passwords (<= 72 bytes, no NUL) with as many settings of one cost -> their 60-byte hashes, or :error."
  def hash(_keys, _settings), do: :erlang.nif_error(:not_loaded)

  @doc "16 random bytes -> a cost-10 setting, \"$2b$10$\" + 22 characters."
  def salt(_random), do: :erlang.nif_error(:not_loaded)
end
