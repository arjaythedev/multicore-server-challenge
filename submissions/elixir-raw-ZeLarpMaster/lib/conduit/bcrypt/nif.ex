defmodule Conduit.Bcrypt.Nif do
  @moduledoc false
  # native/conduit_bcrypt_nif.c. hash/2 runs on a dirty CPU scheduler.
  @on_load :load

  def load, do: :erlang.load_nif(:filename.join(:code.priv_dir(:conduit), ~c"conduit_bcrypt"), 0)

  @doc "1-6 passwords (<= 72 bytes, no NUL) with as many settings of one cost -> their 60-byte hashes, or :error."
  def hash(_keys, _settings), do: :erlang.nif_error(:not_loaded)

  @doc "16 random bytes -> a cost-10 setting, \"$2b$10$\" + 22 characters."
  def salt(_random), do: :erlang.nif_error(:not_loaded)

  @doc "Starts `n` hashing threads of our own under SCHED_IDLE (once): :ok or {:error, reason}."
  def idle_start(_n), do: :erlang.nif_error(:not_loaded)

  @doc """
  Queues hash/2's job for the idle threads: :ok, after which the caller gets {ref, hashes | :error}; or :error at
  once for bad input.
  """
  def hash_idle(_keys, _settings, _ref), do: :erlang.nif_error(:not_loaded)
end
