defmodule BaileysExo.Store.File do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Store.JSONCodec

  @filename "session.json"
  @legacy_filename "session.etf"
  @max_session_bytes 10 * 1024 * 1024
  @persisted_atoms [
    BaileysExo.Auth.Credentials,
    BaileysExo.Proto.ADVSignedDeviceIdentity,
    :__protobuf__,
    :__struct__,
    :__unknown_fields__,
    :account,
    :accountSignature,
    :accountSignatureKey,
    :adv_secret_key,
    :base_key,
    :base_key_type,
    :chain_key,
    :chain_type,
    :chains,
    :closed,
    :counter,
    :created,
    :current_ratchet,
    :details,
    :deviceSignature,
    :ephemeral_key_pair,
    :first_unuploaded_pre_key_id,
    :id,
    :index_info,
    :key,
    :key_id,
    :key_pair,
    :last_remote_ephemeral_key,
    :lid,
    :lid_mappings,
    :me,
    :message_keys,
    :name,
    :next_pre_key_id,
    :noise_key,
    :pairing_code,
    :pairing_ephemeral_key,
    :pending_pre_key,
    :platform,
    :pre_key_id,
    :pre_keys,
    :previous_counter,
    :private,
    :public,
    :registered?,
    :registration_id,
    :remote_identity_key,
    :root_key,
    :routing_info,
    :sessions,
    :signature,
    :signed_identity_key,
    :signed_key_id,
    :signed_pre_key,
    :used
  ]

  def load_or_create(root, session) do
    path = session_path(root, session)

    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      case load(path) do
        {:ok, credentials} -> {:ok, credentials, path}
        {:error, :enoent} -> create(path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def save(path, %Credentials{} = credentials) do
    destination = Path.join(path, @filename)
    temporary = destination <> ".tmp-#{System.unique_integer([:positive])}"

    with {:ok, encoded} <- JSONCodec.encode(credentials),
         true <- byte_size(encoded) <= @max_session_bytes || {:error, :session_too_large},
         :ok <- File.write(temporary, encoded, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, destination) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  def reset(path) do
    with {:ok, _files} <- File.rm_rf(path),
         :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    end
  end

  defp load(path) do
    case load_json(path) do
      {:error, :enoent} -> migrate_legacy(path)
      result -> result
    end
  end

  defp load_json(path) do
    with {:ok, encoded} <- File.read(Path.join(path, @filename)),
         true <- byte_size(encoded) <= @max_session_bytes || {:error, :session_too_large} do
      JSONCodec.decode(encoded)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_legacy(path) do
    legacy_path = Path.join(path, @legacy_filename)

    with {:ok, credentials} <- load_legacy(legacy_path),
         :ok <- save(path, credentials),
         :ok <- File.rm(legacy_path) do
      {:ok, credentials}
    end
  end

  defp load_legacy(path) do
    with {:ok, encoded} <- File.read(path),
         true <- byte_size(encoded) <= @max_session_bytes || {:error, :session_too_large} do
      preload_schema_atoms()

      try do
        case :erlang.binary_to_term(encoded, [:safe]) do
          %Credentials{} = credentials -> {:ok, credentials}
          _other -> {:error, :invalid_credentials}
        end
      rescue
        ArgumentError -> {:error, :invalid_credentials}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(path) do
    credentials = Credentials.new()

    case save(path, credentials) do
      :ok -> {:ok, credentials, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp session_path(root, session) do
    root |> Path.expand() |> Path.join(session)
  end

  # Force every allowed atom into the VM before safe ETF decoding. Keeping this
  # operation observable prevents the compiler from removing the literal table.
  defp preload_schema_atoms do
    Enum.each(@persisted_atoms, &:erlang.atom_to_binary/1)
  end
end
