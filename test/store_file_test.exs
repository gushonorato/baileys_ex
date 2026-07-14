defmodule BaileysExo.Store.FileTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Proto.ADVSignedDeviceIdentity
  alias BaileysExo.Signal.SenderKey
  alias BaileysExo.Store.File, as: FileStore

  test "round trips credentials through versioned JSON" do
    root = temporary_root()
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    path = Path.join(root, "safe.json")
    assert :ok = FileStore.save(path, credentials)

    assert {:ok, %{"version" => 3}} =
             path |> File.read!() |> Jason.decode()

    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "safe")
  end

  test "migrates JSON from the session directory and removes the empty directory" do
    root = temporary_root()
    legacy_directory = Path.join(root, "legacy-json")
    legacy_path = Path.join(legacy_directory, "session.json")
    path = Path.join(root, "legacy-json.json")
    File.mkdir_p!(legacy_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    assert :ok = FileStore.save(legacy_path, credentials)

    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "legacy-json")
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

    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "legacy")
    assert File.exists?(path)
    refute File.exists?(legacy_directory)
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

    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "legacy-old-struct")
    assert File.exists?(path)
    refute File.exists?(legacy_directory)
  end

  test "round trips prekeys, protobuf account and Signal sessions" do
    root = temporary_root()
    path = Path.join(root, "paired.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = paired_credentials()

    assert :ok = FileStore.save(path, credentials)
    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "paired")
  end

  test "rejects an unsupported JSON schema version" do
    root = temporary_root()
    path = Path.join(root, "future.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(path, Jason.encode!(%{"version" => 4, "credentials" => %{}}))

    assert {:error, :unsupported_session_version} = FileStore.load_or_create(root, "future")
  end

  test "migrates version one JSON with empty sender-key storage" do
    root = temporary_root()
    path = Path.join(root, "version-one.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    assert :ok = FileStore.save(path, credentials)
    document = path |> File.read!() |> Jason.decode!()

    document =
      document
      |> Map.put("version", 1)
      |> update_in(["credentials"], &Map.delete(&1, "sender_keys"))

    File.write!(path, Jason.encode!(document))
    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "version-one")
  end

  test "migrates version two JSON with empty account settings" do
    root = temporary_root()
    path = Path.join(root, "version-two.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    assert :ok = FileStore.save(path, credentials)
    document = path |> File.read!() |> Jason.decode!()

    document =
      document
      |> Map.put("version", 2)
      |> update_in(["credentials"], &Map.delete(&1, "account_settings"))

    File.write!(path, Jason.encode!(document))
    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "version-two")
  end

  test "rejects malformed Base64 in JSON credentials" do
    root = temporary_root()
    path = Path.join(root, "malformed.json")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    assert :ok = FileStore.save(path, credentials)

    document = path |> File.read!() |> Jason.decode!()
    document = put_in(document, ["credentials", "adv_secret_key"], "not base64!")
    File.write!(path, Jason.encode!(document))

    assert {:error, :invalid_credentials} = FileStore.load_or_create(root, "malformed")
  end

  test "rejects legacy ETF containing an atom outside the persisted schema" do
    root = temporary_root()
    legacy_directory = Path.join(root, "unsafe")
    File.mkdir_p!(legacy_directory)
    on_exit(fn -> File.rm_rf!(root) end)

    atom_name = "baileys_untrusted_atom_#{System.unique_integer([:positive])}"
    encoded = <<131, 100, byte_size(atom_name)::16, atom_name::binary>>
    File.write!(Path.join(legacy_directory, "session.etf"), encoded)

    assert {:error, :invalid_credentials} = FileStore.load_or_create(root, "unsafe")
  end

  test "requires an absolute sessions path" do
    assert {:error, :sessions_path_required} = FileStore.load_or_create(nil, "missing")

    assert {:error, :sessions_path_must_be_absolute} =
             FileStore.load_or_create("relative/sessions", "relative")
  end

  defp temporary_root do
    Path.join(System.tmp_dir!(), "baileys-store-#{System.unique_integer([:positive])}")
  end

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
        pending_app_state_sync: ["critical_block", "regular"]
    }
  end
end
