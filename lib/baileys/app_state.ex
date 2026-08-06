defmodule Baileys.AppState do
  @moduledoc false

  alias Baileys.AppState.Decoder
  alias Baileys.Auth.Credentials
  alias Baileys.Binary.{Node, NodeUtils}
  alias Baileys.Crypto
  alias Baileys.Media.Download
  alias Baileys.Proto.{ExternalBlobReference, SyncdMutations, SyncdPatch, SyncdSnapshot}
  alias Baileys.Proto.Message

  def request_node(collections, %Credentials{} = credentials) when is_list(collections) do
    children =
      Enum.map(collections, fn name ->
        state = credentials.app_state_collections[name] || Decoder.empty_state()

        %Node{
          tag: "collection",
          attrs: %{
            "name" => name,
            "version" => Integer.to_string(state.version),
            "return_snapshot" => if(state.version == 0, do: "true", else: "false")
          }
        }
      end)

    %Node{
      tag: "iq",
      attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "w:sync:app:state"},
      content: [%Node{tag: "sync", content: children}]
    }
  end

  def process_response(response, credentials, options \\ [])

  def process_response(%Node{} = response, %Credentials{} = credentials, options) do
    with %Node{} = sync <- NodeUtils.child(response, "sync") do
      sync
      |> NodeUtils.children("collection")
      |> Enum.reduce_while({:ok, credentials, []}, fn collection, {:ok, credentials, effects} ->
        case process_collection(collection, credentials, options) do
          {:ok, credentials, mutations} ->
            {:cont, {:ok, credentials, effects ++ mutations}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    else
      _missing -> {:error, :invalid_app_state_response}
    end
  end

  def process_response(_response, _credentials, _options),
    do: {:error, :invalid_app_state_response}

  def process_key_share(message, credentials, from_me \\ false)

  def process_key_share(%Message{} = message, %Credentials{} = credentials, true) do
    message = (message.deviceSentMessage && message.deviceSentMessage.message) || message

    case message.protocolMessage do
      %Message.ProtocolMessage{appStateSyncKeyShare: %{keys: keys}} when is_list(keys) ->
        {stored, current} =
          Enum.reduce(keys, {credentials.app_state_sync_keys, credentials.my_app_state_key_id}, fn
            %{keyId: %{keyId: id}, keyData: key_data}, {stored, _current}
            when is_binary(id) and byte_size(id) > 0 and not is_nil(key_data) ->
              encoded = Base.encode64(id)
              {Map.put(stored, encoded, key_data), encoded}

            _invalid, accumulator ->
              accumulator
          end)

        {:ok, %{credentials | app_state_sync_keys: stored, my_app_state_key_id: current}}

      _other ->
        {:ok, credentials}
    end
  end

  def process_key_share(%Message{}, %Credentials{} = credentials, false), do: {:ok, credentials}

  def project_effects(mutations) do
    Enum.map(mutations, fn mutation ->
      %{type: effect_type(mutation.index), data: mutation}
    end)
  end

  defp process_collection(%Node{attrs: %{"name" => name}} = collection, credentials, options) do
    state = credentials.app_state_collections[name] || Decoder.empty_state()
    key_map = credentials.app_state_sync_keys

    with {:ok, state, snapshot_mutations} <-
           apply_snapshot_node(collection, state, name, key_map, options),
         {:ok, patches} <- patch_nodes(collection, options),
         {:ok, state, patch_mutations} <- Decoder.apply_patches(state, patches, name, key_map) do
      mutations =
        Enum.map(snapshot_mutations ++ patch_mutations, fn mutation ->
          Map.merge(mutation, %{collection: name, version: state.version})
        end)

      pending =
        if collection.attrs["has_more_patches"] == "true",
          do: List.delete(credentials.pending_app_state_sync, name) ++ [name],
          else: List.delete(credentials.pending_app_state_sync, name)

      lid_mappings = apply_lid_mappings(credentials.lid_mappings, mutations)

      credentials = %{
        credentials
        | app_state_collections: Map.put(credentials.app_state_collections, name, state),
          pending_app_state_sync: pending,
          lid_mappings: lid_mappings
      }

      {:ok, credentials, mutations}
    end
  rescue
    _error -> {:error, :invalid_app_state_response}
  end

  defp process_collection(_collection, _credentials, _options),
    do: {:error, :invalid_app_state_response}

  defp apply_snapshot_node(collection, state, name, key_map, options) do
    case NodeUtils.child(collection, "snapshot") do
      %Node{content: content} when is_binary(content) ->
        case external_reference(content) do
          %ExternalBlobReference{} = reference ->
            with {:ok, plaintext} <- download_external(reference, options) do
              Decoder.apply_snapshot(SyncdSnapshot.decode(plaintext), name, key_map)
            end

          nil ->
            Decoder.apply_snapshot(SyncdSnapshot.decode(content), name, key_map)
        end

      _missing ->
        {:ok, state, []}
    end
  end

  defp patch_nodes(collection, options) do
    nested =
      collection
      |> NodeUtils.children("patches")
      |> Enum.flat_map(&NodeUtils.children(&1, "patch"))

    direct = NodeUtils.children(collection, "patch")

    Enum.reduce_while(nested ++ direct, {:ok, []}, fn %Node{content: content}, {:ok, patches} ->
      patch = SyncdPatch.decode(content)
      patch = put_missing_patch_version(patch, collection)

      case expand_external_mutations(patch, options) do
        {:ok, patch} -> {:cont, {:ok, [patch | patches]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, patches} -> {:ok, Enum.reverse(patches)}
      error -> error
    end
  end

  defp put_missing_patch_version(%SyncdPatch{version: nil} = patch, collection) do
    case Integer.parse(collection.attrs["version"] || "") do
      {version, ""} when version >= 0 ->
        %{patch | version: %Baileys.Proto.SyncdVersion{version: version + 1}}

      _invalid ->
        patch
    end
  end

  defp put_missing_patch_version(patch, _collection), do: patch

  defp expand_external_mutations(%SyncdPatch{externalMutations: nil} = patch, _options),
    do: {:ok, patch}

  defp expand_external_mutations(%SyncdPatch{externalMutations: reference} = patch, options) do
    with {:ok, plaintext} <- download_external(reference, options) do
      external = SyncdMutations.decode(plaintext)
      {:ok, %{patch | mutations: patch.mutations ++ external.mutations, externalMutations: nil}}
    end
  rescue
    _error -> {:error, :invalid_external_mutations}
  end

  defp external_reference(content) do
    reference = ExternalBlobReference.decode(content)
    if is_binary(reference.directPath) and reference.directPath != "", do: reference
  rescue
    _error -> nil
  end

  defp download_external(%ExternalBlobReference{} = reference, options) do
    downloader = Keyword.get(options, :downloader, &Download.get/1)

    with {:ok, downloaded} <- downloader.(reference.directPath),
         :ok <- optional_hash(downloaded, reference.fileEncSha256, :encrypted_sha256_mismatch),
         {:ok, ciphertext, mac} <- split_blob(downloaded),
         <<iv::binary-size(16), cipher_key::binary-size(32), mac_key::binary-size(32), _::binary>> <-
           Crypto.hkdf(reference.mediaKey, 112, info: "WhatsApp App State Keys"),
         expected <- Crypto.hmac_sha256(mac_key, iv <> ciphertext) |> binary_part(0, 10),
         true <- :crypto.hash_equals(mac, expected) || {:error, :media_mac_mismatch},
         {:ok, plaintext} <- Crypto.aes_cbc_decrypt(ciphertext, cipher_key, iv),
         :ok <- optional_size(plaintext, reference.fileSizeBytes),
         :ok <- optional_hash(plaintext, reference.fileSha256, :plaintext_sha256_mismatch) do
      {:ok, plaintext}
    else
      false -> {:error, :media_mac_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_external_blob}
    end
  end

  defp split_blob(bytes) when is_binary(bytes) and byte_size(bytes) >= 26 do
    size = byte_size(bytes) - 10

    if rem(size, 16) == 0 do
      <<ciphertext::binary-size(size), mac::binary-size(10)>> = bytes
      {:ok, ciphertext, mac}
    else
      {:error, :invalid_external_blob}
    end
  end

  defp split_blob(_bytes), do: {:error, :invalid_external_blob}

  defp optional_hash(_value, hash, _reason) when hash in [nil, ""], do: :ok

  defp optional_hash(value, hash, reason) when is_binary(hash) and byte_size(hash) == 32 do
    if :crypto.hash_equals(Crypto.sha256(value), hash), do: :ok, else: {:error, reason}
  end

  defp optional_hash(_value, _hash, reason), do: {:error, reason}

  defp optional_size(_value, size) when size in [nil, 0], do: :ok
  defp optional_size(value, size) when is_integer(size) and byte_size(value) == size, do: :ok
  defp optional_size(_value, _size), do: {:error, :file_size_mismatch}

  defp apply_lid_mappings(mappings, mutations) do
    Enum.reduce(mutations, mappings, fn mutation, mappings ->
      value = mutation.sync_action.value

      case {value && value.pnForLidChatAction, mutation.index} do
        {%{pnJid: pn}, [_kind, lid | _]}
        when is_binary(pn) and pn != "" and is_binary(lid) and lid != "" ->
          Map.put(mappings, pn, lid)

        _other ->
          mappings
      end
    end)
  end

  defp effect_type([kind | _]) when kind in ["mute", "archive", "markChatAsRead", "pin_v1"],
    do: :chats_update

  defp effect_type(["deleteChat" | _]), do: :chats_delete
  defp effect_type([kind | _]) when kind in ["deleteMessageForMe", "star"], do: :messages_update
  defp effect_type([kind | _]) when kind in ["contact", "lidContact"], do: :contacts_upsert
  defp effect_type(["pnForLidChat" | _]), do: :lid_mapping_update
  defp effect_type(["label_edit" | _]), do: :labels_edit
  defp effect_type(["label_jid" | _]), do: :labels_association
  defp effect_type(["lockChat" | _]), do: :chats_lock
  defp effect_type(["setting_" <> _setting | _]), do: :settings_update
  defp effect_type(_index), do: :internal
end
