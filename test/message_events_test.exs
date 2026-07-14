defmodule BaileysExo.MessageEventsTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Client
  alias BaileysExo.Proto.{Message, MessageKey}

  test "emits reactions with separate target and author keys" do
    target = %MessageKey{
      remoteJid: "remote-user@s.whatsapp.net",
      fromMe: true,
      id: "target-message-1"
    }

    content = %Message{
      reactionMessage: %Message.ReactionMessage{
        key: target,
        text: "+1",
        senderTimestampMs: 1_700_000_000_000
      }
    }

    state = client_state()
    envelope = envelope(content, "reaction-event-1")

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event, {:messages_upsert, [envelope], :notify, nil}},
               state
             )

    assert_receive {:baileys, _client, {:messages_upsert, %Baileys.MessagesUpsert{}}}

    assert_receive {:baileys, _client,
                    {:messages_reaction,
                     [
                       %Baileys.MessageReaction{
                         target_key: %Baileys.MessageKey{id: "target-message-1", from_me: false},
                         reaction: %Baileys.Message{
                           key: %Baileys.MessageKey{id: "reaction-event-1"}
                         }
                       }
                     ]}}
  end

  test "preserves empty reaction text as removal" do
    target = %MessageKey{remoteJid: "local-user@s.whatsapp.net", id: "target-message-1"}

    content = %Message{
      reactionMessage: %Message.ReactionMessage{key: target, text: "", senderTimestampMs: 1}
    }

    state = client_state()

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event,
                {:messages_upsert, [envelope(content, "reaction-remove-1")], :notify, nil}},
               state
             )

    assert_receive {:baileys, _client, {:messages_upsert, _upsert}}

    assert_receive {:baileys, _client,
                    {:messages_reaction,
                     [
                       %Baileys.MessageReaction{
                         target_key: %Baileys.MessageKey{
                           remote_jid: "remote-user@s.whatsapp.net",
                           from_me: true
                         },
                         reaction: reaction
                       }
                     ]}}

    assert reaction.content.reactionMessage.text == ""
  end

  test "emits revoke and edit updates while retaining protocol upserts" do
    target = %MessageKey{remoteJid: "remote-user@s.whatsapp.net", id: "target-message-1"}

    revoke = %Message{
      protocolMessage: %Message.ProtocolMessage{key: target, type: :REVOKE}
    }

    edit = %Message{
      protocolMessage: %Message.ProtocolMessage{
        key: target,
        type: :MESSAGE_EDIT,
        editedMessage: %Message{conversation: "edited fixture"},
        timestampMs: 1_700_000_000_000
      }
    }

    state = client_state()
    envelopes = [envelope(revoke, "revoke-event-1"), envelope(edit, "edit-event-1")]

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event, {:messages_upsert, envelopes, :notify, nil}},
               state
             )

    assert_receive {:baileys, _client,
                    {:messages_upsert, %Baileys.MessagesUpsert{messages: messages}}}

    assert length(messages) == 2

    assert_receive {:baileys, _client, {:messages_update, updates}}
    assert Enum.map(updates, & &1.key.id) == ["target-message-1", "target-message-1"]
    assert Enum.at(updates, 0).update.deleted?
    assert Enum.at(updates, 1).update.message.conversation == "edited fixture"
  end

  test "projects direct and per-user receipt updates into typed public events" do
    key = key("message-1")
    timestamp = ~U[2023-11-14 22:13:20Z]
    state = client_state()

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event,
                {:messages_update,
                 [%{key: key, update: %{status: :read, timestamp: timestamp, error: nil}}]}},
               state
             )

    assert_receive {:baileys, _client,
                    {:messages_update,
                     [
                       %Baileys.MessageUpdate{
                         key: %Baileys.MessageKey{id: "message-1"},
                         update: %{status: :read, timestamp: ^timestamp}
                       }
                     ]}}

    receipt = %{
      user_jid: "remote-user:3@s.whatsapp.net",
      receipt_timestamp: nil,
      read_timestamp: nil,
      played_timestamp: timestamp,
      pending_device_jids: [],
      delivered_device_jids: []
    }

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event, {:message_receipt_update, [%{key: key, receipt: receipt}]}},
               state
             )

    assert_receive {:baileys, _client,
                    {:message_receipt_update,
                     [
                       %Baileys.MessageReceiptUpdate{
                         receipt: %Baileys.UserReceipt{
                           user_jid: "remote-user:3@s.whatsapp.net",
                           played_timestamp: ^timestamp
                         }
                       }
                     ]}}
  end

  test "projects wrapped and linked-device specialized messages" do
    target = %MessageKey{remoteJid: "remote-user@s.whatsapp.net", id: "target-message-1"}

    linked_reaction = %Message{
      deviceSentMessage: %Message.DeviceSentMessage{
        destinationJid: "remote-user@s.whatsapp.net",
        message: %Message{
          reactionMessage: %Message.ReactionMessage{key: target, text: "+1"}
        }
      }
    }

    wrapped_revoke = %Message{
      ephemeralMessage: %Message.FutureProofMessage{
        message: %Message{
          protocolMessage: %Message.ProtocolMessage{key: target, type: :REVOKE}
        }
      }
    }

    state = client_state()

    envelopes = [
      envelope(linked_reaction, "reaction-event-1"),
      envelope(wrapped_revoke, "revoke-event-1")
    ]

    assert {:noreply, ^state} =
             Client.handle_info(
               {:connection_event, {:messages_upsert, envelopes, :notify, nil}},
               state
             )

    assert_receive {:baileys, _client, {:messages_upsert, _upsert}}
    assert_receive {:baileys, _client, {:messages_reaction, [%Baileys.MessageReaction{}]}}

    assert_receive {:baileys, _client,
                    {:messages_update, [%Baileys.MessageUpdate{key: %{id: "target-message-1"}}]}}
  end

  defp client_state do
    %{
      credentials: %Credentials{
        me: %{id: "local-user:2@s.whatsapp.net", lid: "local-lid:2@lid"}
      },
      subscribers: %{self() => make_ref()}
    }
  end

  defp envelope(content, id) do
    %{
      key: key(id),
      content: content,
      raw_content: Protobuf.encode(content),
      timestamp: ~U[2023-11-14 22:13:20Z],
      status: nil,
      category: nil,
      push_name: nil,
      verified_business_name: nil,
      broadcast: false,
      offline: false,
      retry_count: nil
    }
  end

  defp key(id) do
    %{
      remote_jid: "remote-user@s.whatsapp.net",
      remote_jid_alt: "remote-lid@lid",
      remote_jid_username: nil,
      from_me: false,
      id: id,
      participant: nil,
      participant_alt: nil,
      participant_username: nil,
      addressing_mode: :pn,
      server_id: nil,
      view_once?: false
    }
  end
end
