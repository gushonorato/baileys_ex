defmodule Baileys.Store.Memory do
  @moduledoc """
  In-memory, process-local credential storage.

  Every initialization starts an isolated Agent linked to the client process.
  Its contents disappear when that client terminates.
  """

  @behaviour Baileys.Store.Adapter

  @impl true
  def init(_options), do: Agent.start_link(fn -> %{} end)

  @impl true
  def fetch(agent, session) do
    call(fn ->
      Agent.get(agent, fn entries ->
        case Map.fetch(entries, session) do
          {:ok, payload} -> {:ok, payload}
          :error -> :not_found
        end
      end)
    end)
  end

  @impl true
  def put(agent, session, payload) when is_binary(payload) do
    call(fn -> Agent.update(agent, &Map.put(&1, session, payload)) end)
  end

  @impl true
  def delete(agent, session) do
    call(fn -> Agent.update(agent, &Map.delete(&1, session)) end)
  end

  defp call(function) do
    function.()
  catch
    :exit, reason -> {:error, reason}
  end
end
