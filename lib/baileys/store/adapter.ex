defmodule Baileys.Store.Adapter do
  @moduledoc """
  Behaviour implemented by credential storage adapters.

  Adapters persist opaque binary payloads. Credential serialization, schema
  handling and reset orchestration belong to `Baileys.Store`. Adapters backed
  by remote shared storage should use conditional writes and return an explicit
  `:conflict` rather than silently overwriting a concurrently changed session.
  """

  @type state :: term()
  @type session :: String.t()

  @callback init(keyword()) :: {:ok, state()} | {:error, term()}
  @callback fetch(state(), session()) :: {:ok, binary()} | :not_found | {:error, term()}
  @callback put(state(), session(), binary()) :: :ok | {:error, term()}
  @callback delete(state(), session()) :: :ok | {:error, term()}
end
