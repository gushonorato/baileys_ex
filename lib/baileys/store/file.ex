defmodule Baileys.Store.File do
  @moduledoc """
  Filesystem-backed credential storage.

  Each session is stored as `<root>/<session>.json`. Existing files from the
  former per-session JSON and ETF layouts are moved into the current layout on
  first access; `Baileys.Store` performs any required payload conversion.
  """

  @behaviour Baileys.Store.Adapter

  @json_extension ".json"
  @legacy_json_filename "session.json"
  @legacy_filename "session.etf"

  @impl true
  def init(options) do
    with {:ok, root} <- fetch_root(options),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      {:ok, %{root: root}}
    end
  end

  @impl true
  def fetch(%{root: root} = state, session) do
    path = session_path(root, session)

    case File.read(path) do
      {:ok, payload} -> {:ok, payload}
      {:error, :enoent} -> fetch_legacy(state, session)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(%{root: root}, session, payload) when is_binary(payload) do
    path = session_path(root, session)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(temporary, payload, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  @impl true
  def delete(%{root: root}, session) do
    case File.rm(session_path(root, session)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_legacy(state, session) do
    directory = Path.join(state.root, session)
    json_path = Path.join(directory, @legacy_json_filename)

    case File.read(json_path) do
      {:ok, payload} -> migrate(state, session, json_path, directory, payload)
      {:error, :enoent} -> fetch_legacy_etf(state, session, directory)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_legacy_etf(state, session, directory) do
    etf_path = Path.join(directory, @legacy_filename)

    case File.read(etf_path) do
      {:ok, payload} -> migrate(state, session, etf_path, directory, payload)
      {:error, :enoent} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate(state, session, legacy_path, legacy_directory, payload) do
    with :ok <- put(state, session, payload),
         :ok <- File.rm(legacy_path),
         :ok <- remove_legacy_directory(legacy_directory) do
      {:ok, payload}
    end
  end

  defp remove_legacy_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, reason} when reason in [:enoent, :eexist, :enotempty] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_root(options) do
    case Keyword.fetch(options, :root) do
      {:ok, root} when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute, do: {:ok, root}, else: {:error, :root_must_be_absolute}

      {:ok, _root} ->
        {:error, :invalid_root}

      :error ->
        {:error, :root_required}
    end
  end

  defp session_path(root, session), do: Path.join(root, session <> @json_extension)
end
