defmodule BaileysExo.Store.FileTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Proto.ADVSignedDeviceIdentity
  alias BaileysExo.Store.File, as: FileStore

  test "round trips credentials through versioned JSON" do
    root = temporary_root()
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    path = Path.join(root, "safe")
    File.mkdir_p!(path)
    assert :ok = FileStore.save(path, credentials)

    assert {:ok, %{"version" => 1}} =
             path |> Path.join("session.json") |> File.read!() |> Jason.decode()

    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "safe")
  end

  test "migrates safe legacy ETF and removes it" do
    root = temporary_root()
    path = Path.join(root, "legacy")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    File.write!(Path.join(path, "session.etf"), :erlang.term_to_binary(credentials))

    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "legacy")
    assert File.exists?(Path.join(path, "session.json"))
    refute File.exists?(Path.join(path, "session.etf"))
  end

  test "round trips prekeys, protobuf account and Signal sessions" do
    root = temporary_root()
    path = Path.join(root, "paired")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = paired_credentials()

    assert :ok = FileStore.save(path, credentials)
    assert {:ok, ^credentials, ^path} = FileStore.load_or_create(root, "paired")
  end

  test "rejects an unsupported JSON schema version" do
    root = temporary_root()
    path = Path.join(root, "future")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(path, "session.json"),
      Jason.encode!(%{"version" => 2, "credentials" => %{}})
    )

    assert {:error, :unsupported_session_version} = FileStore.load_or_create(root, "future")
  end

  test "rejects malformed Base64 in JSON credentials" do
    root = temporary_root()
    path = Path.join(root, "malformed")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)

    credentials = Credentials.new()
    assert :ok = FileStore.save(path, credentials)

    session_path = Path.join(path, "session.json")
    document = session_path |> File.read!() |> Jason.decode!()
    document = put_in(document, ["credentials", "adv_secret_key"], "not base64!")
    File.write!(session_path, Jason.encode!(document))

    assert {:error, :invalid_credentials} = FileStore.load_or_create(root, "malformed")
  end

  test "rejects legacy ETF containing an atom outside the persisted schema" do
    root = temporary_root()
    path = Path.join(root, "unsafe")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(root) end)

    atom_name = "baileys_untrusted_atom_#{System.unique_integer([:positive])}"
    encoded = <<131, 100, byte_size(atom_name)::16, atom_name::binary>>
    File.write!(Path.join(path, "session.etf"), encoded)

    assert {:error, :invalid_credentials} = FileStore.load_or_create(root, "unsafe")
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
        lid_mappings: %{"5511999999999@s.whatsapp.net" => "1@lid"}
    }
  end
end
