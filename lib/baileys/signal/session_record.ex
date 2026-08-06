defmodule Baileys.Signal.SessionRecord do
  @moduledoc false

  @base_key_ours 1
  @base_key_theirs 2
  @chain_sending 1
  @chain_receiving 2

  def base_key_ours, do: @base_key_ours
  def base_key_theirs, do: @base_key_theirs
  def chain_sending, do: @chain_sending
  def chain_receiving, do: @chain_receiving

  def new, do: %{sessions: %{}}
  def create_entry, do: %{chains: %{}}

  def add_chain(entry, key, chain) do
    id = key_id(key)
    if Map.has_key?(entry.chains, id), do: raise("signal chain already exists")
    put_in(entry.chains[id], chain)
  end

  def get_chain(entry, key), do: Map.get(entry.chains, key_id(key))
  def put_chain(entry, key, chain), do: put_in(entry.chains[key_id(key)], chain)
  def delete_chain(entry, key), do: %{entry | chains: Map.delete(entry.chains, key_id(key))}

  def get_session(record, key) do
    session = Map.get(record.sessions, key_id(key))

    if session && session.index_info.base_key_type == @base_key_ours do
      raise "cannot look up a Signal session using our base key"
    end

    session
  end

  def get_open_session(record) do
    Enum.find(Map.values(record.sessions), &(&1.index_info.closed == -1))
  end

  def get_sessions(record) do
    record.sessions |> Map.values() |> Enum.sort_by(& &1.index_info.used, :desc)
  end

  def set_session(record, session) do
    put_in(record.sessions[key_id(session.index_info.base_key)], session)
  end

  def close_open_session(record) do
    case get_open_session(record) do
      nil ->
        record

      session ->
        closed = put_in(session.index_info.closed, System.system_time(:millisecond))
        set_session(record, closed)
    end
  end

  defp key_id(key), do: Base.encode64(key)
end
