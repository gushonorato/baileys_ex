defmodule Baileys.AppState.Decoder do
  @moduledoc false

  alias Baileys.AppState.Crypto

  alias Baileys.Proto.{
    KeyId,
    SyncActionData,
    SyncdMutation,
    SyncdPatch,
    SyncdRecord,
    SyncdSnapshot,
    SyncdVersion
  }

  @empty_hash <<0::size(128)-unit(8)>>
  @uint64_max 0xFFFFFFFFFFFFFFFF

  @type state :: %{
          version: non_neg_integer(),
          hash: binary(),
          index_value_map: %{binary() => binary()}
        }

  @type mutation :: %{
          operation: :SET | :REMOVE,
          index: Jason.decode_term(),
          sync_action: SyncActionData.t()
        }

  @type reason ::
          :external_mutations_not_supported
          | :invalid_action_data
          | :invalid_index_json
          | :invalid_index_mac
          | :invalid_patch
          | :invalid_patch_mac
          | :invalid_record
          | :invalid_snapshot
          | :invalid_snapshot_mac
          | :invalid_state
          | :invalid_value_mac
          | {:missing_index, binary()}
          | {:missing_key, binary()}
          | {:unexpected_version, non_neg_integer(), non_neg_integer()}

  @spec empty_state() :: state()
  def empty_state do
    %{version: 0, hash: @empty_hash, index_value_map: %{}}
  end

  @spec apply_snapshot(SyncdSnapshot.t(), binary(), map()) ::
          {:ok, state(), [mutation()]} | {:error, reason()}
  def apply_snapshot(%SyncdSnapshot{} = snapshot, collection, key_map)
      when is_binary(collection) and is_map(key_map) do
    with {:ok, version} <- snapshot_version(snapshot.version),
         {:ok, decoded_state, mutations} <-
           decode_records(snapshot.records, empty_state(), key_map, :snapshot),
         {:ok, keys} <- record_keys(snapshot.keyId, key_map),
         expected_mac =
           Crypto.snapshot_mac(
             decoded_state.hash,
             version,
             collection,
             keys.snapshot_mac_key
           ),
         :ok <- verify_mac(snapshot.mac, expected_mac, :invalid_snapshot_mac) do
      {:ok, %{decoded_state | version: version}, mutations}
    end
  end

  def apply_snapshot(_snapshot, _collection, _key_map), do: {:error, :invalid_snapshot}

  @spec apply_patches(state(), [SyncdPatch.t()], binary(), map()) ::
          {:ok, state(), [mutation()]} | {:error, reason()}
  def apply_patches(state, patches, collection, key_map)
      when is_list(patches) and is_binary(collection) and is_map(key_map) do
    with :ok <- validate_state(state) do
      Enum.reduce_while(patches, {:ok, state, []}, fn patch, {:ok, current, mutations} ->
        case apply_patch_validated(current, patch, collection, key_map) do
          {:ok, next, patch_mutations} ->
            {:cont, {:ok, next, Enum.reverse(patch_mutations, mutations)}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, next, reversed_mutations} -> {:ok, next, Enum.reverse(reversed_mutations)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def apply_patches(_state, _patches, _collection, _key_map), do: {:error, :invalid_state}

  @spec apply_patch(state(), SyncdPatch.t(), binary(), map()) ::
          {:ok, state(), [mutation()]} | {:error, reason()}
  def apply_patch(state, patch, collection, key_map)
      when is_binary(collection) and is_map(key_map) do
    with :ok <- validate_state(state) do
      apply_patch_validated(state, patch, collection, key_map)
    end
  end

  def apply_patch(_state, _patch, _collection, _key_map), do: {:error, :invalid_state}

  @spec decode_record(SyncdRecord.t(), :SET | :REMOVE, map()) ::
          {:ok, mutation()} | {:error, reason()}
  def decode_record(%SyncdRecord{} = record, operation, key_map)
      when operation in [:SET, :REMOVE] and is_map(key_map) do
    with {:ok, decoded} <- decode_record_with_macs(record, operation, key_map) do
      {:ok, Map.take(decoded, [:operation, :index, :sync_action])}
    end
  end

  def decode_record(_record, _operation, _key_map), do: {:error, :invalid_record}

  defp apply_patch_validated(state, %SyncdPatch{} = patch, collection, key_map) do
    expected_version = state.version + 1

    with :ok <- validate_external_mutations(patch.externalMutations),
         {:ok, version} <- patch_version(patch.version),
         :ok <- verify_version(version, expected_version),
         :ok <- validate_mac_field(patch.snapshotMac, :invalid_patch),
         {:ok, keys} <- record_keys(patch.keyId, key_map),
         {:ok, value_macs} <- mutation_value_macs(patch.mutations),
         expected_patch_mac =
           Crypto.patch_mac(
             patch.snapshotMac,
             value_macs,
             version,
             collection,
             keys.patch_mac_key
           ),
         :ok <- verify_mac(patch.patchMac, expected_patch_mac, :invalid_patch_mac),
         {:ok, decoded_state, mutations} <-
           decode_records(patch.mutations, state, key_map, :patch),
         next_state = %{decoded_state | version: version},
         expected_snapshot_mac =
           Crypto.snapshot_mac(
             next_state.hash,
             version,
             collection,
             keys.snapshot_mac_key
           ),
         :ok <- verify_mac(patch.snapshotMac, expected_snapshot_mac, :invalid_snapshot_mac) do
      {:ok, next_state, mutations}
    end
  end

  defp apply_patch_validated(_state, _patch, _collection, _key_map),
    do: {:error, :invalid_patch}

  defp decode_records(records, state, key_map, source) when is_list(records) do
    Enum.reduce_while(records, {:ok, state, []}, fn item, {:ok, current, mutations} ->
      with {:ok, operation, record} <- mutation_record(item, source),
           {:ok, decoded} <- decode_record_with_macs(record, operation, key_map),
           {:ok, next} <- mix_mutation(current, decoded) do
        mutation = Map.take(decoded, [:operation, :index, :sync_action])
        {:cont, {:ok, next, [mutation | mutations]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, next, reversed_mutations} -> {:ok, next, Enum.reverse(reversed_mutations)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_records(_records, _state, _key_map, :snapshot), do: {:error, :invalid_snapshot}
  defp decode_records(_records, _state, _key_map, :patch), do: {:error, :invalid_patch}

  defp mutation_record(%SyncdRecord{} = record, :snapshot), do: {:ok, :SET, record}

  defp mutation_record(
         %SyncdMutation{operation: operation, record: %SyncdRecord{} = record},
         :patch
       )
       when operation in [:SET, :REMOVE],
       do: {:ok, operation, record}

  defp mutation_record(_record, :snapshot), do: {:error, :invalid_record}
  defp mutation_record(_mutation, :patch), do: {:error, :invalid_patch}

  defp decode_record_with_macs(
         %SyncdRecord{
           keyId: %KeyId{id: key_id},
           index: %{blob: index_mac},
           value: %{blob: value_blob}
         },
         operation,
         key_map
       )
       when is_binary(key_id) and byte_size(key_id) > 0 and is_binary(index_mac) and
              byte_size(index_mac) == 32 and is_binary(value_blob) and
              operation in [:SET, :REMOVE] do
    with {:ok, encrypted_value, value_mac} <- split_value_blob(value_blob),
         {:ok, keys} <- fetch_keys(key_id, key_map),
         expected_value_mac =
           Crypto.value_mac(operation, encrypted_value, key_id, keys.value_mac_key),
         :ok <- verify_mac(value_mac, expected_value_mac, :invalid_value_mac),
         {:ok, plaintext} <- decrypt(encrypted_value, keys.value_encryption_key),
         {:ok, sync_action} <- decode_action(plaintext),
         expected_index_mac = Crypto.index_mac(sync_action.index, keys.index_key),
         :ok <- verify_mac(index_mac, expected_index_mac, :invalid_index_mac),
         {:ok, index} <- decode_index(sync_action.index) do
      {:ok,
       %{
         operation: operation,
         index: index,
         sync_action: sync_action,
         index_mac: index_mac,
         value_mac: value_mac
       }}
    end
  end

  defp decode_record_with_macs(_record, _operation, _key_map), do: {:error, :invalid_record}

  defp split_value_blob(value_blob) when byte_size(value_blob) >= 64 do
    encrypted_size = byte_size(value_blob) - 32
    <<encrypted_value::binary-size(encrypted_size), value_mac::binary-size(32)>> = value_blob

    if byte_size(encrypted_value) >= 32 and rem(byte_size(encrypted_value), 16) == 0 do
      {:ok, encrypted_value, value_mac}
    else
      {:error, :invalid_record}
    end
  end

  defp split_value_blob(_value_blob), do: {:error, :invalid_record}

  defp decrypt(encrypted_value, key) do
    case Crypto.decrypt_value(encrypted_value, key) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, _reason} -> {:error, :invalid_action_data}
    end
  rescue
    _error -> {:error, :invalid_action_data}
  end

  defp decode_action(plaintext) do
    action = SyncActionData.decode(plaintext)

    if is_binary(action.index) do
      {:ok, action}
    else
      {:error, :invalid_action_data}
    end
  rescue
    _error -> {:error, :invalid_action_data}
  end

  defp decode_index(index_json) do
    case Jason.decode(index_json) do
      {:ok, index} -> {:ok, index}
      {:error, _reason} -> {:error, :invalid_index_json}
    end
  end

  defp mix_mutation(state, %{operation: :SET, index_mac: index_mac, value_mac: value_mac}) do
    hash =
      case Map.fetch(state.index_value_map, index_mac) do
        {:ok, previous_value_mac} -> Crypto.lt_hash_subtract(state.hash, previous_value_mac)
        :error -> state.hash
      end

    {:ok,
     %{
       state
       | hash: Crypto.lt_hash_add(hash, value_mac),
         index_value_map: Map.put(state.index_value_map, index_mac, value_mac)
     }}
  end

  defp mix_mutation(state, %{operation: :REMOVE, index_mac: index_mac}) do
    case Map.pop(state.index_value_map, index_mac) do
      {nil, _index_value_map} ->
        {:error, {:missing_index, Base.encode64(index_mac)}}

      {previous_value_mac, index_value_map} ->
        {:ok,
         %{
           state
           | hash: Crypto.lt_hash_subtract(state.hash, previous_value_mac),
             index_value_map: index_value_map
         }}
    end
  end

  defp mutation_value_macs(mutations) when is_list(mutations) do
    Enum.reduce_while(mutations, {:ok, []}, fn
      %SyncdMutation{record: %SyncdRecord{value: %{blob: value_blob}}}, {:ok, value_macs}
      when is_binary(value_blob) ->
        case split_value_blob(value_blob) do
          {:ok, _encrypted_value, value_mac} -> {:cont, {:ok, [value_mac | value_macs]}}
          {:error, _reason} -> {:halt, {:error, :invalid_patch}}
        end

      _mutation, _accumulator ->
        {:halt, {:error, :invalid_patch}}
    end)
    |> case do
      {:ok, reversed_value_macs} -> {:ok, Enum.reverse(reversed_value_macs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mutation_value_macs(_mutations), do: {:error, :invalid_patch}

  defp snapshot_version(%SyncdVersion{version: version})
       when is_integer(version) and version >= 0 and version <= @uint64_max,
       do: {:ok, version}

  defp snapshot_version(_version), do: {:error, :invalid_snapshot}

  defp patch_version(%SyncdVersion{version: version})
       when is_integer(version) and version >= 0 and version <= @uint64_max,
       do: {:ok, version}

  defp patch_version(_version), do: {:error, :invalid_patch}

  defp verify_version(version, version), do: :ok

  defp verify_version(actual, expected) do
    {:error, {:unexpected_version, expected, actual}}
  end

  defp record_keys(%KeyId{id: key_id}, key_map)
       when is_binary(key_id) and byte_size(key_id) > 0 do
    fetch_keys(key_id, key_map)
  end

  defp record_keys(_key_id, _key_map), do: {:error, :invalid_record}

  defp fetch_keys(key_id, key_map) do
    encoded_key_id = Base.encode64(key_id)

    key_value =
      case Map.fetch(key_map, key_id) do
        {:ok, value} -> {:ok, value}
        :error -> Map.fetch(key_map, encoded_key_id)
      end

    with {:ok, value} <- key_value,
         {:ok, key_data} <- unwrap_key_data(value) do
      {:ok, Crypto.derive_keys(key_data)}
    else
      _error -> {:error, {:missing_key, encoded_key_id}}
    end
  end

  defp unwrap_key_data(key_data) when is_binary(key_data) and byte_size(key_data) > 0,
    do: {:ok, key_data}

  defp unwrap_key_data(%{keyData: key_data}), do: unwrap_key_data(key_data)
  defp unwrap_key_data(%{key_data: key_data}), do: unwrap_key_data(key_data)
  defp unwrap_key_data(_key_data), do: {:error, :invalid_key_data}

  defp verify_mac(actual, expected, reason)
       when is_binary(actual) and byte_size(actual) == 32 do
    if Crypto.secure_compare(actual, expected), do: :ok, else: {:error, reason}
  end

  defp verify_mac(_actual, _expected, reason), do: {:error, reason}

  defp validate_mac_field(mac, _reason) when is_binary(mac) and byte_size(mac) == 32, do: :ok
  defp validate_mac_field(_mac, reason), do: {:error, reason}

  defp validate_external_mutations(nil), do: :ok

  defp validate_external_mutations(_external_mutations),
    do: {:error, :external_mutations_not_supported}

  defp validate_state(%{
         version: version,
         hash: hash,
         index_value_map: index_value_map
       })
       when is_integer(version) and version >= 0 and version <= @uint64_max and is_binary(hash) and
              byte_size(hash) == 128 and is_map(index_value_map) do
    if Enum.all?(index_value_map, fn {index_mac, value_mac} ->
         is_binary(index_mac) and byte_size(index_mac) == 32 and is_binary(value_mac) and
           byte_size(value_mac) == 32
       end) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp validate_state(_state), do: {:error, :invalid_state}
end
