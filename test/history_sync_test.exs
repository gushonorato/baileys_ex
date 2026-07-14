defmodule BaileysExo.HistorySyncTest do
  use ExUnit.Case, async: true

  alias Baileys.{HistoryConversation, HistoryPastParticipants, LIDMapping, MessagingHistorySet}
  alias BaileysExo.Crypto
  alias BaileysExo.Client

  alias BaileysExo.Proto.{
    Conversation,
    HistorySync,
    HistorySyncMsg,
    Message,
    MessageKey,
    PastParticipant,
    PastParticipants,
    PhoneNumberToLIDMapping,
    Pushname,
    WebMessageInfo
  }

  @media_key :binary.copy(<<7>>, 32)

  test "detects wrapped notifications and projects inline history without reordering it" do
    first = web_message("first", "111@lid", 10, :READ, "one")

    second =
      web_message("second", "222@s.whatsapp.net", 20, :DELIVERY_ACK, "two", %{
        participant: "333@lid",
        messageStubType: :GROUP_CREATE,
        messageStubParameters: ["Synthetic Group"]
      })

    status = web_message("status", "status@broadcast", 30, :SERVER_ACK, "status")

    history = %HistorySync{
      syncType: :FULL,
      chunkOrder: 2,
      progress: 80,
      conversations: [
        %Conversation{
          id: "111@lid",
          displayName: "First Contact",
          pnJid: "111@s.whatsapp.net",
          messages: [%HistorySyncMsg{message: first, msgOrderId: 5}]
        },
        %Conversation{
          id: "group@g.us",
          name: "Synthetic Group",
          messages: [%HistorySyncMsg{message: second, msgOrderId: 4}]
        }
      ],
      statusV3Messages: [status],
      phoneNumberToLidMappings: [
        %PhoneNumberToLIDMapping{pnJid: "444@s.whatsapp.net", lidJid: "444@lid"}
      ],
      pastParticipants: [
        %PastParticipants{
          groupJid: "group@g.us",
          pastParticipants: [
            %PastParticipant{userJid: "left@s.whatsapp.net", leaveReason: :REMOVED, leaveTs: 9}
          ]
        }
      ]
    }

    notification = notification(history)

    message = %Message{
      ephemeralMessage: %Message.FutureProofMessage{
        message: %Message{
          protocolMessage: %Message.ProtocolMessage{
            type: :HISTORY_SYNC_NOTIFICATION,
            historySyncNotification: notification
          }
        }
      }
    }

    assert {:ok, ^notification} = BaileysExo.HistorySync.detect(message)

    assert %BaileysExo.Binary.Node{
             tag: "receipt",
             attrs: %{
               "id" => "history-notification",
               "to" => "local:2@s.whatsapp.net",
               "type" => "hist_sync"
             }
           } =
             BaileysExo.HistorySync.receipt(%{
               content: message,
               key: %{from_me: true, id: "history-notification"},
               wire_sender_jid: "local:2@s.whatsapp.net"
             })

    assert {:ok, %MessagingHistorySet{} = result} = BaileysExo.HistorySync.process(message)

    assert Enum.map(result.conversations, & &1.id) == ["111@lid", "group@g.us"]

    assert [%HistoryConversation{messages: [projected_first]}, %{messages: [projected_second]}] =
             result.conversations

    assert Enum.map(result.contacts, &{&1.id, &1.name}) == [
             {"111@lid", "First Contact"},
             {"group@g.us", "Synthetic Group"}
           ]

    assert Enum.map(result.messages, & &1.key.id) == ["first", "second"]
    assert projected_first == hd(result.messages)
    assert projected_second == List.last(result.messages)
    assert projected_first.web_message_info == first
    assert projected_first.content.conversation == "one"
    assert projected_first.raw_content == Protobuf.encode(first.message)
    assert projected_first.timestamp == DateTime.from_unix!(10)
    assert projected_first.status == :read
    assert projected_first.key.remote_jid_alt == "111@s.whatsapp.net"
    assert projected_first.key.addressing_mode == :lid
    assert projected_second.stub_type == :group_create
    assert projected_second.stub_parameters == ["Synthetic Group"]
    assert projected_second.key.participant_alt == nil

    assert [status_message] = result.status_v3_messages
    assert status_message.key.id == "status"
    assert status_message.web_message_info == status

    assert result.lid_pn_mappings == [
             %LIDMapping{lid: "444@lid", pn: "444@s.whatsapp.net"},
             %LIDMapping{lid: "111@lid", pn: "111@s.whatsapp.net"}
           ]

    assert [
             %HistoryPastParticipants{
               group_jid: "group@g.us",
               participants: [participant]
             }
           ] = result.past_participants

    assert participant.user_jid == "left@s.whatsapp.net"
    assert participant.leave_reason == :removed
    assert participant.leave_timestamp == 9

    assert result.sync_type == :full
    assert result.chunk_order == 7
    assert result.progress == 100
    assert result.latest?
    assert result.request_id == "request-1"
    assert result.peer_data_request_session_id == "session-1"
    assert result.original_message_id == "original-1"
    assert result.oldest_message_in_chunk_timestamp == 8
    assert result.enc_handle == "enc-1"
    assert result.complete_access_granted?
  end

  test "projects push-name contacts in wire order" do
    history = %HistorySync{
      syncType: :PUSH_NAME,
      pushnames: [
        %Pushname{id: "first@s.whatsapp.net", pushname: "First"},
        %Pushname{id: "second@s.whatsapp.net", pushname: "Second"}
      ]
    }

    assert {:ok, result} = history |> notification() |> BaileysExo.HistorySync.process()

    assert Enum.map(result.contacts, &{&1.id, &1.notify}) == [
             {"first@s.whatsapp.net", "First"},
             {"second@s.whatsapp.net", "Second"}
           ]
  end

  test "authenticates, decrypts and processes downloaded history bytes" do
    history = %HistorySync{
      syncType: :RECENT,
      conversations: [
        %Conversation{
          id: "remote@s.whatsapp.net",
          messages: [%HistorySyncMsg{message: web_message("remote", "remote@s.whatsapp.net", 40)}]
        }
      ]
    }

    compressed = history |> Protobuf.encode() |> :zlib.compress()
    {blob, notification} = encrypted_blob(compressed)

    assert {:ok, ^compressed} = BaileysExo.HistorySync.decrypt_remote_blob(blob, notification)
    assert {:ok, result} = BaileysExo.HistorySync.process(notification, blob)
    assert Enum.map(result.messages, & &1.key.id) == ["remote"]
  end

  test "rejects remote history corruption at every integrity boundary" do
    compressed = %HistorySync{syncType: :RECENT} |> Protobuf.encode() |> :zlib.compress()
    {blob, notification} = encrypted_blob(compressed)
    <<first, rest::binary>> = blob
    tampered = <<Bitwise.bxor(first, 1), rest::binary>>

    assert {:error, :encrypted_sha256_mismatch} =
             BaileysExo.HistorySync.decrypt_remote_blob(tampered, notification)

    hmac_notification = %{notification | fileEncSha256: Crypto.sha256(tampered)}

    assert {:error, :hmac_mismatch} =
             BaileysExo.HistorySync.decrypt_remote_blob(tampered, hmac_notification)

    assert {:error, :length_mismatch} =
             BaileysExo.HistorySync.decrypt_remote_blob(blob, %{notification | fileLength: 1})

    assert {:error, :plaintext_sha256_mismatch} =
             BaileysExo.HistorySync.decrypt_remote_blob(blob, %{
               notification
               | fileSha256: :binary.copy(<<0>>, 32)
             })

    <<ciphertext::binary-size(byte_size(blob) - 10), _mac::binary-size(10)>> = blob
    size = byte_size(ciphertext)
    <<prefix::binary-size(size - 1), last>> = ciphertext
    invalid_ciphertext = prefix <> <<Bitwise.bxor(last, 1)>>
    invalid_mac = remote_mac(invalid_ciphertext)
    invalid_blob = invalid_ciphertext <> invalid_mac

    invalid_padding_notification = %{
      notification
      | fileEncSha256: Crypto.sha256(invalid_blob)
    }

    assert {:error, :invalid_padding} =
             BaileysExo.HistorySync.decrypt_remote_blob(
               invalid_blob,
               invalid_padding_notification
             )
  end

  test "returns bounded errors for non-history messages and malformed inline payloads" do
    assert :ignore = BaileysExo.HistorySync.detect(%Message{conversation: "ordinary"})
    assert {:error, :not_history_sync} = BaileysExo.HistorySync.process(%Message{})

    assert {:error, :invalid_compressed_history} =
             BaileysExo.HistorySync.process(%Message.HistorySyncNotification{
               initialHistBootstrapInlinePayload: "not-zlib"
             })
  end

  test "client processes inline history FIFO and persists before publishing" do
    history = %HistorySync{
      syncType: :FULL,
      conversations: [
        %Conversation{
          id: "111@lid",
          pnJid: "111@s.whatsapp.net",
          messages: [%HistorySyncMsg{message: web_message("history-1", "111@lid", 10)}]
        }
      ]
    }

    history_notification = %{notification(history) | syncType: :INITIAL_BOOTSTRAP}

    content = %Message{
      protocolMessage: %Message.ProtocolMessage{
        type: :HISTORY_SYNC_NOTIFICATION,
        historySyncNotification: history_notification
      }
    }

    envelope = %{
      key: %{
        remote_jid: "local@s.whatsapp.net",
        remote_jid_alt: nil,
        remote_jid_username: nil,
        from_me: true,
        id: "history-notification-1",
        participant: nil,
        participant_alt: nil,
        participant_username: nil,
        addressing_mode: :pn,
        server_id: nil,
        view_once?: false
      },
      content: content,
      raw_content: Protobuf.encode(content),
      timestamp: ~U[2023-11-14 22:13:20Z],
      status: :server_ack,
      category: nil,
      push_name: nil,
      verified_business_name: nil,
      broadcast: false,
      offline: true,
      retry_count: nil
    }

    test = self()
    connection = spawn(fn -> commit_loop(test) end)

    state = %{
      subscribers: %{self() => make_ref()},
      connection: connection,
      options: [],
      history_queue: :queue.new(),
      history_worker: nil,
      history_pause_timer: nil
    }

    assert {:noreply, state} =
             Client.handle_info(
               {:connection_event, {:messages_upsert, [envelope], :append, nil}},
               state
             )

    assert_receive {:baileys, _client, {:messages_upsert, _outer}}
    assert_receive {:history_result, reference, {:ok, result}}

    assert {:noreply, _state} =
             Client.handle_info({:history_result, reference, {:ok, result}}, state)

    assert_receive {:history_commit, mappings, progress}
    assert mappings == [%{lid: "111@lid", pn: "111@s.whatsapp.net"}]
    assert progress.request_id == "request-1"

    assert_receive {:baileys, _client,
                    {:messaging_history_set, %MessagingHistorySet{messages: [message]}}}

    assert_receive {:baileys, _client,
                    {:messaging_history_status,
                     %Baileys.MessagingHistoryStatus{
                       sync_type: :initial_bootstrap,
                       status: :complete,
                       explicit?: true
                     }}}

    assert message.key.id == "history-1"

    refute_receive {:baileys, _client,
                    {:messages_upsert, %{messages: [%{key: %{id: "history-1"}}]}}}
  end

  test "history inactivity emits pause without marking completion" do
    state = %{subscribers: %{self() => make_ref()}, history_pause_timer: make_ref()}

    assert {:noreply, updated} = Client.handle_info({:history_pause, :recent}, state)
    assert updated.history_pause_timer == nil

    assert_receive {:baileys, _client,
                    {:messaging_history_status,
                     %Baileys.MessagingHistoryStatus{
                       sync_type: :recent,
                       status: :paused,
                       explicit?: false
                     }}}
  end

  defp web_message(id, jid, timestamp, status \\ :SERVER_ACK, text \\ "message", extra \\ %{}) do
    struct!(
      WebMessageInfo,
      Map.merge(
        %{
          key: %MessageKey{remoteJid: jid, fromMe: false, id: id},
          message: %Message{conversation: text},
          messageTimestamp: timestamp,
          status: status
        },
        extra
      )
    )
  end

  defp notification(history) do
    %Message.HistorySyncNotification{
      syncType: :FULL,
      chunkOrder: 7,
      progress: 100,
      originalMessageId: "original-1",
      oldestMsgInChunkTimestampSec: 8,
      peerDataRequestSessionId: "session-1",
      fullHistorySyncOnDemandRequestMetadata: %Message.FullHistorySyncOnDemandRequestMetadata{
        requestId: "request-1"
      },
      encHandle: "enc-1",
      messageAccessStatus: %Message.HistorySyncMessageAccessStatus{completeAccessGranted: true},
      initialHistBootstrapInlinePayload: history |> Protobuf.encode() |> :zlib.compress()
    }
  end

  defp encrypted_blob(plaintext) do
    <<iv::binary-size(16), cipher_key::binary-size(32), _mac_key::binary-size(32), _::binary>> =
      Crypto.hkdf(@media_key, 112, info: "WhatsApp History Keys")

    ciphertext = Crypto.aes_cbc_encrypt(plaintext, cipher_key, iv)
    blob = ciphertext <> remote_mac(ciphertext)

    notification = %Message.HistorySyncNotification{
      mediaKey: @media_key,
      fileLength: byte_size(plaintext),
      fileSha256: Crypto.sha256(plaintext),
      fileEncSha256: Crypto.sha256(blob),
      syncType: :RECENT,
      chunkOrder: 1,
      progress: 50,
      peerDataRequestSessionId: "remote-session"
    }

    {blob, notification}
  end

  defp remote_mac(ciphertext) do
    <<iv::binary-size(16), _cipher_key::binary-size(32), mac_key::binary-size(32), _::binary>> =
      Crypto.hkdf(@media_key, 112, info: "WhatsApp History Keys")

    mac_key
    |> Crypto.hmac_sha256(iv <> ciphertext)
    |> binary_part(0, 10)
  end

  defp commit_loop(test) do
    receive do
      {:"$gen_call", from, {:commit_history, mappings, progress}} ->
        send(test, {:history_commit, mappings, progress})
        GenServer.reply(from, :ok)
        commit_loop(test)
    end
  end
end
