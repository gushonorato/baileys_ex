defmodule BaileysExo.Signal.SenderKey do
  @moduledoc false

  alias BaileysExo.Crypto
  alias BaileysExo.Crypto.XEdDSA
  alias BaileysExo.JID

  alias BaileysExo.Proto.{
    SenderKeyDistributionMessage,
    SenderKeyMessage,
    SenderKeyRecordStructure,
    SenderKeyStateStructure
  }

  @version 0x33
  @max_states 5
  @max_message_keys 2_000
  @max_future_distance 2_000

  def new_state(key_id, iteration, chain_seed, signing_key)
      when is_integer(key_id) and is_integer(iteration) and is_binary(chain_seed) do
    %{
      key_id: key_id,
      chain_key: %{iteration: iteration, seed: chain_seed},
      signing_key: signing_key,
      message_keys: []
    }
  end

  def new_record(state), do: %{states: [state]}

  def record_key(group_jid, author_jid) do
    case JID.decode(author_jid) do
      {:ok, author} ->
        user =
          if author.domain_type == 0,
            do: author.user,
            else: "#{author.user}_#{author.domain_type}"

        "#{group_jid}::#{user}::#{author.device || 0}"

      {:error, :invalid_jid} ->
        "#{group_jid}::#{author_jid}::0"
    end
  end

  def distribution(%{states: states}) do
    state = List.last(states)

    message = %SenderKeyDistributionMessage{
      id: state.key_id,
      iteration: state.chain_key.iteration,
      chainKey: state.chain_key.seed,
      signingKey: prefix_key(state.signing_key.public)
    }

    <<@version, Protobuf.encode(message)::binary>>
  end

  def process_distribution(record, <<@version, encoded::binary>>) do
    message = SenderKeyDistributionMessage.decode(encoded)

    with true <- is_integer(message.id),
         true <- is_integer(message.iteration),
         <<chain_seed::binary-size(32)>> <- message.chainKey,
         {:ok, public} <- signing_public(message.signingKey) do
      state =
        new_state(message.id, message.iteration, chain_seed, %{public: public, private: nil})

      states = ((record && record.states) || []) ++ [state]
      {:ok, %{states: Enum.take(states, -@max_states)}}
    else
      _invalid -> {:error, :invalid_sender_key_distribution}
    end
  rescue
    _invalid -> {:error, :invalid_sender_key_distribution}
  end

  def process_distribution(_record, _message), do: {:error, :invalid_sender_key_distribution}

  def encrypt(%{states: states} = record, plaintext) when is_binary(plaintext) do
    index = length(states) - 1
    state = Enum.at(states, index)

    with private when is_binary(private) <- state.signing_key.private,
         {:ok, message_seed, state} <- message_seed(state, state.chain_key.iteration),
         {iv, cipher_key} <- message_cipher(message_seed),
         ciphertext <- Crypto.aes_cbc_encrypt(plaintext, cipher_key, iv) do
      message = %SenderKeyMessage{
        id: state.key_id,
        iteration: state.chain_key.iteration - 1,
        ciphertext: ciphertext
      }

      unsigned = <<@version, Protobuf.encode(message)::binary>>
      signature = XEdDSA.sign(unsigned, private)
      {:ok, unsigned <> signature, put_in(record.states, List.replace_at(states, index, state))}
    else
      nil -> {:error, :missing_sender_signing_key}
      {:error, _reason} = error -> error
    end
  end

  def decrypt(%{states: states} = record, message)
      when is_binary(message) and byte_size(message) > 65 do
    unsigned_size = byte_size(message) - 64
    <<unsigned::binary-size(unsigned_size), signature::binary-size(64)>> = message

    with <<@version, encoded::binary>> <- unsigned,
         decoded <- SenderKeyMessage.decode(encoded),
         index when is_integer(index) <- Enum.find_index(states, &(&1.key_id == decoded.id)),
         state <- Enum.at(states, index),
         true <- XEdDSA.verify(unsigned, signature, state.signing_key.public),
         {:ok, seed, updated_state} <- message_seed(state, decoded.iteration),
         {iv, cipher_key} <- message_cipher(seed),
         {:ok, plaintext} <- Crypto.aes_cbc_decrypt(decoded.ciphertext, cipher_key, iv) do
      {:ok, plaintext, put_in(record.states, List.replace_at(states, index, updated_state))}
    else
      false -> {:error, :invalid_sender_key_signature}
      nil -> {:error, :missing_sender_key_state}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_sender_key_message}
    end
  rescue
    _invalid -> {:error, :invalid_sender_key_message}
  end

  def decrypt(_record, _message), do: {:error, :invalid_sender_key_message}

  def serialize(%{states: states}) do
    %SenderKeyRecordStructure{senderKeyStates: Enum.map(states, &serialize_state/1)}
  end

  def deserialize(%SenderKeyRecordStructure{senderKeyStates: states}) do
    %{states: Enum.map(states, &deserialize_state/1)}
  end

  defp message_seed(state, target) when target < state.chain_key.iteration do
    case Enum.split_with(state.message_keys, &(&1.iteration == target)) do
      {[message_key], remaining} -> {:ok, message_key.seed, %{state | message_keys: remaining}}
      _missing -> {:error, :old_sender_key_message}
    end
  end

  defp message_seed(state, target)
       when target - state.chain_key.iteration > @max_future_distance,
       do: {:error, :sender_key_message_too_far}

  defp message_seed(state, target) do
    state = cache_skipped_keys(state, target)
    seed = Crypto.hmac_sha256(state.chain_key.seed, <<1>>)
    next_seed = Crypto.hmac_sha256(state.chain_key.seed, <<2>>)
    state = put_in(state.chain_key, %{iteration: target + 1, seed: next_seed})
    {:ok, seed, state}
  end

  defp cache_skipped_keys(state, target) when state.chain_key.iteration >= target, do: state

  defp cache_skipped_keys(state, target) do
    iteration = state.chain_key.iteration
    message_key = %{iteration: iteration, seed: Crypto.hmac_sha256(state.chain_key.seed, <<1>>)}
    next_seed = Crypto.hmac_sha256(state.chain_key.seed, <<2>>)

    state = %{
      state
      | chain_key: %{iteration: iteration + 1, seed: next_seed},
        message_keys: Enum.take([message_key | state.message_keys], @max_message_keys)
    }

    cache_skipped_keys(state, target)
  end

  defp message_cipher(seed) do
    <<iv::binary-size(16), cipher_key::binary-size(32)>> =
      Crypto.hkdf(seed, 48, salt: <<0::256>>, info: "WhisperGroup")

    {iv, cipher_key}
  end

  defp signing_public(<<5, public::binary-size(32)>>), do: {:ok, public}
  defp signing_public(<<public::binary-size(32)>>), do: {:ok, public}
  defp signing_public(_public), do: {:error, :invalid_sender_signing_key}

  defp prefix_key(<<5, _::binary-size(32)>> = public), do: public
  defp prefix_key(<<public::binary-size(32)>>), do: <<5, public::binary>>

  defp serialize_state(state) do
    %SenderKeyStateStructure{
      senderKeyId: state.key_id,
      senderChainKey: %SenderKeyStateStructure.SenderChainKey{
        iteration: state.chain_key.iteration,
        seed: state.chain_key.seed
      },
      senderSigningKey: %SenderKeyStateStructure.SenderSigningKey{
        public: state.signing_key.public,
        private: state.signing_key.private
      },
      senderMessageKeys:
        Enum.map(state.message_keys, fn key ->
          %SenderKeyStateStructure.SenderMessageKey{iteration: key.iteration, seed: key.seed}
        end)
    }
  end

  defp deserialize_state(state) do
    new_state(
      state.senderKeyId,
      state.senderChainKey.iteration,
      state.senderChainKey.seed,
      %{public: state.senderSigningKey.public, private: state.senderSigningKey.private}
    )
    |> Map.put(
      :message_keys,
      Enum.map(state.senderMessageKeys, &%{iteration: &1.iteration, seed: &1.seed})
    )
  end
end
