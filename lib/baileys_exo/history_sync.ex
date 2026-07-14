defmodule BaileysExo.HistorySync do
  @moduledoc """
  Pure decoding and projection for WhatsApp history-sync notifications.

  Callers remain responsible for downloading remote blobs and for deciding how
  to publish or persist the returned `%Baileys.MessagingHistorySet{}`.
  """

  import Bitwise

  alias Baileys.{
    HistoryContact,
    HistoryConversation,
    HistoryPastParticipant,
    HistoryPastParticipants,
    LIDMapping,
    Message,
    MessageKey,
    MessagingHistorySet
  }

  alias BaileysExo.Crypto
  alias BaileysExo.Binary.Node

  alias BaileysExo.Proto.{
    Conversation,
    PastParticipants,
    WebMessageInfo
  }

  alias BaileysExo.Proto.HistorySync, as: ProtoHistorySync
  alias BaileysExo.Proto.Message, as: ProtoMessage
  alias BaileysExo.Proto.Message.HistorySyncNotification

  @history_hkdf_info "WhatsApp History Keys"
  @history_hkdf_length 112
  @mac_length 10
  @aes_block_size 16
  @max_history_bytes 128 * 1024 * 1024

  @doc "Returns the history notification contained in a message, including future-proof wrappers."
  @spec detect(ProtoMessage.t()) :: {:ok, HistorySyncNotification.t()} | :ignore
  def detect(%ProtoMessage{} = message), do: detect(message, 0)
  def detect(_message), do: :ignore

  @doc false
  def receipt(%{content: content, key: %{from_me: true, id: id}, wire_sender_jid: to}) do
    case detect(content) do
      {:ok, _notification} ->
        %Node{tag: "receipt", attrs: %{"id" => id, "to" => to, "type" => "hist_sync"}}

      :ignore ->
        nil
    end
  end

  def receipt(_envelope), do: nil

  @doc "Decodes and projects a history message or notification."
  @spec process(
          ProtoMessage.t() | HistorySyncNotification.t() | ProtoHistorySync.t(),
          binary() | nil
        ) ::
          {:ok, MessagingHistorySet.t()} | {:error, atom()}
  def process(value, downloaded_bytes \\ nil)

  def process(%ProtoMessage{} = message, downloaded_bytes) do
    case detect(message) do
      {:ok, notification} -> process(notification, downloaded_bytes)
      :ignore -> {:error, :not_history_sync}
    end
  end

  def process(%HistorySyncNotification{} = notification, downloaded_bytes) do
    with {:ok, history} <- decode_notification(notification, downloaded_bytes) do
      {:ok, project(history, notification)}
    end
  end

  def process(%ProtoHistorySync{} = history, _downloaded_bytes), do: {:ok, project(history)}
  def process(_value, _downloaded_bytes), do: {:error, :not_history_sync}

  @doc "Inflates and decodes an inline history payload or notification."
  @spec decode_inline(HistorySyncNotification.t() | binary()) ::
          {:ok, ProtoHistorySync.t()} | {:error, atom()}
  def decode_inline(%HistorySyncNotification{initialHistBootstrapInlinePayload: payload})
      when is_binary(payload) and byte_size(payload) > 0,
      do: decode_compressed(payload)

  def decode_inline(%HistorySyncNotification{}), do: {:error, :missing_inline_payload}
  def decode_inline(payload) when is_binary(payload), do: decode_compressed(payload)
  def decode_inline(_payload), do: {:error, :missing_inline_payload}

  @doc """
  Authenticates and decrypts already-downloaded history bytes.

  The downloaded value must be `AES-256-CBC ciphertext <> 10-byte MAC`. The
  encrypted SHA-256, truncated HMAC, PKCS#7 padding, declared plaintext length,
  and plaintext SHA-256 are validated before plaintext is returned.
  """
  @spec decrypt_remote_blob(binary(), HistorySyncNotification.t()) ::
          {:ok, binary()} | {:error, atom()}
  def decrypt_remote_blob(downloaded_bytes, %HistorySyncNotification{} = notification)
      when is_binary(downloaded_bytes) do
    with :ok <- validate_remote_metadata(notification),
         :ok <-
           validate_hash(downloaded_bytes, notification.fileEncSha256, :encrypted_sha256_mismatch),
         {:ok, ciphertext, received_mac} <- split_remote_blob(downloaded_bytes),
         {iv, cipher_key, mac_key} <- media_keys(notification.mediaKey),
         expected_mac <-
           Crypto.hmac_sha256(mac_key, iv <> ciphertext) |> binary_part(0, @mac_length),
         :ok <- validate_mac(received_mac, expected_mac),
         {:ok, plaintext} <- Crypto.aes_cbc_decrypt(ciphertext, cipher_key, iv),
         :ok <- validate_length(plaintext, notification.fileLength),
         :ok <- validate_hash(plaintext, notification.fileSha256, :plaintext_sha256_mismatch) do
      {:ok, plaintext}
    end
  end

  def decrypt_remote_blob(_downloaded_bytes, %HistorySyncNotification{}),
    do: {:error, :invalid_remote_blob}

  def decrypt_remote_blob(_downloaded_bytes, _notification),
    do: {:error, :invalid_history_notification}

  @doc "Projects decoded protobuf history while preserving all list order."
  @spec project(ProtoHistorySync.t(), HistorySyncNotification.t() | nil) ::
          MessagingHistorySet.t()
  def project(%ProtoHistorySync{} = history, notification \\ nil) do
    mappings = history_mappings(history)
    mapping_index = mapping_index(mappings)

    conversations =
      Enum.map(history.conversations, &project_conversation(&1, mapping_index))

    messages = Enum.flat_map(conversations, & &1.messages)

    status_v3_messages =
      Enum.map(history.statusV3Messages, &project_message(&1, nil, mapping_index))

    %MessagingHistorySet{
      conversations: conversations,
      contacts: history_contacts(history),
      messages: messages,
      status_v3_messages: status_v3_messages,
      lid_pn_mappings: mappings,
      past_participants: Enum.map(history.pastParticipants, &project_past_participants/1),
      sync_type: enum_value(metadata(notification, :syncType) || history.syncType),
      progress: metadata(notification, :progress) || history.progress,
      chunk_order: metadata(notification, :chunkOrder) || history.chunkOrder,
      latest?: (metadata(notification, :progress) || history.progress) == 100,
      request_id: request_id(notification),
      peer_data_request_session_id: metadata(notification, :peerDataRequestSessionId),
      original_message_id: metadata(notification, :originalMessageId),
      oldest_message_in_chunk_timestamp: metadata(notification, :oldestMsgInChunkTimestampSec),
      enc_handle: metadata(notification, :encHandle),
      complete_access_granted?: complete_access_granted(notification)
    }
  end

  defp detect(%ProtoMessage{protocolMessage: protocol}, _depth)
       when not is_nil(protocol) do
    case protocol do
      %ProtoMessage.ProtocolMessage{
        type: :HISTORY_SYNC_NOTIFICATION,
        historySyncNotification: %HistorySyncNotification{} = notification
      } ->
        {:ok, notification}

      _other ->
        :ignore
    end
  end

  defp detect(%ProtoMessage{} = message, depth) when depth < 8 do
    message
    |> wrapped_message()
    |> case do
      %ProtoMessage{} = inner -> detect(inner, depth + 1)
      _missing -> :ignore
    end
  end

  defp detect(_message, _depth), do: :ignore

  defp wrapped_message(message) do
    Enum.find_value(
      [
        message.ephemeralMessage,
        message.viewOnceMessage,
        message.documentWithCaptionMessage,
        message.viewOnceMessageV2,
        message.viewOnceMessageV2Extension,
        message.editedMessage,
        message.associatedChildMessage,
        message.groupStatusMessage,
        message.groupStatusMessageV2
      ],
      &(&1 && &1.message)
    )
  end

  defp decode_notification(
         %HistorySyncNotification{initialHistBootstrapInlinePayload: payload},
         _downloaded_bytes
       )
       when is_binary(payload) and byte_size(payload) > 0,
       do: decode_compressed(payload)

  defp decode_notification(%HistorySyncNotification{} = notification, downloaded_bytes)
       when is_binary(downloaded_bytes) do
    with {:ok, compressed} <- decrypt_remote_blob(downloaded_bytes, notification) do
      decode_compressed(compressed)
    end
  end

  defp decode_notification(%HistorySyncNotification{}, _downloaded_bytes),
    do: {:error, :remote_blob_required}

  defp decode_compressed(compressed) do
    with {:ok, protobuf} <- inflate(compressed),
         {:ok, history} <- decode_history(protobuf) do
      {:ok, history}
    end
  end

  defp inflate(compressed) do
    zlib = :zlib.open()
    :ok = :zlib.inflateInit(zlib)

    try do
      inflate_chunks(zlib, compressed, [], 0)
    after
      :zlib.inflateEnd(zlib)
      :zlib.close(zlib)
    end
  rescue
    _error -> {:error, :invalid_compressed_history}
  catch
    _kind, _reason -> {:error, :invalid_compressed_history}
  end

  defp inflate_chunks(zlib, input, chunks, size) do
    case :zlib.safeInflate(zlib, input) do
      {:finished, output} -> collect_inflated(output, chunks, size, true, zlib)
      {:continue, output} -> collect_inflated(output, chunks, size, false, zlib)
    end
  end

  defp collect_inflated(output, chunks, size, finished?, zlib) do
    output = IO.iodata_to_binary(output)
    size = size + byte_size(output)

    cond do
      size > @max_history_bytes -> {:error, :history_payload_too_large}
      finished? -> {:ok, chunks |> Enum.reverse([output]) |> IO.iodata_to_binary()}
      true -> inflate_chunks(zlib, <<>>, [output | chunks], size)
    end
  end

  defp decode_history(protobuf) do
    {:ok, ProtoHistorySync.decode(protobuf)}
  rescue
    _error -> {:error, :invalid_history_payload}
  catch
    _kind, _reason -> {:error, :invalid_history_payload}
  end

  defp validate_remote_metadata(notification) do
    cond do
      not (is_binary(notification.mediaKey) and byte_size(notification.mediaKey) > 0) ->
        {:error, :missing_media_key}

      not valid_digest?(notification.fileEncSha256) ->
        {:error, :missing_encrypted_sha256}

      not valid_digest?(notification.fileSha256) ->
        {:error, :missing_plaintext_sha256}

      not (is_integer(notification.fileLength) and notification.fileLength >= 0) ->
        {:error, :missing_file_length}

      true ->
        :ok
    end
  end

  defp valid_digest?(digest), do: is_binary(digest) and byte_size(digest) == 32

  defp validate_hash(value, expected, error) do
    if secure_equal?(Crypto.sha256(value), expected), do: :ok, else: {:error, error}
  end

  defp split_remote_blob(bytes) when byte_size(bytes) >= @aes_block_size + @mac_length do
    ciphertext_length = byte_size(bytes) - @mac_length

    if rem(ciphertext_length, @aes_block_size) == 0 do
      <<ciphertext::binary-size(ciphertext_length), mac::binary-size(@mac_length)>> = bytes
      {:ok, ciphertext, mac}
    else
      {:error, :invalid_remote_blob}
    end
  end

  defp split_remote_blob(_bytes), do: {:error, :invalid_remote_blob}

  defp media_keys(media_key) do
    <<iv::binary-size(16), cipher_key::binary-size(32), mac_key::binary-size(32), _::binary>> =
      Crypto.hkdf(media_key, @history_hkdf_length, info: @history_hkdf_info)

    {iv, cipher_key, mac_key}
  end

  defp validate_mac(received, expected) do
    if secure_equal?(received, expected), do: :ok, else: {:error, :hmac_mismatch}
  end

  defp validate_length(plaintext, expected) do
    if byte_size(plaintext) == expected, do: :ok, else: {:error, :length_mismatch}
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    left
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(right))
    |> Enum.reduce(0, fn {left_byte, right_byte}, difference ->
      bor(difference, bxor(left_byte, right_byte))
    end) == 0
  end

  defp secure_equal?(_left, _right), do: false

  defp history_mappings(history) do
    explicit =
      Enum.flat_map(history.phoneNumberToLidMappings, fn mapping ->
        mapping(mapping.lidJid, mapping.pnJid)
      end)

    derived = Enum.flat_map(history.conversations, &conversation_mapping/1)

    {mappings, _seen} =
      Enum.reduce(explicit ++ derived, {[], MapSet.new()}, fn mapping, {mappings, seen} ->
        key = {mapping.lid, mapping.pn}

        if MapSet.member?(seen, key) do
          {mappings, seen}
        else
          {[mapping | mappings], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(mappings)
  end

  defp conversation_mapping(%Conversation{} = conversation) do
    cond do
      lid_jid?(conversation.id) and pn_jid?(conversation.pnJid) ->
        mapping(conversation.id, conversation.pnJid)

      pn_jid?(conversation.id) and lid_jid?(conversation.lidJid) ->
        mapping(conversation.lidJid, conversation.id)

      lid_jid?(conversation.id) ->
        mapping(conversation.id, phone_number_from_receipts(conversation.messages))

      true ->
        []
    end
  end

  defp phone_number_from_receipts(messages) do
    Enum.find_value(messages, fn
      %{message: %WebMessageInfo{key: %{fromMe: true}, userReceipt: receipts}} ->
        Enum.find_value(receipts, fn receipt ->
          if pn_jid?(receipt.userJid), do: receipt.userJid
        end)

      _message ->
        nil
    end)
  end

  defp mapping(lid, pn) do
    if lid_jid?(lid) and pn_jid?(pn), do: [%LIDMapping{lid: lid, pn: pn}], else: []
  end

  defp mapping_index(mappings) do
    Enum.reduce(mappings, %{}, fn mapping, index ->
      index
      |> Map.put(mapping.lid, mapping.pn)
      |> Map.put(mapping.pn, mapping.lid)
    end)
  end

  defp project_conversation(%Conversation{} = conversation, mapping_index) do
    messages =
      Enum.flat_map(conversation.messages, fn
        %{message: %WebMessageInfo{} = message} ->
          [project_message(message, conversation.id, mapping_index)]

        _missing_message ->
          []
      end)

    %HistoryConversation{
      id: conversation.id,
      name: conversation.name,
      display_name: conversation.displayName,
      username: conversation.username,
      lid: conversation.lidJid || conversation.accountLid,
      phone_number: conversation.pnJid,
      new_jid: conversation.newJid,
      old_jid: conversation.oldJid,
      last_message_timestamp: conversation.lastMsgTimestamp,
      conversation_timestamp: conversation.conversationTimestamp,
      unread_count: conversation.unreadCount,
      read_only?: conversation.readOnly,
      archived?: conversation.archived,
      marked_as_unread?: conversation.markedAsUnread,
      pinned: conversation.pinned,
      mute_end_time: conversation.muteEndTime,
      end_of_history_transfer?: conversation.endOfHistoryTransfer,
      end_of_history_transfer_type: enum_value(conversation.endOfHistoryTransferType),
      ephemeral_expiration: conversation.ephemeralExpiration,
      ephemeral_setting_timestamp: conversation.ephemeralSettingTimestamp,
      messages: messages,
      web_conversation: conversation
    }
  end

  defp project_message(%WebMessageInfo{} = web_message, fallback_jid, mapping_index) do
    proto_key = web_message.key || %BaileysExo.Proto.MessageKey{}
    remote_jid = proto_key.remoteJid || fallback_jid || ""
    participant = proto_key.participant || web_message.participant
    grouped? = grouped_jid?(remote_jid)
    addressing_jid = participant || remote_jid

    key = %MessageKey{
      remote_jid: remote_jid,
      remote_jid_alt: if(grouped?, do: nil, else: mapping_index[remote_jid]),
      remote_jid_username: nil,
      from_me: proto_key.fromMe == true,
      id: proto_key.id || "",
      participant: participant,
      participant_alt: if(grouped? and participant, do: mapping_index[participant]),
      participant_username: nil,
      addressing_mode: if(lid_jid?(addressing_jid), do: :lid, else: :pn),
      server_id: server_id(web_message.newsletterServerId),
      view_once?: view_once?(web_message.message)
    }

    %Message{
      key: key,
      content: web_message.message,
      raw_content: encode_content(web_message.message),
      timestamp: timestamp(web_message.messageTimestamp),
      status: enum_value(web_message.status),
      category: nil,
      push_name: web_message.pushName,
      verified_business_name: web_message.verifiedBizName,
      stub_type: enum_value(web_message.messageStubType),
      stub_parameters: web_message.messageStubParameters,
      web_message_info: web_message,
      retry_count: nil,
      broadcast?: web_message.broadcast == true or String.ends_with?(remote_jid, "@broadcast"),
      offline?: false
    }
  end

  defp encode_content(nil), do: nil
  defp encode_content(content), do: Protobuf.encode(content)

  defp timestamp(nil), do: nil

  defp timestamp(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value) do
      {:ok, timestamp} -> timestamp
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp server_id(nil), do: nil
  defp server_id(value) when is_integer(value), do: Integer.to_string(value)
  defp server_id(value), do: to_string(value)

  defp view_once?(%ProtoMessage{} = message) do
    not is_nil(message.viewOnceMessage) or
      not is_nil(message.viewOnceMessageV2) or
      not is_nil(message.viewOnceMessageV2Extension)
  end

  defp view_once?(_message), do: false

  defp history_contacts(history) do
    conversation_contacts =
      Enum.flat_map(history.conversations, fn conversation ->
        base = %HistoryContact{
          id: conversation.id,
          name: conversation.displayName || conversation.name || conversation.username,
          username: conversation.username,
          lid: conversation.lidJid || conversation.accountLid,
          phone_number: conversation.pnJid
        }

        [base | verified_contacts(conversation.messages)]
      end)

    pushname_contacts =
      Enum.flat_map(history.pushnames, fn pushname ->
        if present?(pushname.id) do
          [%HistoryContact{id: pushname.id, notify: pushname.pushname}]
        else
          []
        end
      end)

    conversation_contacts ++ pushname_contacts
  end

  defp verified_contacts(messages) do
    Enum.flat_map(messages, fn
      %{
        message: %WebMessageInfo{
          key: key,
          participant: participant,
          messageStubType: stub,
          messageStubParameters: [verified_name | _rest]
        }
      }
      when stub in [:BIZ_PRIVACY_MODE_TO_BSP, :BIZ_PRIVACY_MODE_TO_FB] and
             is_binary(verified_name) ->
        id = (key && (key.participant || key.remoteJid)) || participant
        if present?(id), do: [%HistoryContact{id: id, verified_name: verified_name}], else: []

      _message ->
        []
    end)
  end

  defp project_past_participants(%PastParticipants{} = group) do
    %HistoryPastParticipants{
      group_jid: group.groupJid,
      participants:
        Enum.map(group.pastParticipants, fn participant ->
          %HistoryPastParticipant{
            user_jid: participant.userJid,
            leave_reason: enum_value(participant.leaveReason),
            leave_timestamp: participant.leaveTs
          }
        end)
    }
  end

  defp metadata(%HistorySyncNotification{} = notification, key), do: Map.get(notification, key)
  defp metadata(_notification, _key), do: nil

  defp request_id(%HistorySyncNotification{
         fullHistorySyncOnDemandRequestMetadata: metadata
       })
       when not is_nil(metadata),
       do: metadata.requestId

  defp request_id(_notification), do: nil

  defp complete_access_granted(%HistorySyncNotification{messageAccessStatus: status})
       when not is_nil(status),
       do: status.completeAccessGranted

  defp complete_access_granted(_notification), do: nil

  defp enum_value(nil), do: nil

  defp enum_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.downcase()
    |> String.to_atom()
  end

  defp enum_value(value), do: value

  defp grouped_jid?(jid),
    do: String.ends_with?(jid, "@g.us") or String.ends_with?(jid, "@broadcast")

  defp lid_jid?(jid) when is_binary(jid),
    do: String.ends_with?(jid, "@lid") or String.ends_with?(jid, "@hosted.lid")

  defp lid_jid?(_jid), do: false

  defp pn_jid?(jid) when is_binary(jid),
    do: String.ends_with?(jid, "@s.whatsapp.net") or String.ends_with?(jid, "@hosted")

  defp pn_jid?(_jid), do: false

  defp present?(value), do: is_binary(value) and value != ""
end
