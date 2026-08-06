defmodule Baileys.Store.File do
  @moduledoc false

  alias Baileys.Auth.Credentials
  alias Baileys.Store.JSONCodec

  @json_extension ".json"
  @legacy_json_filename "session.json"
  @legacy_filename "session.etf"
  @max_session_bytes 10 * 1024 * 1024
  @persisted_atoms [
    Baileys.Auth.Credentials,
    Baileys.Proto.ADVSignedDeviceIdentity,
    Baileys.Proto.Message.AppStateSyncKeyData,
    Baileys.Proto.Message.AppStateSyncKeyFingerprint,
    :__protobuf__,
    :__struct__,
    :__unknown_fields__,
    :account,
    :account_settings,
    :app_state_collections,
    :app_state_sync_keys,
    :accountSignature,
    :accountSignatureKey,
    :adv_secret_key,
    :base_key,
    :base_key_type,
    :chain_key,
    :chain_type,
    :chunk_order,
    :chains,
    :closed,
    :counter,
    :created,
    :current_ratchet,
    :details,
    :deviceSignature,
    :ephemeral_key_pair,
    :ephemeral_expiration,
    :ephemeral_setting_timestamp,
    :default_disappearing_mode,
    :first_unuploaded_pre_key_id,
    :id,
    :history_sync_progress,
    :hash,
    :index_info,
    :index_value_map,
    :key,
    :keyData,
    :key_id,
    :key_pair,
    :last_remote_ephemeral_key,
    :lid,
    :lid_mappings,
    :fingerprint,
    :rawId,
    :currentIndex,
    :deviceIndexes,
    :me,
    :message_keys,
    :my_app_state_key_id,
    :name,
    :next_pre_key_id,
    :noise_key,
    :pairing_code,
    :pairing_ephemeral_key,
    :pending_pre_key,
    :peer_data_request_session_id,
    :pending_app_state_sync,
    :pending_history_sync,
    :platform,
    :pre_key_id,
    :pre_keys,
    :progress,
    :privacy_tokens,
    :previous_counter,
    :private,
    :public,
    :registered?,
    :registration_id,
    :remote_identity_key,
    :root_key,
    :request_id,
    :routing_info,
    :sessions,
    :sender_keys,
    :states,
    :sender_key_id,
    :signing_key,
    :seed,
    :iteration,
    :signature,
    :signed_identity_key,
    :signed_key_id,
    :signed_pre_key,
    :sync_type,
    :timestamp,
    :token,
    :used,
    :version,
    :original_message_id
  ]

  def load_or_create(root, session) do
    with :ok <- validate_root(root),
         path = session_path(root, session),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      case load_json(path) do
        {:ok, credentials} -> {:ok, credentials, path}
        {:error, :enoent} -> migrate_or_create(root, session, path)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def save(path, %Credentials{} = credentials) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with {:ok, encoded} <- JSONCodec.encode(credentials),
         true <- byte_size(encoded) <= @max_session_bytes || {:error, :session_too_large},
         :ok <- File.write(temporary, encoded, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      error ->
        File.rm(temporary)
        error
    end
  end

  def reset(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_json(path) do
    with {:ok, encoded} <- File.read(path),
         true <- byte_size(encoded) <= @max_session_bytes || {:error, :session_too_large} do
      JSONCodec.decode(encoded)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_or_create(root, session, path) do
    legacy_directory = Path.join(root, session)
    legacy_json_path = Path.join(legacy_directory, @legacy_json_filename)

    case load_json(legacy_json_path) do
      {:ok, credentials} -> migrate(path, legacy_json_path, legacy_directory, credentials)
      {:error, :enoent} -> migrate_legacy_etf(path, legacy_directory)
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate_legacy_etf(path, legacy_directory) do
    legacy_path = Path.join(legacy_directory, @legacy_filename)

    case load_legacy(legacy_path) do
      {:ok, credentials} -> migrate(path, legacy_path, legacy_directory, credentials)
      {:error, :enoent} -> create(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp migrate(path, legacy_path, legacy_directory, credentials) do
    with :ok <- save(path, credentials),
         :ok <- File.rm(legacy_path),
         :ok <- remove_legacy_directory(legacy_directory) do
      {:ok, credentials, path}
    end
  end

  defp remove_legacy_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, reason} when reason in [:enoent, :eexist, :enotempty] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_legacy(path) do
    with {:ok, encoded} <- File.read(path),
         true <- byte_size(encoded) <= @max_session_bytes || {:error, :session_too_large} do
      preload_schema_atoms()

      try do
        case :erlang.binary_to_term(encoded, [:safe]) do
          %Credentials{} = credentials ->
            credentials = credentials |> Map.from_struct() |> then(&struct(Credentials, &1))
            {:ok, credentials}

          _other ->
            {:error, :invalid_credentials}
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
    Path.join(root, session <> @json_extension)
  end

  defp validate_root(nil), do: {:error, :sessions_path_required}

  defp validate_root(root) when is_binary(root) do
    if Path.type(root) == :absolute,
      do: :ok,
      else: {:error, :sessions_path_must_be_absolute}
  end

  defp validate_root(_root), do: {:error, :invalid_sessions_path}

  # Force every allowed atom into the VM before safe ETF decoding. Keeping this
  # operation observable prevents the compiler from removing the literal table.
  defp preload_schema_atoms do
    Enum.each(@persisted_atoms, &:erlang.atom_to_binary/1)
  end
end
