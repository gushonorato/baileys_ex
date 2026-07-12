defmodule BaileysExo.Messages.Sender do
  @moduledoc false

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias Baileys.SentMessage
  alias BaileysExo.{ConnectionProcess, Crypto, JID}
  alias BaileysExo.Protocol.USync
  alias BaileysExo.Proto.Message
  alias BaileysExo.Signal.{SessionBuilder, SessionCipher}

  def send_text(connection, %Credentials{me: me} = credentials, recipient, text)
      when is_map(me) and is_binary(text) and byte_size(text) > 0 do
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
         {:ok, participants, credentials} <-
           encrypt_devices(credentials, devices, recipient, text),
         id = message_id(),
         :ok <- ConnectionProcess.commit_credentials(connection, credentials),
         :ok <-
           ConnectionProcess.relay(
             connection,
             relay_stanza(id, recipient, participants, credentials.account)
           ) do
      {:ok, %SentMessage{id: id, to: recipient, accepted_at: DateTime.utc_now()}, credentials}
    else
      false -> {:error, :not_on_whatsapp}
      {:error, _reason} = error -> error
    end
  end

  def send_text(_connection, _credentials, _recipient, _text), do: {:error, :invalid_text}

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

  defp encrypt_devices(credentials, devices, recipient, text) do
    message = %Message{extendedTextMessage: %Message.ExtendedTextMessage{text: text}}
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

    jids = Enum.map(participants, &elem(&1, 0))

    %Node{
      tag: "message",
      attrs: %{
        "id" => id,
        "to" => recipient,
        "type" => "text",
        "phash" => participant_hash(jids)
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

  defp wire_jid(credentials, jid) do
    {:ok, decoded} = JID.decode(jid)
    bare = JID.encode(decoded.user, decoded.server)

    case Map.get(credentials.lid_mappings, bare) do
      nil ->
        jid

      mapped ->
        {:ok, mapped} = JID.decode(mapped)
        JID.encode(mapped.user, mapped.server, decoded.device)
    end
  end

  defp session_address(credentials, jid), do: wire_jid(credentials, jid)

  defp participant_hash(jids) do
    digest = jids |> Enum.sort() |> Enum.join() |> Crypto.sha256() |> Base.encode64()
    "2:" <> binary_part(digest, 0, 6)
  end

  defp message_id, do: "3EB0" <> (:crypto.strong_rand_bytes(9) |> Base.encode16(case: :upper))
end
