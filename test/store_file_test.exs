defmodule Baileys.Store.FileTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Proto.{ADVSignedDeviceIdentity, Message}
  alias Baileys.Signal.SenderKey
  alias Baileys.Store
  alias Baileys.Store.File, as: FileStore
  alias Baileys.Store.JSONCodec

  test "round trips credentials through versioned JSON" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    path = Path.join(root, "safe.json")
    assert {:ok, _created, store} = open(root, "safe")
    assert :ok = Store.save(store, credentials)

    assert {:ok, %{"version" => 4}} =
             path |> File.read!() |> Jason.decode()

    assert {:ok, ^credentials, _store} = open(root, "safe")
  end

  test "adapter writes atomically with private permissions and deletes idempotently" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, state} = FileStore.init(root: root)
    assert :ok = FileStore.put(state, "atomic", "first")
    assert :ok = FileStore.put(state, "atomic", "second")
    assert {:ok, "second"} = FileStore.fetch(state, "atomic")

    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(Path.join(root, "atomic.json")).mode, 0o777) == 0o600
    assert Path.wildcard(Path.join(root, "atomic.json.tmp-*")) == []

    assert :ok = FileStore.delete(state, "atomic")
    assert :ok = FileStore.delete(state, "atomic")
    assert :not_found = FileStore.fetch(state, "atomic")
  end

  test "migrates JSON from the session directory and removes the empty directory" do
    root = temporary_root()
    legacy_directory = Path.join(root, "legacy-json")
    legacy_path = Path.join(legacy_directory, "session.json")
    path = Path.join(root, "legacy-json.json")
    File.mkdir_p!(legacy_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    {:ok, payload} = JSONCodec.encode(credentials)
    File.write!(legacy_path, payload)

    assert {:ok, ^credentials, _store} = open(root, "legacy-json")
    assert File.exists?(path)
    refute File.exists?(legacy_directory)
  end

  test "migrates safe legacy ETF and removes it" do
    root = temporary_root()
    legacy_directory = Path.join(root, "legacy")
    path = Path.join(root, "legacy.json")
    File.mkdir_p!(legacy_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()

    File.write!(
      Path.join(legacy_directory, "session.etf"),
      :erlang.term_to_binary(credentials)
    )

    assert {:ok, ^credentials, _store} = open(root, "legacy")
    assert File.exists?(path)
    refute File.exists?(legacy_directory)
    refute match?(<<131, _::binary>>, File.read!(path))
  end

  test "migrates legacy ETF credentials created before sender-key storage" do
    root = temporary_root()
    legacy_directory = Path.join(root, "legacy-old-struct")
    path = Path.join(root, "legacy-old-struct.json")
    File.mkdir_p!(legacy_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()

    legacy_credentials =
      credentials
      |> Map.from_struct()
      |> Map.delete(:sender_keys)
      |> Map.put(:__struct__, Credentials)

    File.write!(
      Path.join(legacy_directory, "session.etf"),
      :erlang.term_to_binary(legacy_credentials)
    )

    assert {:ok, ^credentials, _store} = open(root, "legacy-old-struct")
    assert File.exists?(path)
    refute File.exists?(legacy_directory)
  end

  test "round trips prekeys, protobuf account and Signal sessions" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = paired_credentials()

    assert {:ok, _created, store} = open(root, "paired")
    assert :ok = Store.save(store, credentials)
    assert {:ok, ^credentials, _store} = open(root, "paired")
  end

  test "rejects an unsupported JSON schema version" do
    root = temporary_root()
    path = Path.join(root, "future.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(path, Jason.encode!(%{"version" => 5, "credentials" => %{}}))

    assert {:error, {:store, :unsupported_session_version}} = open(root, "future")
  end

  test "migrates all previous JSON schema versions" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()

    for {version, removed} <- [
          {1, ["sender_keys", "account_settings", "privacy_tokens", "pending_app_state_sync"]},
          {2, ["account_settings", "privacy_tokens", "pending_app_state_sync"]},
          {3,
           [
             "history_sync_progress",
             "pending_history_sync",
             "app_state_sync_keys",
             "app_state_collections",
             "my_app_state_key_id"
           ]}
        ] do
      session = "version-#{version}"
      path = Path.join(root, "#{session}.json")
      {:ok, payload} = JSONCodec.encode(credentials)

      document =
        payload
        |> Jason.decode!()
        |> Map.put("version", version)
        |> update_in(["credentials"], &Map.drop(&1, removed))

      File.mkdir_p!(root)
      File.write!(path, Jason.encode!(document))
      assert {:ok, ^credentials, _store} = open(root, session)
    end
  end

  test "rejects malformed Base64 in JSON credentials" do
    root = temporary_root()
    path = Path.join(root, "malformed.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    {:ok, payload} = JSONCodec.encode(credentials)
    File.write!(path, payload)

    document = path |> File.read!() |> Jason.decode!()
    document = put_in(document, ["credentials", "adv_secret_key"], "not base64!")
    File.write!(path, Jason.encode!(document))

    assert {:error, {:store, :invalid_credentials}} = open(root, "malformed")
  end

  test "rejects legacy ETF containing an atom outside the persisted schema" do
    root = temporary_root()
    legacy_directory = Path.join(root, "unsafe")
    File.mkdir_p!(legacy_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    atom_name = "baileys_untrusted_atom_#{System.unique_integer([:positive])}"
    encoded = <<131, 100, byte_size(atom_name)::16, atom_name::binary>>
    File.write!(Path.join(legacy_directory, "session.etf"), encoded)

    assert {:error, {:store, :invalid_credentials}} = open(root, "unsafe")
  end

  test "requires an absolute root" do
    assert {:error, :root_required} = FileStore.init([])
    assert {:error, :root_must_be_absolute} = FileStore.init(root: "relative/sessions")
    assert {:error, :invalid_root} = FileStore.init(root: nil)
  end

  defp temporary_root do
    Path.join(System.tmp_dir!(), "baileys-store-#{System.unique_integer([:positive])}")
  end

  defp open(root, session), do: Store.open({FileStore, root: root}, session)

  defp paired_credentials do
    credentials = Credentials.new()
    key_pair = credentials.noise_key

    session = %{
      chains: %{
        "chain-id" => %{
          message_keys: %{3 => <<1, 2, 3>>},
          chain_key: %{counter: 3, key: <<4, 5, 6>>},
          chain_type: 1
        }
      },
      registration_id: 42,
      current_ratchet: %{
        root_key: <<7, 8, 9>>,
        ephemeral_key_pair: key_pair,
        last_remote_ephemeral_key: <<10, 11, 12>>,
        previous_counter: 2
      },
      index_info: %{
        created: 1,
        used: 2,
        remote_identity_key: <<13, 14, 15>>,
        base_key: <<16, 17, 18>>,
        base_key_type: 1,
        closed: -1
      },
      pending_pre_key: %{signed_key_id: 1, pre_key_id: nil, base_key: <<19, 20, 21>>}
    }

    private = :binary.copy(<<31>>, 32)
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)

    sender_key =
      SenderKey.new_record(
        SenderKey.new_state(7, 2, :binary.copy(<<32>>, 32), %{
          public: public,
          private: private
        })
      )

    %{
      credentials
      | me: %{id: "5511999999999:1@s.whatsapp.net", name: "Test", lid: "1:1@lid"},
        account: %ADVSignedDeviceIdentity{
          details: <<22>>,
          accountSignatureKey: <<23>>,
          accountSignature: <<24>>,
          deviceSignature: <<25>>
        },
        platform: "smbi",
        routing_info: <<26, 27>>,
        registered?: true,
        pre_keys: %{7 => key_pair},
        sessions: %{"5511999999999.1" => %{sessions: %{"session-id" => session}}},
        sender_keys: %{"fixture-group@g.us::1_1::2" => sender_key},
        lid_mappings: %{"5511999999999@s.whatsapp.net" => "1@lid"},
        account_settings: %{
          default_disappearing_mode: %{
            ephemeral_expiration: 86_400,
            ephemeral_setting_timestamp: 1_700_000_000
          }
        },
        privacy_tokens: %{"1@lid" => %{token: <<33, 34>>, timestamp: 1_700_000_000}},
        pending_app_state_sync: ["critical_block", "regular"],
        history_sync_progress: %{
          "history-request" => %{
            sync_type: :recent,
            progress: 50,
            chunk_order: 2,
            request_id: "history-request",
            peer_data_request_session_id: nil,
            original_message_id: "history-message"
          }
        },
        app_state_sync_keys: %{
          "a2V5" => %Message.AppStateSyncKeyData{keyData: :binary.copy(<<35>>, 32), timestamp: 1}
        },
        app_state_collections: %{
          "regular" => %{
            version: 1,
            hash: :binary.copy(<<0>>, 128),
            index_value_map: %{:binary.copy(<<36>>, 32) => :binary.copy(<<37>>, 32)}
          }
        },
        my_app_state_key_id: "a2V5"
    }
  end
end
