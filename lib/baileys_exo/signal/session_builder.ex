defmodule BaileysExo.Signal.SessionBuilder do
  @moduledoc false

  alias BaileysExo.Crypto
  alias BaileysExo.Crypto.XEdDSA
  alias BaileysExo.Signal.SessionRecord

  def init_incoming(record, message, credentials) do
    record = record || SessionRecord.new()

    case SessionRecord.get_session(record, message.base_key) do
      nil ->
        pre_key = message.pre_key_id && credentials.pre_keys[message.pre_key_id]

        cond do
          message.pre_key_id && is_nil(pre_key) ->
            {:error, :missing_pre_key}

          message.signed_pre_key_id != credentials.signed_pre_key.key_id ->
            {:error, :missing_signed_pre_key}

          true ->
            session = build_incoming_session(message, credentials, pre_key)

            record =
              record |> SessionRecord.close_open_session() |> SessionRecord.set_session(session)

            {:ok, record, message.pre_key_id}
        end

      _session ->
        {:ok, record, message.pre_key_id}
    end
  end

  def init_outgoing(record \\ nil, device, identity_key) do
    signed_pre_key = device.signed_pre_key
    remote_identity = strip_prefix(device.identity_key)

    if not XEdDSA.verify(signed_pre_key.public, signed_pre_key.signature, remote_identity) do
      {:error, :invalid_signed_pre_key}
    else
      base_key = Crypto.generate_x25519_key_pair()
      pre_key = device[:pre_key]
      record = record || SessionRecord.new()

      session =
        build_session(
          base_key,
          identity_key,
          device.identity_key,
          signed_pre_key.public,
          pre_key && pre_key.public,
          device.registration_id
        )
        |> Map.put(:pending_pre_key, %{
          signed_key_id: signed_pre_key.key_id,
          pre_key_id: pre_key && pre_key.key_id,
          base_key: base_key.public
        })

      record = record |> SessionRecord.close_open_session() |> SessionRecord.set_session(session)
      {:ok, record}
    end
  end

  defp build_session(
         base_key,
         identity_key,
         remote_identity,
         remote_signed,
         remote_pre_key,
         registration_id
       ) do
    dh1 = dh(remote_signed, identity_key.private)
    dh2 = dh(remote_identity, base_key.private)
    dh3 = dh(remote_signed, base_key.private)
    shared = :binary.copy(<<255>>, 32) <> dh1 <> dh2 <> dh3
    shared = if remote_pre_key, do: shared <> dh(remote_pre_key, base_key.private), else: shared

    <<root_key::binary-size(32), _::binary-size(32)>> =
      Crypto.hkdf(shared, 64, salt: <<0::256>>, info: "WhisperText")

    ratchet_key = Crypto.generate_x25519_key_pair()

    session =
      SessionRecord.create_entry()
      |> Map.put(:registration_id, registration_id)
      |> Map.put(:current_ratchet, %{
        root_key: root_key,
        ephemeral_key_pair: ratchet_key,
        last_remote_ephemeral_key: remote_signed,
        previous_counter: 0
      })
      |> Map.put(:index_info, %{
        created: System.system_time(:millisecond),
        used: System.system_time(:millisecond),
        remote_identity_key: remote_identity,
        base_key: base_key.public,
        base_key_type: SessionRecord.base_key_ours(),
        closed: -1
      })

    shared_ratchet = dh(remote_signed, ratchet_key.private)

    <<new_root::binary-size(32), chain_key::binary-size(32)>> =
      Crypto.hkdf(shared_ratchet, 64, salt: root_key, info: "WhisperRatchet")

    session
    |> SessionRecord.add_chain(ratchet_key.public, %{
      message_keys: %{},
      chain_key: %{counter: -1, key: chain_key},
      chain_type: SessionRecord.chain_sending()
    })
    |> put_in([:current_ratchet, :root_key], new_root)
  end

  defp build_incoming_session(message, credentials, pre_key) do
    identity = credentials.signed_identity_key
    signed = credentials.signed_pre_key.key_pair
    remote_identity = message.identity_key
    remote_base = message.base_key

    dh1 = dh(remote_identity, signed.private)
    dh2 = dh(remote_base, identity.private)
    dh3 = dh(remote_base, signed.private)
    shared = :binary.copy(<<255>>, 32) <> dh1 <> dh2 <> dh3
    shared = if pre_key, do: shared <> dh(remote_base, pre_key.private), else: shared

    <<root_key::binary-size(32), _::binary-size(32)>> =
      Crypto.hkdf(shared, 64, salt: <<0::256>>, info: "WhisperText")

    SessionRecord.create_entry()
    |> Map.put(:registration_id, message.registration_id)
    |> Map.put(:current_ratchet, %{
      root_key: root_key,
      ephemeral_key_pair: signed,
      last_remote_ephemeral_key: remote_base,
      previous_counter: 0
    })
    |> Map.put(:index_info, %{
      created: System.system_time(:millisecond),
      used: System.system_time(:millisecond),
      remote_identity_key: strip_prefix(remote_identity),
      base_key: remote_base,
      base_key_type: SessionRecord.base_key_theirs(),
      closed: -1
    })
  end

  defp dh(public, private), do: Crypto.x25519(private, strip_prefix(public))
  defp strip_prefix(<<5, key::binary-size(32)>>), do: key
  defp strip_prefix(<<key::binary-size(32)>>), do: key
end
