defmodule Baileys.Messages.Sender do
  @moduledoc false

  alias Baileys.Auth.Credentials
  alias Baileys.Binary.Node
  alias Baileys.SentMessage
  alias Baileys.{ConnectionProcess, JID}
  alias Baileys.Protocol.USync
  alias Baileys.Proto.Message
  alias Baileys.Signal.{SessionBuilder, SessionCipher, SessionRecord}

  def send_text(connection, %Credentials{me: me} = credentials, recipient, text)
      when is_map(me) and is_binary(text) and byte_size(text) > 0 do
    base_credentials = credentials

    with {:ok, recipient} <- Baileys.jid(recipient),
         {:ok, reply} <-
           ConnectionProcess.query(
             connection,
             USync.device_query([recipient, credentials.me.id])
           ),
         {:ok, devices, mappings} <-
           USync.parse_devices(reply, credentials.me.id, credentials.me[:lid]),
         true <- devices != [] || {:error, :not_on_whatsapp},
         credentials = %{
           credentials
           | lid_mappings: Map.merge(credentials.lid_mappings, mappings)
         },
         {:ok, credentials} <- ensure_sessions(connection, credentials, devices),
         material = retry_material(recipient, text),
         {:ok, participants, credentials} <- encrypt_devices(credentials, devices, material),
         id = message_id(),
         {:ok, credentials} <-
           ConnectionProcess.commit_credentials(connection, base_credentials, credentials),
         stanza =
           id
           |> relay_stanza(recipient, participants, credentials.account)
           |> attach_privacy_token(recipient, credentials),
         :ok <-
           ConnectionProcess.relay(
             connection,
             stanza,
             material
           ) do
      {:ok, %SentMessage{id: id, to: recipient, accepted_at: DateTime.utc_now()}, credentials}
    else
      false -> {:error, :not_on_whatsapp}
      {:error, _reason} = error -> error
    end
  end

  def send_text(_connection, _credentials, _recipient, _text), do: {:error, :invalid_text}

  @doc false
  def retry_material(recipient, text) when is_binary(recipient) and is_binary(text) do
    %{recipient: recipient, text: text}
  end

  @doc false
  def retry_stanza(
        id,
        %{recipient: recipient, text: text},
        requester,
        count,
        %Credentials{} = credentials,
        bundle,
        registration_id
      )
      when is_binary(id) and is_binary(requester) and is_integer(count) and count > 0 do
    with {:ok, wire_requester} <-
           retry_requester(%{recipient: recipient, text: text}, requester, credentials),
         address = session_address(credentials, wire_requester),
         {:ok, record} <-
           retry_session(
             credentials.sessions[address],
             bundle,
             registration_id,
             credentials
           ),
         message = text_message(text),
         plaintext = retry_plaintext(message, recipient, requester, credentials),
         {:ok, type, ciphertext, record} <-
           SessionCipher.encrypt(
             record,
             plaintext,
             credentials.signed_identity_key,
             credentials.registration_id
           ) do
      credentials = put_in(credentials.sessions[address], record)

      stanza =
        id
        |> relay_stanza(recipient, [{wire_requester, type, ciphertext}], credentials.account)
        |> route_retry(recipient, wire_requester, requester, credentials)
        |> put_retry_count(count)
        |> attach_privacy_token(recipient, credentials)

      {:ok, stanza, credentials}
    end
  end

  def retry_stanza(_id, _material, _requester, _count, _credentials, _bundle, _registration_id),
    do: {:error, :invalid_retry_material}

  @doc false
  def retry_requester(%{recipient: recipient}, requester, %Credentials{} = credentials)
      when is_binary(recipient) and is_binary(requester) do
    with {:ok, decoded} <- JID.decode(requester),
         true <- valid_retry_jid?(requester, decoded),
         wire_requester = wire_jid(credentials, requester),
         true <-
           own_jid?(requester, credentials.me) or
             same_user?(requester, recipient) or
             same_user?(wire_requester, wire_jid(credentials, recipient)) do
      {:ok, wire_requester}
    else
      {:error, :invalid_jid} -> {:error, :invalid_retry_requester}
      false -> retry_requester_error(requester, recipient, credentials)
    end
  end

  def retry_requester(_material, _requester, _credentials),
    do: {:error, :invalid_retry_requester}

  defp ensure_sessions(connection, credentials, devices) do
    missing =
      Enum.reject(devices, fn device ->
        Map.has_key?(credentials.sessions, session_address(credentials, device.jid))
      end)

    if missing == [] do
      {:ok, credentials}
    else
      wire_jids = Enum.map(missing, &wire_jid(credentials, &1.jid))

      with {:ok, reply} <- ConnectionProcess.query(connection, USync.bundle_query(wire_jids)),
           {:ok, bundles} <- USync.parse_bundles(reply) do
        Enum.reduce_while(missing, {:ok, credentials}, fn device, {:ok, credentials} ->
          wire = wire_jid(credentials, device.jid)

          with {:ok, bundle} <- Map.fetch(bundles, wire),
               address = session_address(credentials, device.jid),
               {:ok, record} <-
                 SessionBuilder.init_outgoing(
                   credentials.sessions[address],
                   bundle,
                   credentials.signed_identity_key
                 ) do
            {:cont, {:ok, put_in(credentials.sessions[address], record)}}
          else
            :error -> {:halt, {:error, {:missing_pre_key_bundle, wire}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp encrypt_devices(credentials, devices, %{recipient: recipient, text: text}) do
    message = text_message(text)
    plaintext = encode_message(message)

    own_plaintext =
      encode_message(%Message{
        deviceSentMessage: %Message.DeviceSentMessage{
          destinationJid: recipient,
          message: message
        }
      })

    {:ok, me} = JID.decode(credentials.me.id)

    Enum.reduce_while(devices, {:ok, [], credentials}, fn device,
                                                          {:ok, participants, credentials} ->
      address = session_address(credentials, device.jid)
      record = Map.fetch!(credentials.sessions, address)
      bytes = if device.user == me.user, do: own_plaintext, else: plaintext

      {:ok, type, ciphertext, record} =
        SessionCipher.encrypt(
          record,
          bytes,
          credentials.signed_identity_key,
          credentials.registration_id
        )

      credentials = put_in(credentials.sessions[address], record)
      {:cont, {:ok, [{device.jid, type, ciphertext} | participants], credentials}}
    end)
    |> case do
      {:ok, participants, credentials} -> {:ok, Enum.reverse(participants), credentials}
      error -> error
    end
  end

  @doc false
  def relay_stanza(id, recipient, participants, account) do
    participant_nodes =
      Enum.map(participants, fn {jid, type, ciphertext} ->
        %Node{
          tag: "to",
          attrs: %{"jid" => jid},
          content: [
            %Node{
              tag: "enc",
              attrs: %{"v" => "2", "type" => Atom.to_string(type)},
              content: ciphertext
            }
          ]
        }
      end)

    content = [%Node{tag: "participants", content: participant_nodes}]

    content =
      if account && Enum.any?(participants, &(elem(&1, 1) == :pkmsg)) do
        content ++ [%Node{tag: "device-identity", content: Protobuf.encode(account)}]
      else
        content
      end

    %Node{
      tag: "message",
      attrs: %{
        "id" => id,
        "to" => recipient,
        "type" => "text"
      },
      content: content
    }
  end

  defp encode_message(message) do
    encoded = Protobuf.encode(message)
    <<random>> = :crypto.strong_rand_bytes(1)
    padding = Bitwise.band(random, 15) + 1
    encoded <> :binary.copy(<<padding>>, padding)
  end

  defp retry_session(nil, nil, _registration_id, _credentials), do: {:error, :missing_session}

  defp retry_session(record, nil, registration_id, _credentials) do
    case SessionRecord.get_open_session(record) do
      nil ->
        {:error, :missing_session}

      session ->
        if is_integer(registration_id) and session.registration_id != registration_id do
          {:error, :registration_mismatch}
        else
          {:ok, record}
        end
    end
  end

  defp retry_session(record, bundle, _registration_id, credentials) when is_map(bundle) do
    SessionBuilder.init_outgoing(record, bundle, credentials.signed_identity_key)
  end

  defp retry_plaintext(message, recipient, requester, credentials) do
    if own_jid?(requester, credentials.me) do
      encode_message(%Message{
        deviceSentMessage: %Message.DeviceSentMessage{
          destinationJid: recipient,
          message: message
        }
      })
    else
      encode_message(message)
    end
  end

  defp route_retry(stanza, recipient, wire_requester, requester, credentials) do
    attrs =
      if own_jid?(requester, credentials.me) do
        Map.merge(stanza.attrs, %{"to" => wire_requester, "recipient" => recipient})
      else
        Map.put(stanza.attrs, "to", wire_requester)
      end

    %{stanza | attrs: attrs}
  end

  defp put_retry_count(stanza, count) do
    content =
      Enum.map(stanza.content, fn
        %Node{tag: "participants", content: participants} = node ->
          participants =
            Enum.map(participants, fn
              %Node{tag: "to", content: [%Node{tag: "enc"} = encrypted]} = participant ->
                encrypted = put_in(encrypted.attrs["count"], Integer.to_string(count))
                %{participant | content: [encrypted]}

              participant ->
                participant
            end)

          %{node | content: participants}

        node ->
          node
      end)

    %{stanza | content: content}
  end

  defp text_message(text) do
    %Message{extendedTextMessage: %Message.ExtendedTextMessage{text: text}}
  end

  defp own_jid?(jid, me) do
    Enum.any?([me[:id], me[:lid]], fn own ->
      with {:ok, left} <- JID.decode(jid),
           {:ok, right} <- JID.decode(own) do
        left.user == right.user and left.server == right.server
      else
        _invalid -> false
      end
    end)
  end

  defp retry_requester_error(requester, recipient, credentials) do
    case JID.decode(requester) do
      {:ok, decoded} ->
        cond do
          not valid_retry_jid?(requester, decoded) -> {:error, :invalid_retry_requester}
          own_jid?(requester, credentials.me) -> {:error, :invalid_retry_requester}
          same_user?(requester, recipient) -> {:error, :invalid_retry_requester}
          true -> {:error, :retry_requester_mismatch}
        end

      _invalid ->
        {:error, :invalid_retry_requester}
    end
  end

  defp valid_retry_jid?(jid, decoded) do
    user_part = jid |> String.split("@", parts: 2) |> List.first()
    malformed_device? = String.contains?(user_part, ":") and is_nil(decoded.device)

    decoded.user != "" and decoded.server != "" and not malformed_device? and
      (is_nil(decoded.device) or decoded.device > 0)
  end

  defp same_user?(left, right) do
    with {:ok, left} <- JID.decode(left),
         {:ok, right} <- JID.decode(right) do
      left.user == right.user and left.server == right.server
    else
      _invalid -> false
    end
  end

  defp wire_jid(credentials, jid) do
    case JID.decode(jid) do
      {:ok, decoded} ->
        bare = JID.encode(decoded.user, decoded.server)

        case Map.get(credentials.lid_mappings, bare) do
          nil ->
            jid

          mapped ->
            case JID.decode(mapped) do
              {:ok, mapped} -> JID.encode(mapped.user, mapped.server, decoded.device)
              {:error, :invalid_jid} -> jid
            end
        end

      {:error, :invalid_jid} ->
        jid
    end
  end

  defp session_address(credentials, jid), do: wire_jid(credentials, jid)

  @doc false
  def attach_privacy_token(%Node{content: content} = stanza, recipient, credentials) do
    storage_jid = wire_jid(credentials, recipient)

    case credentials.privacy_tokens[storage_jid] || credentials.privacy_tokens[recipient] do
      %{token: token, timestamp: timestamp}
      when is_binary(token) and byte_size(token) > 0 and is_integer(timestamp) ->
        if privacy_token_expired?(timestamp) do
          stanza
        else
          token = %Node{
            tag: "tctoken",
            attrs: %{"t" => Integer.to_string(timestamp)},
            content: token
          }

          %{stanza | content: List.wrap(content) ++ [token]}
        end

      _missing ->
        stanza
    end
  end

  defp privacy_token_expired?(timestamp) do
    bucket_duration = 604_800
    current_bucket = div(System.system_time(:second), bucket_duration)
    timestamp < (current_bucket - 3) * bucket_duration
  end

  defp message_id, do: "3EB0" <> (:crypto.strong_rand_bytes(9) |> Base.encode16(case: :upper))
end
