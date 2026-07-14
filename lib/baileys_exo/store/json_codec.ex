defmodule BaileysExo.Store.JSONCodec do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Proto.{ADVSignedDeviceIdentity, SenderKeyRecordStructure}
  alias BaileysExo.Signal.SenderKey

  @version 3

  def encode(%Credentials{} = credentials) do
    Jason.encode(%{
      "version" => @version,
      "credentials" => encode_credentials(credentials)
    })
  rescue
    _error -> {:error, :invalid_credentials}
  end

  def decode(encoded) when is_binary(encoded) do
    with {:ok, document} <- Jason.decode(encoded),
         {:ok, version} <- validate_version(document),
         %{"credentials" => credentials} <- document,
         {:ok, credentials} <- decode_credentials(credentials, version) do
      {:ok, credentials}
    else
      {:error, :unsupported_session_version} = error -> error
      _other -> {:error, :invalid_credentials}
    end
  rescue
    _error -> {:error, :invalid_credentials}
  end

  defp validate_version(%{"version" => version}) when version in [1, 2, @version],
    do: {:ok, version}

  defp validate_version(%{"version" => _version}), do: {:error, :unsupported_session_version}
  defp validate_version(_document), do: {:error, :invalid_credentials}

  defp encode_credentials(credentials) do
    %{
      "noise_key" => encode_key_pair(credentials.noise_key),
      "pairing_ephemeral_key" => encode_key_pair(credentials.pairing_ephemeral_key),
      "signed_identity_key" => encode_key_pair(credentials.signed_identity_key),
      "signed_pre_key" => encode_signed_pre_key(credentials.signed_pre_key),
      "registration_id" => credentials.registration_id,
      "adv_secret_key" => encode_binary(credentials.adv_secret_key),
      "me" => encode_me(credentials.me),
      "account" => encode_account(credentials.account),
      "platform" => credentials.platform,
      "routing_info" => encode_binary(credentials.routing_info),
      "pairing_code" => credentials.pairing_code,
      "registered" => credentials.registered?,
      "next_pre_key_id" => credentials.next_pre_key_id,
      "first_unuploaded_pre_key_id" => credentials.first_unuploaded_pre_key_id,
      "sessions" => Map.new(credentials.sessions, &encode_session_record_entry/1),
      "sender_keys" => Map.new(credentials.sender_keys, &encode_sender_key_entry/1),
      "pre_keys" => Map.new(credentials.pre_keys, &encode_pre_key_entry/1),
      "lid_mappings" => credentials.lid_mappings,
      "account_settings" => encode_account_settings(credentials.account_settings),
      "privacy_tokens" => Map.new(credentials.privacy_tokens, &encode_privacy_token/1),
      "pending_app_state_sync" => credentials.pending_app_state_sync
    }
  end

  defp decode_credentials(value, version) when is_map(value) do
    with {:ok, noise_key} <- decode_key_pair(value["noise_key"]),
         {:ok, pairing_ephemeral_key} <- decode_key_pair(value["pairing_ephemeral_key"]),
         {:ok, signed_identity_key} <- decode_key_pair(value["signed_identity_key"]),
         {:ok, signed_pre_key} <- decode_signed_pre_key(value["signed_pre_key"]),
         {:ok, registration_id} <- decode_non_negative_integer(value["registration_id"]),
         {:ok, adv_secret_key} <- decode_binary(value["adv_secret_key"]),
         {:ok, me} <- decode_me(value["me"]),
         {:ok, account} <- decode_account(value["account"]),
         {:ok, platform} <- decode_nullable_string(value["platform"]),
         {:ok, routing_info} <- decode_nullable_binary(value["routing_info"]),
         {:ok, pairing_code} <- decode_nullable_string(value["pairing_code"]),
         {:ok, registered?} <- decode_boolean(value["registered"]),
         {:ok, next_pre_key_id} <- decode_non_negative_integer(value["next_pre_key_id"]),
         {:ok, first_unuploaded_pre_key_id} <-
           decode_non_negative_integer(value["first_unuploaded_pre_key_id"]),
         {:ok, sessions} <- decode_sessions(value["sessions"]),
         {:ok, sender_keys} <- decode_sender_keys(value, version),
         {:ok, pre_keys} <- decode_pre_keys(value["pre_keys"]),
         {:ok, lid_mappings} <- decode_string_map(value["lid_mappings"]),
         {:ok, account_settings} <- decode_account_settings(value, version),
         {:ok, privacy_tokens} <- decode_privacy_tokens(value, version),
         {:ok, pending_app_state_sync} <- decode_pending_app_state_sync(value, version) do
      {:ok,
       %Credentials{
         noise_key: noise_key,
         pairing_ephemeral_key: pairing_ephemeral_key,
         signed_identity_key: signed_identity_key,
         signed_pre_key: signed_pre_key,
         registration_id: registration_id,
         adv_secret_key: adv_secret_key,
         me: me,
         account: account,
         platform: platform,
         routing_info: routing_info,
         pairing_code: pairing_code,
         registered?: registered?,
         next_pre_key_id: next_pre_key_id,
         first_unuploaded_pre_key_id: first_unuploaded_pre_key_id,
         sessions: sessions,
         sender_keys: sender_keys,
         pre_keys: pre_keys,
         lid_mappings: lid_mappings,
         account_settings: account_settings,
         privacy_tokens: privacy_tokens,
         pending_app_state_sync: pending_app_state_sync
       }}
    end
  end

  defp decode_credentials(_value, _version), do: {:error, :invalid_credentials}

  defp encode_sender_key_entry({address, record}) do
    encoded = record |> SenderKey.serialize() |> Protobuf.encode() |> encode_binary()
    {address, encoded}
  end

  defp decode_sender_keys(_value, 1), do: {:ok, %{}}

  defp decode_sender_keys(%{"sender_keys" => value}, version)
       when version in [2, @version] and is_map(value) do
    decode_map(value, fn address, encoded ->
      with true <- is_binary(address),
           {:ok, encoded} <- decode_binary(encoded),
           record <- encoded |> SenderKeyRecordStructure.decode() |> SenderKey.deserialize() do
        {:ok, address, record}
      else
        _invalid -> {:error, :invalid_credentials}
      end
    end)
  end

  defp decode_sender_keys(_value, version) when version in [2, @version],
    do: {:error, :invalid_credentials}

  defp encode_account_settings(settings) do
    case settings[:default_disappearing_mode] do
      nil ->
        %{}

      mode ->
        %{
          "default_disappearing_mode" => %{
            "ephemeral_expiration" => mode.ephemeral_expiration,
            "ephemeral_setting_timestamp" => mode.ephemeral_setting_timestamp
          }
        }
    end
  end

  defp decode_account_settings(_value, version) when version in [1, 2], do: {:ok, %{}}

  defp decode_account_settings(%{"account_settings" => settings}, @version)
       when is_map(settings) do
    case settings["default_disappearing_mode"] do
      nil ->
        {:ok, %{}}

      %{
        "ephemeral_expiration" => expiration,
        "ephemeral_setting_timestamp" => timestamp
      }
      when is_integer(expiration) and expiration >= 0 and is_integer(timestamp) and timestamp >= 0 ->
        {:ok,
         %{
           default_disappearing_mode: %{
             ephemeral_expiration: expiration,
             ephemeral_setting_timestamp: timestamp
           }
         }}

      _invalid ->
        {:error, :invalid_credentials}
    end
  end

  defp decode_account_settings(_value, @version), do: {:error, :invalid_credentials}

  defp encode_privacy_token({jid, %{token: token, timestamp: timestamp}}) do
    {jid, %{"token" => encode_binary(token), "timestamp" => timestamp}}
  end

  defp decode_privacy_tokens(_value, version) when version in [1, 2], do: {:ok, %{}}

  defp decode_privacy_tokens(%{"privacy_tokens" => tokens}, @version) when is_map(tokens) do
    decode_map(tokens, fn jid, value ->
      with true <- is_binary(jid) and jid != "",
           %{"token" => token, "timestamp" => timestamp} <- value,
           {:ok, token} <- decode_binary(token),
           true <- is_integer(timestamp) and timestamp >= 0 do
        {:ok, jid, %{token: token, timestamp: timestamp}}
      else
        _invalid -> {:error, :invalid_credentials}
      end
    end)
  end

  defp decode_privacy_tokens(_value, @version), do: {:error, :invalid_credentials}

  defp decode_pending_app_state_sync(_value, version) when version in [1, 2], do: {:ok, []}

  defp decode_pending_app_state_sync(%{"pending_app_state_sync" => collections}, @version)
       when is_list(collections) do
    allowed = ["critical_block", "critical_unblock_low", "regular_high", "regular_low", "regular"]

    if Enum.all?(collections, &(&1 in allowed)) and
         length(Enum.uniq(collections)) == length(collections) do
      {:ok, collections}
    else
      {:error, :invalid_credentials}
    end
  end

  defp decode_pending_app_state_sync(_value, @version), do: {:error, :invalid_credentials}

  defp encode_key_pair(%{public: public, private: private}) do
    %{"public" => encode_binary(public), "private" => encode_binary(private)}
  end

  defp decode_key_pair(%{"public" => public, "private" => private}) do
    with {:ok, public} <- decode_binary(public),
         {:ok, private} <- decode_binary(private) do
      {:ok, %{public: public, private: private}}
    end
  end

  defp decode_key_pair(_value), do: {:error, :invalid_credentials}

  defp encode_signed_pre_key(signed) do
    %{
      "key_pair" => encode_key_pair(signed.key_pair),
      "key_id" => signed.key_id,
      "signature" => encode_binary(signed.signature)
    }
  end

  defp decode_signed_pre_key(%{
         "key_pair" => key_pair,
         "key_id" => key_id,
         "signature" => signature
       }) do
    with {:ok, key_pair} <- decode_key_pair(key_pair),
         {:ok, key_id} <- decode_non_negative_integer(key_id),
         {:ok, signature} <- decode_binary(signature) do
      {:ok, %{key_pair: key_pair, key_id: key_id, signature: signature}}
    end
  end

  defp decode_signed_pre_key(_value), do: {:error, :invalid_credentials}

  defp encode_me(nil), do: nil

  defp encode_me(me) do
    %{"id" => me.id, "name" => me.name}
    |> maybe_put("lid", me, :lid)
  end

  defp decode_me(nil), do: {:ok, nil}

  defp decode_me(%{"id" => id, "name" => name} = value)
       when is_binary(id) and is_binary(name) do
    case Map.fetch(value, "lid") do
      {:ok, lid} when is_binary(lid) -> {:ok, %{id: id, name: name, lid: lid}}
      :error -> {:ok, %{id: id, name: name}}
      _other -> {:error, :invalid_credentials}
    end
  end

  defp decode_me(_value), do: {:error, :invalid_credentials}

  defp encode_account(nil), do: nil

  defp encode_account(%ADVSignedDeviceIdentity{} = account),
    do: account |> Protobuf.encode() |> encode_binary()

  defp decode_account(nil), do: {:ok, nil}

  defp decode_account(value) do
    with {:ok, encoded} <- decode_binary(value) do
      {:ok, ADVSignedDeviceIdentity.decode(encoded)}
    end
  end

  defp encode_pre_key_entry({id, key_pair}),
    do: {Integer.to_string(id), encode_key_pair(key_pair)}

  defp decode_pre_keys(value) when is_map(value) do
    decode_map(value, fn id, key_pair ->
      with {:ok, id} <- decode_integer_key(id),
           {:ok, key_pair} <- decode_key_pair(key_pair) do
        {:ok, id, key_pair}
      end
    end)
  end

  defp decode_pre_keys(_value), do: {:error, :invalid_credentials}

  defp encode_session_record_entry({address, record}) do
    {address,
     %{
       "sessions" => Map.new(record.sessions, &encode_session_entry/1)
     }}
  end

  defp encode_session_entry({id, session}) do
    value = %{
      "chains" => Map.new(session.chains, &encode_chain_entry/1),
      "registration_id" => session.registration_id,
      "current_ratchet" => encode_ratchet(session.current_ratchet),
      "index_info" => encode_index_info(session.index_info)
    }

    {id, maybe_put(value, "pending_pre_key", session, :pending_pre_key)}
  end

  defp decode_sessions(value) when is_map(value) do
    decode_map(value, fn address, record ->
      with true <- is_binary(address),
           {:ok, record} <- decode_session_record(record) do
        {:ok, address, record}
      else
        _other -> {:error, :invalid_credentials}
      end
    end)
  end

  defp decode_sessions(_value), do: {:error, :invalid_credentials}

  defp decode_session_record(%{"sessions" => sessions}) when is_map(sessions) do
    with {:ok, sessions} <-
           decode_map(sessions, fn id, session ->
             with true <- is_binary(id),
                  {:ok, session} <- decode_session(session) do
               {:ok, id, session}
             else
               _other -> {:error, :invalid_credentials}
             end
           end) do
      {:ok, %{sessions: sessions}}
    end
  end

  defp decode_session_record(_value), do: {:error, :invalid_credentials}

  defp decode_session(value) when is_map(value) do
    with {:ok, chains} <- decode_chains(value["chains"]),
         {:ok, registration_id} <- decode_non_negative_integer(value["registration_id"]),
         {:ok, current_ratchet} <- decode_ratchet(value["current_ratchet"]),
         {:ok, index_info} <- decode_index_info(value["index_info"]),
         {:ok, pending_pre_key} <- decode_pending_pre_key(Map.fetch(value, "pending_pre_key")) do
      session = %{
        chains: chains,
        registration_id: registration_id,
        current_ratchet: current_ratchet,
        index_info: index_info
      }

      {:ok, maybe_put_decoded(session, :pending_pre_key, pending_pre_key)}
    end
  end

  defp decode_session(_value), do: {:error, :invalid_credentials}

  defp encode_chain_entry({id, chain}) do
    {id,
     %{
       "message_keys" =>
         Map.new(chain.message_keys, fn {counter, key} ->
           {Integer.to_string(counter), encode_binary(key)}
         end),
       "chain_key" => %{
         "counter" => chain.chain_key.counter,
         "key" => encode_binary(chain.chain_key.key)
       },
       "chain_type" => chain.chain_type
     }}
  end

  defp decode_chains(value) when is_map(value) do
    decode_map(value, fn id, chain ->
      with true <- is_binary(id),
           {:ok, chain} <- decode_chain(chain) do
        {:ok, id, chain}
      else
        _other -> {:error, :invalid_credentials}
      end
    end)
  end

  defp decode_chains(_value), do: {:error, :invalid_credentials}

  defp decode_chain(%{
         "message_keys" => message_keys,
         "chain_key" => %{"counter" => counter, "key" => key},
         "chain_type" => chain_type
       }) do
    with {:ok, message_keys} <- decode_message_keys(message_keys),
         {:ok, counter} <- decode_integer(counter),
         {:ok, key} <- decode_nullable_binary(key),
         {:ok, chain_type} <- decode_non_negative_integer(chain_type) do
      {:ok,
       %{
         message_keys: message_keys,
         chain_key: %{counter: counter, key: key},
         chain_type: chain_type
       }}
    end
  end

  defp decode_chain(_value), do: {:error, :invalid_credentials}

  defp decode_message_keys(value) when is_map(value) do
    decode_map(value, fn counter, key ->
      with {:ok, counter} <- decode_integer_key(counter),
           {:ok, key} <- decode_binary(key) do
        {:ok, counter, key}
      end
    end)
  end

  defp decode_message_keys(_value), do: {:error, :invalid_credentials}

  defp encode_ratchet(ratchet) do
    %{
      "root_key" => encode_binary(ratchet.root_key),
      "ephemeral_key_pair" => encode_key_pair(ratchet.ephemeral_key_pair),
      "last_remote_ephemeral_key" => encode_binary(ratchet.last_remote_ephemeral_key),
      "previous_counter" => ratchet.previous_counter
    }
  end

  defp decode_ratchet(%{
         "root_key" => root_key,
         "ephemeral_key_pair" => ephemeral_key_pair,
         "last_remote_ephemeral_key" => last_remote_ephemeral_key,
         "previous_counter" => previous_counter
       }) do
    with {:ok, root_key} <- decode_binary(root_key),
         {:ok, ephemeral_key_pair} <- decode_key_pair(ephemeral_key_pair),
         {:ok, last_remote_ephemeral_key} <- decode_binary(last_remote_ephemeral_key),
         {:ok, previous_counter} <- decode_non_negative_integer(previous_counter) do
      {:ok,
       %{
         root_key: root_key,
         ephemeral_key_pair: ephemeral_key_pair,
         last_remote_ephemeral_key: last_remote_ephemeral_key,
         previous_counter: previous_counter
       }}
    end
  end

  defp decode_ratchet(_value), do: {:error, :invalid_credentials}

  defp encode_index_info(index_info) do
    %{
      "created" => index_info.created,
      "used" => index_info.used,
      "remote_identity_key" => encode_binary(index_info.remote_identity_key),
      "base_key" => encode_binary(index_info.base_key),
      "base_key_type" => index_info.base_key_type,
      "closed" => index_info.closed
    }
  end

  defp decode_index_info(%{
         "created" => created,
         "used" => used,
         "remote_identity_key" => remote_identity_key,
         "base_key" => base_key,
         "base_key_type" => base_key_type,
         "closed" => closed
       }) do
    with {:ok, created} <- decode_non_negative_integer(created),
         {:ok, used} <- decode_non_negative_integer(used),
         {:ok, remote_identity_key} <- decode_binary(remote_identity_key),
         {:ok, base_key} <- decode_binary(base_key),
         {:ok, base_key_type} <- decode_non_negative_integer(base_key_type),
         {:ok, closed} <- decode_integer(closed) do
      {:ok,
       %{
         created: created,
         used: used,
         remote_identity_key: remote_identity_key,
         base_key: base_key,
         base_key_type: base_key_type,
         closed: closed
       }}
    end
  end

  defp decode_index_info(_value), do: {:error, :invalid_credentials}

  defp encode_pending_pre_key(nil), do: nil

  defp encode_pending_pre_key(pending) do
    %{
      "signed_key_id" => pending.signed_key_id,
      "pre_key_id" => pending.pre_key_id,
      "base_key" => encode_binary(pending.base_key)
    }
  end

  defp decode_pending_pre_key(:error), do: {:ok, :missing}
  defp decode_pending_pre_key({:ok, nil}), do: {:ok, nil}

  defp decode_pending_pre_key(
         {:ok,
          %{"signed_key_id" => signed_key_id, "pre_key_id" => pre_key_id, "base_key" => base_key}}
       ) do
    with {:ok, signed_key_id} <- decode_non_negative_integer(signed_key_id),
         {:ok, pre_key_id} <- decode_nullable_non_negative_integer(pre_key_id),
         {:ok, base_key} <- decode_binary(base_key) do
      {:ok, %{signed_key_id: signed_key_id, pre_key_id: pre_key_id, base_key: base_key}}
    end
  end

  defp decode_pending_pre_key(_value), do: {:error, :invalid_credentials}

  defp decode_string_map(value) when is_map(value) do
    if Enum.all?(value, fn {key, item} -> is_binary(key) and is_binary(item) end) do
      {:ok, value}
    else
      {:error, :invalid_credentials}
    end
  end

  defp decode_string_map(_value), do: {:error, :invalid_credentials}

  defp decode_map(map, decoder) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, decoded} ->
      case decoder.(key, value) do
        {:ok, decoded_key, decoded_value} ->
          {:cont, {:ok, Map.put(decoded, decoded_key, decoded_value)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp encode_binary(nil), do: nil
  defp encode_binary(value) when is_binary(value), do: Base.encode64(value)

  defp decode_binary(value) when is_binary(value), do: Base.decode64(value)
  defp decode_binary(_value), do: {:error, :invalid_credentials}

  defp decode_nullable_binary(nil), do: {:ok, nil}
  defp decode_nullable_binary(value), do: decode_binary(value)

  defp decode_nullable_string(nil), do: {:ok, nil}
  defp decode_nullable_string(value) when is_binary(value), do: {:ok, value}
  defp decode_nullable_string(_value), do: {:error, :invalid_credentials}

  defp decode_boolean(value) when is_boolean(value), do: {:ok, value}
  defp decode_boolean(_value), do: {:error, :invalid_credentials}

  defp decode_integer(value) when is_integer(value), do: {:ok, value}
  defp decode_integer(_value), do: {:error, :invalid_credentials}

  defp decode_non_negative_integer(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp decode_non_negative_integer(_value), do: {:error, :invalid_credentials}

  defp decode_nullable_non_negative_integer(nil), do: {:ok, nil}
  defp decode_nullable_non_negative_integer(value), do: decode_non_negative_integer(value)

  defp decode_integer_key(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :invalid_credentials}
    end
  end

  defp maybe_put(map, json_key, source, atom_key) do
    if Map.has_key?(source, atom_key) do
      Map.put(map, json_key, encode_optional_value(atom_key, Map.get(source, atom_key)))
    else
      map
    end
  end

  defp encode_optional_value(:pending_pre_key, value), do: encode_pending_pre_key(value)
  defp encode_optional_value(:lid, value), do: value

  defp maybe_put_decoded(map, _key, :missing), do: map
  defp maybe_put_decoded(map, key, value), do: Map.put(map, key, value)
end
