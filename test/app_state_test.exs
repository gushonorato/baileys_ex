defmodule BaileysExo.AppStateTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias BaileysExo.AppState.{Crypto, Decoder}
  alias BaileysExo.AppState
  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.{Node, NodeUtils}
  alias BaileysExo.Crypto, as: CoreCrypto

  alias BaileysExo.Proto.{
    KeyId,
    Message,
    SyncActionData,
    SyncActionValue,
    SyncdIndex,
    SyncdMutation,
    SyncdPatch,
    SyncdRecord,
    SyncdSnapshot,
    SyncdValue,
    SyncdVersion
  }

  @collection "regular"
  @key_id <<0x10, 0x20, 0x30, 0x40>>
  @key_data :erlang.list_to_binary(Enum.to_list(0..31))
  @empty_hash <<0::size(128)-unit(8)>>

  test "derives and splits mutation keys and generates protocol MACs" do
    keys = Crypto.derive_keys(@key_data)
    expanded = CoreCrypto.hkdf(@key_data, 160, info: "WhatsApp Mutation Keys")

    assert keys.index_key <>
             keys.value_encryption_key <>
             keys.value_mac_key <>
             keys.snapshot_mac_key <> keys.patch_mac_key == expanded

    assert Enum.all?(Map.values(keys), &(byte_size(&1) == 32))
    assert Crypto.uint64_be(0x0102030405060708) == <<1, 2, 3, 4, 5, 6, 7, 8>>

    encrypted_value = :erlang.list_to_binary(Enum.to_list(0..47))
    key_data = <<0x01>> <> @key_id

    expected_value_mac =
      :crypto.mac(
        :hmac,
        :sha512,
        keys.value_mac_key,
        key_data <> encrypted_value <> <<byte_size(key_data)::unsigned-big-64>>
      )
      |> binary_part(0, 32)

    assert Crypto.value_mac(:SET, encrypted_value, @key_id, keys.value_mac_key) ==
             expected_value_mac

    index_json = Jason.encode!(["mute", "15550000000@s.whatsapp.net"])

    assert Crypto.index_mac(index_json, keys.index_key) ==
             :crypto.mac(:hmac, :sha256, keys.index_key, index_json)

    snapshot_mac =
      :crypto.mac(
        :hmac,
        :sha256,
        keys.snapshot_mac_key,
        @empty_hash <> <<7::unsigned-big-64>> <> @collection
      )

    assert Crypto.snapshot_mac(@empty_hash, 7, @collection, keys.snapshot_mac_key) ==
             snapshot_mac

    assert Crypto.patch_mac(
             snapshot_mac,
             [expected_value_mac],
             7,
             @collection,
             keys.patch_mac_key
           ) ==
             :crypto.mac(
               :hmac,
               :sha256,
               keys.patch_mac_key,
               snapshot_mac <> expected_value_mac <> <<7::unsigned-big-64>> <> @collection
             )
  end

  test "LT-hash adds and subtracts 128-byte little-endian uint16 vectors with overflow" do
    value_mac = :erlang.list_to_binary(Enum.to_list(32..63))
    initial = :binary.copy(<<0xFFFF::unsigned-little-16>>, 64)
    expanded = CoreCrypto.hkdf(value_mac, 128, info: "WhatsApp Patch Integrity")

    <<expanded_first::unsigned-little-16, _::binary>> = expanded
    <<actual_first::unsigned-little-16, _::binary>> = Crypto.lt_hash_add(initial, value_mac)

    assert actual_first == band(0xFFFF + expanded_first, 0xFFFF)

    assert initial |> Crypto.lt_hash_add(value_mac) |> Crypto.lt_hash_subtract(value_mac) ==
             initial

    assert Crypto.lt_hash_subtract(@empty_hash, value_mac) |> Crypto.lt_hash_add(value_mac) ==
             @empty_hash
  end

  test "applies a snapshot then consecutive overwrite, add, and remove patches" do
    mute_index = ["mute", "15550000001@s.whatsapp.net"]
    pin_index = ["pin_v1", "15550000002@s.whatsapp.net"]

    {snapshot, expected_snapshot_state, initial_record} =
      snapshot_fixture(mute_index, mute_action(false, 1), fixed_iv(1))

    assert {:ok, snapshot_state, [snapshot_mutation]} =
             Decoder.apply_snapshot(snapshot, @collection, key_map())

    assert snapshot_state == expected_snapshot_state
    assert snapshot_mutation.operation == :SET
    assert snapshot_mutation.index == mute_index
    assert snapshot_mutation.sync_action.value.muteAction.muted == false

    {overwrite_patch, overwrite_state, overwrite_record} =
      patch_fixture(
        snapshot_state,
        :SET,
        mute_index,
        mute_action(true, 2),
        fixed_iv(2)
      )

    {add_patch, add_state, add_record} =
      patch_fixture(
        overwrite_state,
        :SET,
        pin_index,
        pin_action(true, 3),
        fixed_iv(3)
      )

    {remove_patch, expected_final_state, _remove_record} =
      patch_fixture(
        add_state,
        :REMOVE,
        mute_index,
        mute_action(false, 4),
        fixed_iv(4)
      )

    assert {:ok, final_state, mutations} =
             Decoder.apply_patches(
               snapshot_state,
               [overwrite_patch, add_patch, remove_patch],
               @collection,
               key_map()
             )

    assert final_state == expected_final_state
    assert final_state.version == 4
    assert Map.keys(final_state.index_value_map) == [add_record.index_mac]
    assert final_state.index_value_map[add_record.index_mac] == add_record.value_mac
    refute final_state.index_value_map[initial_record.index_mac]
    refute initial_record.value_mac == overwrite_record.value_mac

    assert Enum.map(mutations, &{&1.operation, &1.index}) == [
             {:SET, mute_index},
             {:SET, pin_index},
             {:REMOVE, mute_index}
           ]

    assert Enum.at(mutations, 0).sync_action.value.muteAction.muted
    assert Enum.at(mutations, 1).sync_action.value.pinAction.pinned
  end

  test "strictly rejects record and snapshot MAC failures without returning state" do
    index = ["mute", "15550000003@s.whatsapp.net"]

    {snapshot, _expected_state, record_data} =
      snapshot_fixture(index, mute_action(true, 1), fixed_iv(5))

    record = hd(snapshot.records)
    bad_value = %{record.value | blob: flip_last(record.value.blob)}
    bad_value_snapshot = %{snapshot | records: [%{record | value: bad_value}]}

    assert Decoder.apply_snapshot(bad_value_snapshot, @collection, key_map()) ==
             {:error, :invalid_value_mac}

    bad_index = %{record.index | blob: flip_last(record.index.blob)}
    bad_index_snapshot = %{snapshot | records: [%{record | index: bad_index}]}

    assert Decoder.apply_snapshot(bad_index_snapshot, @collection, key_map()) ==
             {:error, :invalid_index_mac}

    assert Decoder.apply_snapshot(
             %{snapshot | mac: flip_last(snapshot.mac)},
             @collection,
             key_map()
           ) ==
             {:error, :invalid_snapshot_mac}

    assert {:ok, decoded} = Decoder.decode_record(record, :SET, key_map())
    assert decoded.index == index
    assert record_data.index_mac == record.index.blob
  end

  test "patch application is transactional across MAC failure and version discontinuity" do
    index = ["mute", "15550000004@s.whatsapp.net"]

    {snapshot, _expected_state, _record} =
      snapshot_fixture(index, mute_action(false, 1), fixed_iv(6))

    assert {:ok, state, _mutations} = Decoder.apply_snapshot(snapshot, @collection, key_map())

    {patch, next_state, record_data} =
      patch_fixture(state, :SET, index, mute_action(true, 2), fixed_iv(7))

    bad_patch = %{patch | patchMac: flip_last(patch.patchMac)}

    assert Decoder.apply_patch(state, bad_patch, @collection, key_map()) ==
             {:error, :invalid_patch_mac}

    {second_patch, _final_state, _record} =
      patch_fixture(next_state, :SET, index, mute_action(false, 3), fixed_iv(9))

    bad_second_patch = %{second_patch | patchMac: flip_last(second_patch.patchMac)}

    assert Decoder.apply_patches(state, [patch, bad_second_patch], @collection, key_map()) ==
             {:error, :invalid_patch_mac}

    keys = Crypto.derive_keys(@key_data)
    bad_snapshot_mac = flip_last(patch.snapshotMac)

    bad_snapshot_patch = %{
      patch
      | snapshotMac: bad_snapshot_mac,
        patchMac:
          Crypto.patch_mac(
            bad_snapshot_mac,
            [record_data.value_mac],
            2,
            @collection,
            keys.patch_mac_key
          )
    }

    assert Decoder.apply_patch(state, bad_snapshot_patch, @collection, key_map()) ==
             {:error, :invalid_snapshot_mac}

    assert Decoder.apply_patches(state, [patch, patch], @collection, key_map()) ==
             {:error, {:unexpected_version, 3, 2}}

    {gap_patch, _gap_state, _record} =
      patch_fixture(state, :SET, index, mute_action(true, 2), fixed_iv(8), 3)

    assert Decoder.apply_patch(state, gap_patch, @collection, key_map()) ==
             {:error, {:unexpected_version, 2, 3}}

    assert state.version == 1
    assert next_state.version == 2
  end

  test "stores key shares and advances a pending collection response transactionally" do
    key_data = %Message.AppStateSyncKeyData{keyData: @key_data, timestamp: 1}

    share = %Message{
      protocolMessage: %Message.ProtocolMessage{
        type: :APP_STATE_SYNC_KEY_SHARE,
        appStateSyncKeyShare: %Message.AppStateSyncKeyShare{
          keys: [
            %Message.AppStateSyncKey{
              keyId: %Message.AppStateSyncKeyId{keyId: @key_id},
              keyData: key_data
            }
          ]
        }
      }
    }

    credentials = %Credentials{pending_app_state_sync: [@collection]}
    assert {:ok, credentials} = AppState.process_key_share(share, credentials, true)
    assert credentials.my_app_state_key_id == Base.encode64(@key_id)

    request = AppState.request_node([@collection], credentials)
    collection = request |> NodeUtils.child("sync") |> NodeUtils.child("collection")
    assert collection.attrs["version"] == "0"
    assert collection.attrs["return_snapshot"] == "true"

    {snapshot, expected_state, _record} =
      snapshot_fixture(["mute", "15550000005@s.whatsapp.net"], mute_action(true, 1), fixed_iv(10))

    response = %Node{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %Node{
          tag: "sync",
          content: [
            %Node{
              tag: "collection",
              attrs: %{"name" => @collection},
              content: [%Node{tag: "snapshot", content: Protobuf.encode(snapshot)}]
            }
          ]
        }
      ]
    }

    assert {:ok, updated, [mutation]} = AppState.process_response(response, credentials)
    assert updated.app_state_collections[@collection] == expected_state
    assert updated.pending_app_state_sync == []
    assert mutation.collection == @collection
    assert mutation.version == 1
    assert mutation.operation == :SET
  end

  defp snapshot_fixture(index, value, iv) do
    record_data = record_fixture(index, value, :SET, iv)
    state = mix_fixture(Decoder.empty_state(), :SET, record_data)
    state = %{state | version: 1}
    keys = Crypto.derive_keys(@key_data)

    snapshot = %SyncdSnapshot{
      version: %SyncdVersion{version: state.version},
      records: [record_data.record],
      mac: Crypto.snapshot_mac(state.hash, state.version, @collection, keys.snapshot_mac_key),
      keyId: %KeyId{id: @key_id}
    }

    {snapshot, state, record_data}
  end

  defp patch_fixture(state, operation, index, value, iv, version \\ nil) do
    version = version || state.version + 1
    record_data = record_fixture(index, value, operation, iv)
    mixed_state = mix_fixture(state, operation, record_data)
    next_state = %{mixed_state | version: version}
    keys = Crypto.derive_keys(@key_data)

    snapshot_mac =
      Crypto.snapshot_mac(next_state.hash, version, @collection, keys.snapshot_mac_key)

    patch = %SyncdPatch{
      version: %SyncdVersion{version: version},
      mutations: [%SyncdMutation{operation: operation, record: record_data.record}],
      snapshotMac: snapshot_mac,
      patchMac:
        Crypto.patch_mac(
          snapshot_mac,
          [record_data.value_mac],
          version,
          @collection,
          keys.patch_mac_key
        ),
      keyId: %KeyId{id: @key_id}
    }

    {patch, next_state, record_data}
  end

  defp record_fixture(index, value, operation, iv) do
    keys = Crypto.derive_keys(@key_data)
    index_json = Jason.encode!(index)

    action_data = %SyncActionData{
      index: index_json,
      value: value,
      padding: <<>>,
      version: 1
    }

    ciphertext =
      action_data
      |> Protobuf.encode()
      |> CoreCrypto.aes_cbc_encrypt(keys.value_encryption_key, iv)

    encrypted_value = iv <> ciphertext
    value_mac = Crypto.value_mac(operation, encrypted_value, @key_id, keys.value_mac_key)
    index_mac = Crypto.index_mac(index_json, keys.index_key)

    record = %SyncdRecord{
      index: %SyncdIndex{blob: index_mac},
      value: %SyncdValue{blob: encrypted_value <> value_mac},
      keyId: %KeyId{id: @key_id}
    }

    %{record: record, index_mac: index_mac, value_mac: value_mac}
  end

  defp mix_fixture(state, :SET, record_data) do
    hash =
      case Map.fetch(state.index_value_map, record_data.index_mac) do
        {:ok, previous} -> Crypto.lt_hash_subtract(state.hash, previous)
        :error -> state.hash
      end

    %{
      state
      | hash: Crypto.lt_hash_add(hash, record_data.value_mac),
        index_value_map:
          Map.put(state.index_value_map, record_data.index_mac, record_data.value_mac)
    }
  end

  defp mix_fixture(state, :REMOVE, record_data) do
    previous = Map.fetch!(state.index_value_map, record_data.index_mac)

    %{
      state
      | hash: Crypto.lt_hash_subtract(state.hash, previous),
        index_value_map: Map.delete(state.index_value_map, record_data.index_mac)
    }
  end

  defp key_map do
    %{
      Base.encode64(@key_id) => %Message.AppStateSyncKeyData{keyData: @key_data}
    }
  end

  defp mute_action(muted, timestamp) do
    %SyncActionValue{
      timestamp: timestamp,
      muteAction: %SyncActionValue.MuteAction{muted: muted, muteEndTimestamp: timestamp * 1000}
    }
  end

  defp pin_action(pinned, timestamp) do
    %SyncActionValue{
      timestamp: timestamp,
      pinAction: %SyncActionValue.PinAction{pinned: pinned}
    }
  end

  defp fixed_iv(byte), do: :binary.copy(<<byte>>, 16)

  defp flip_last(binary) do
    size = byte_size(binary) - 1
    <<prefix::binary-size(size), last>> = binary
    prefix <> <<bxor(last, 1)>>
  end
end
