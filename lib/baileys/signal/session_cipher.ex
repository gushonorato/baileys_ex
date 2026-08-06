defmodule Baileys.Signal.SessionCipher do
  @moduledoc false

  alias Baileys.Crypto
  alias Baileys.Signal.{SessionBuilder, SessionRecord, WhisperProtocol}

  @version 0x33

  def encrypt(record, plaintext, identity_key, registration_id) do
    session = SessionRecord.get_open_session(record)
    ratchet = session.current_ratchet
    chain_id = ratchet.ephemeral_key_pair.public
    chain = session |> SessionRecord.get_chain(chain_id) |> next_message_key()
    counter = chain.chain_key.counter
    message_key = Map.fetch!(chain.message_keys, counter)
    chain = %{chain | message_keys: Map.delete(chain.message_keys, counter)}

    <<cipher_key::binary-size(32), mac_key::binary-size(32), iv_material::binary-size(32)>> =
      Crypto.hkdf(message_key, 96, salt: <<0::256>>, info: "WhisperMessageKeys")

    ciphertext = Crypto.aes_cbc_encrypt(plaintext, cipher_key, binary_part(iv_material, 0, 16))

    message =
      WhisperProtocol.encode_whisper(
        prefix(chain_id),
        counter,
        ratchet.previous_counter,
        ciphertext
      )

    mac_input =
      prefix(identity_key.public) <>
        prefix(session.index_info.remote_identity_key) <> <<@version>> <> message

    mac = binary_part(Crypto.hmac_sha256(mac_key, mac_input), 0, 8)
    whisper = <<@version, message::binary, mac::binary>>
    session = SessionRecord.put_chain(session, chain_id, chain)
    record = SessionRecord.set_session(record, session)

    case session[:pending_pre_key] do
      nil ->
        {:ok, :msg, whisper, record}

      pending ->
        pre_key_message =
          WhisperProtocol.encode_pre_key(%{
            pre_key_id: pending.pre_key_id,
            base_key: prefix(pending.base_key),
            identity_key: prefix(identity_key.public),
            message: whisper,
            registration_id: registration_id,
            signed_pre_key_id: pending.signed_key_id
          })

        {:ok, :pkmsg, <<@version, pre_key_message::binary>>, record}
    end
  end

  def decrypt_pre_key(record, <<@version, body::binary>>, credentials) do
    message = WhisperProtocol.decode_pre_key(body)

    with {:ok, record, used_pre_key} <- SessionBuilder.init_incoming(record, message, credentials),
         session when not is_nil(session) <- SessionRecord.get_session(record, message.base_key),
         {:ok, plaintext, session} <- decrypt_with_session(message.message, session, credentials) do
      {:ok, plaintext, SessionRecord.set_session(record, session), used_pre_key}
    else
      nil -> {:error, :missing_session}
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, error}
  end

  def decrypt_pre_key(_record, _message, _credentials), do: {:error, :invalid_signal_version}

  def decrypt(record, message, credentials) do
    record
    |> SessionRecord.get_sessions()
    |> Enum.reduce_while({:error, :no_matching_session}, fn session, _error ->
      case decrypt_with_session(message, session, credentials) do
        {:ok, plaintext, session} ->
          {:halt, {:ok, plaintext, SessionRecord.set_session(record, session)}}

        {:error, _reason} = error ->
          {:cont, error}
      end
    end)
  end

  defp decrypt_with_session(<<@version, body::binary>>, session, credentials)
       when byte_size(body) >= 8 do
    proto_size = byte_size(body) - 8
    <<message_proto::binary-size(proto_size), mac::binary-size(8)>> = body
    message = WhisperProtocol.decode_whisper(message_proto)
    session = step_ratchet(session, message.ephemeral_key, message.previous_counter)

    chain =
      session
      |> SessionRecord.get_chain(message.ephemeral_key)
      |> fill_message_keys(message.counter)

    case Map.fetch(chain.message_keys, message.counter) do
      {:ok, message_key} ->
        chain = %{chain | message_keys: Map.delete(chain.message_keys, message.counter)}

        <<cipher_key::binary-size(32), mac_key::binary-size(32), iv_material::binary-size(32)>> =
          Crypto.hkdf(message_key, 96, salt: <<0::256>>, info: "WhisperMessageKeys")

        mac_input =
          prefix(session.index_info.remote_identity_key) <>
            prefix(credentials.signed_identity_key.public) <> <<@version>> <> message_proto

        expected = binary_part(Crypto.hmac_sha256(mac_key, mac_input), 0, 8)

        if :crypto.hash_equals(mac, expected) do
          with {:ok, plaintext} <-
                 Crypto.aes_cbc_decrypt(
                   message.ciphertext,
                   cipher_key,
                   binary_part(iv_material, 0, 16)
                 ) do
            session =
              session
              |> SessionRecord.put_chain(message.ephemeral_key, chain)
              |> Map.delete(:pending_pre_key)
              |> put_in([:index_info, :used], System.system_time(:millisecond))

            {:ok, plaintext, session}
          end
        else
          {:error, :invalid_signal_mac}
        end

      :error ->
        {:error, :message_key_unavailable}
    end
  end

  defp decrypt_with_session(_message, _session, _credentials),
    do: {:error, :invalid_signal_version}

  defp next_message_key(chain) do
    key = chain.chain_key.key
    counter = chain.chain_key.counter + 1

    %{
      chain
      | message_keys: Map.put(chain.message_keys, counter, Crypto.hmac_sha256(key, <<1>>)),
        chain_key: %{counter: counter, key: Crypto.hmac_sha256(key, <<2>>)}
    }
  end

  defp fill_message_keys(%{chain_key: %{counter: counter}} = chain, target)
       when counter >= target,
       do: chain

  defp fill_message_keys(chain, target) when target - chain.chain_key.counter <= 2_000 do
    fill_message_keys(next_message_key(chain), target)
  end

  defp fill_message_keys(_chain, _target), do: raise("Signal message is too far in the future")

  defp step_ratchet(session, remote_key, previous_counter) do
    if SessionRecord.get_chain(session, remote_key) do
      session
    else
      ratchet = session.current_ratchet

      session =
        case SessionRecord.get_chain(session, ratchet.last_remote_ephemeral_key) do
          nil ->
            session

          previous ->
            previous =
              previous |> fill_message_keys(previous_counter) |> put_in([:chain_key, :key], nil)

            SessionRecord.put_chain(session, ratchet.last_remote_ephemeral_key, previous)
        end

      session = calculate_ratchet(session, remote_key, false)
      ratchet = session.current_ratchet

      {session, ratchet} =
        case SessionRecord.get_chain(session, ratchet.ephemeral_key_pair.public) do
          nil ->
            {session, ratchet}

          previous ->
            ratchet = %{ratchet | previous_counter: previous.chain_key.counter}
            {SessionRecord.delete_chain(session, ratchet.ephemeral_key_pair.public), ratchet}
        end

      ratchet = %{ratchet | ephemeral_key_pair: Crypto.generate_x25519_key_pair()}
      session = calculate_ratchet(%{session | current_ratchet: ratchet}, remote_key, true)
      put_in(session.current_ratchet.last_remote_ephemeral_key, remote_key)
    end
  end

  defp calculate_ratchet(session, remote_key, sending?) do
    ratchet = session.current_ratchet
    shared = Crypto.x25519(ratchet.ephemeral_key_pair.private, strip_prefix(remote_key))

    <<root_key::binary-size(32), chain_key::binary-size(32)>> =
      Crypto.hkdf(shared, 64, salt: ratchet.root_key, info: "WhisperRatchet")

    chain_id = if sending?, do: ratchet.ephemeral_key_pair.public, else: remote_key

    session
    |> SessionRecord.add_chain(chain_id, %{
      message_keys: %{},
      chain_key: %{counter: -1, key: chain_key},
      chain_type:
        if(sending?, do: SessionRecord.chain_sending(), else: SessionRecord.chain_receiving())
    })
    |> put_in([:current_ratchet, :root_key], root_key)
  end

  defp prefix(<<5, _::binary-size(32)>> = key), do: key
  defp prefix(<<key::binary-size(32)>>), do: <<5, key::binary>>
  defp strip_prefix(<<5, key::binary-size(32)>>), do: key
  defp strip_prefix(<<key::binary-size(32)>>), do: key
end
