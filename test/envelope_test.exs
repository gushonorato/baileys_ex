defmodule BaileysExo.Messages.EnvelopeTest do
  use ExUnit.Case, async: true

  alias BaileysExo.Auth.Credentials
  alias BaileysExo.Binary.Node
  alias BaileysExo.Client
  alias BaileysExo.Messages.Receiver
  alias BaileysExo.Proto.{Message, VerifiedNameCertificate}

  setup do
    credentials = %Credentials{
      me: %{
        id: "local-user:2@s.whatsapp.net",
        lid: "local-lid:2@lid"
      }
    }

    %{credentials: credentials}
  end

  test "preserves PN direct-message key and LID routing", %{credentials: credentials} do
    node =
      message_node(%{
        "from" => "remote-user@s.whatsapp.net",
        "sender_lid" => "remote-lid@lid",
        "notify" => "Remote User",
        "category" => "peer",
        "t" => "1700000000"
      })

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.key.remote_jid == "remote-user@s.whatsapp.net"
    assert context.key.remote_jid_alt == "remote-lid@lid"
    assert context.key.addressing_mode == :pn
    assert context.key.participant == nil
    assert context.chat_jid == "remote-user@s.whatsapp.net"
    assert context.sender_jid == "remote-user@s.whatsapp.net"
    assert context.signal_jid == "remote-lid@lid"
    assert context.category == "peer"
    assert context.push_name == "Remote User"
    assert context.timestamp == ~U[2023-11-14 22:13:20Z]
    assert context.receipt_attrs["type"] == "peer_msg"
  end

  test "keeps a LID remote key while exposing its PN for display", %{credentials: credentials} do
    node =
      message_node(%{
        "from" => "remote-lid@lid",
        "sender_pn" => "remote-user@s.whatsapp.net",
        "addressing_mode" => "lid"
      })

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.key.remote_jid == "remote-lid@lid"
    assert context.key.remote_jid_alt == "remote-user@s.whatsapp.net"
    assert context.key.addressing_mode == :lid
    assert context.chat_jid == "remote-user@s.whatsapp.net"
    assert context.signal_jid == "remote-lid@lid"
    assert context.receipt_attrs["to"] == "remote-lid@lid"
  end

  test "uses the wire recipient as the key for a linked-device message", %{
    credentials: credentials
  } do
    node =
      message_node(%{
        "from" => "local-user:7@s.whatsapp.net",
        "recipient" => "remote-user@s.whatsapp.net",
        "recipient_lid" => "remote-lid@lid"
      })

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.key.remote_jid == "remote-user@s.whatsapp.net"
    assert context.key.from_me
    assert context.chat_jid == "remote-user@s.whatsapp.net"
    assert context.receipt_attrs["recipient"] == "remote-user@s.whatsapp.net"
    assert context.receipt_attrs["type"] == "sender"
  end

  test "routes own peer receipts to the peer chat", %{credentials: credentials} do
    node =
      message_node(%{
        "from" => "local-user:7@s.whatsapp.net",
        "recipient" => "remote-user@s.whatsapp.net",
        "category" => "peer"
      })

    assert {:ok, context} = Receiver.context(node, credentials)

    assert context.receipt_attrs == %{
             "id" => "fixture-message-1",
             "to" => "remote-user@s.whatsapp.net",
             "type" => "peer_msg"
           }
  end

  test "preserves group participant PN and LID alternatives", %{credentials: credentials} do
    node =
      message_node(%{
        "from" => "fixture-group@g.us",
        "participant" => "remote-lid:3@lid",
        "participant_pn" => "remote-user:3@s.whatsapp.net",
        "participant_username" => "fixture-user",
        "addressing_mode" => "lid"
      })

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.key.remote_jid == "fixture-group@g.us"
    assert context.key.remote_jid_alt == nil
    assert context.key.participant == "remote-lid:3@lid"
    assert context.key.participant_alt == "remote-user:3@s.whatsapp.net"
    assert context.key.participant_username == "fixture-user"
    assert context.sender_jid == "remote-user:3@s.whatsapp.net"
    assert context.signal_jid == "remote-lid:3@lid"
    assert context.protocol_response.tag == "receipt"

    assert context.protocol_response.attrs == %{
             "id" => "fixture-message-1",
             "participant" => "remote-lid:3@lid",
             "to" => "fixture-group@g.us"
           }

    refute context.key.from_me
  end

  test "recognizes own group participants and broadcast metadata", %{credentials: credentials} do
    group =
      message_node(%{
        "from" => "fixture-group@g.us",
        "participant" => "local-lid:8@lid",
        "participant_pn" => "local-user:8@s.whatsapp.net",
        "addressing_mode" => "lid"
      })

    assert {:ok, group_context} = Receiver.context(group, credentials)
    assert group_context.key.from_me

    assert group_context.receipt_attrs == %{
             "id" => "fixture-message-1",
             "participant" => "local-lid:8@lid",
             "to" => "fixture-group@g.us",
             "type" => "sender"
           }

    broadcast =
      message_node(%{
        "from" => "status@broadcast",
        "participant" => "remote-user@s.whatsapp.net"
      })

    assert {:ok, broadcast_context} = Receiver.context(broadcast, credentials)
    assert broadcast_context.broadcast
    assert broadcast_context.key.remote_jid == "status@broadcast"
    assert broadcast_context.key.participant == "remote-user@s.whatsapp.net"
  end

  test "preserves newsletter server ids as strings", %{credentials: credentials} do
    newsletter =
      message_node(%{
        "from" => "fixture-channel@newsletter",
        "server_id" => "18446744073709551615"
      })

    assert {:ok, context} = Receiver.context(newsletter, credentials)
    assert context.key.remote_jid == "fixture-channel@newsletter"
    assert context.key.server_id == "18446744073709551615"
    assert context.protocol_response.tag == "ack"
    assert context.receipt_attrs == nil
  end

  test "uses persisted PN to LID mappings for Signal without changing the key", %{
    credentials: credentials
  } do
    credentials = %{
      credentials
      | lid_mappings: %{"remote-user@s.whatsapp.net" => "remote-lid@lid"}
    }

    node = message_node(%{"from" => "remote-user:3@s.whatsapp.net"})
    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.key.remote_jid == "remote-user:3@s.whatsapp.net"
    assert context.key.remote_jid_alt == nil
    assert context.signal_jid == "remote-lid:3@lid"
  end

  test "recognizes hosted own devices by account user", %{credentials: credentials} do
    node =
      message_node(%{
        "from" => "local-user:7@hosted",
        "recipient" => "remote-user@s.whatsapp.net"
      })

    assert {:ok, context} = Receiver.context(node, credentials)
    assert context.key.from_me
    assert context.key.remote_jid == "remote-user@s.whatsapp.net"
  end

  test "allows Meta AI recipient routing without rewriting the chat", %{credentials: credentials} do
    node =
      message_node(%{
        "from" => "remote-user@s.whatsapp.net",
        "recipient" => "fixture-assistant@bot"
      })

    assert {:ok, context} = Receiver.context(node, credentials)
    refute context.key.from_me
    assert context.key.remote_jid == "remote-user@s.whatsapp.net"
  end

  test "rejects malformed group and unknown message sources", %{credentials: credentials} do
    assert {:error, :missing_group_participant} =
             Receiver.context(message_node(%{"from" => "fixture-group@g.us"}), credentials)

    assert {:error, :unsupported_message_source} =
             Receiver.context(message_node(%{"from" => "fixture@unknown"}), credentials)
  end

  test "preserves stanza metadata and uses an injected timestamp fallback", %{
    credentials: credentials
  } do
    details = Protobuf.encode(%VerifiedNameCertificate.Details{verifiedName: "Fixture Business"})
    certificate = Protobuf.encode(%VerifiedNameCertificate{details: details})

    node =
      message_node(%{
        "from" => "remote-user@s.whatsapp.net",
        "recipient_username" => "fixture-username",
        "offline" => "1",
        "t" => "invalid"
      })

    node = %{
      node
      | content: [
          %Node{tag: "verified_name", content: certificate},
          %Node{tag: "unavailable", attrs: %{"type" => "view_once"}},
          %Node{tag: "enc", attrs: %{"count" => "3"}}
        ]
    }

    fallback = fn -> ~U[2000-01-01 00:00:00Z] end
    assert {:ok, context} = Receiver.context(node, credentials, fallback)
    assert context.key.remote_jid_username == "fixture-username"
    assert context.key.view_once?
    assert context.verified_business_name == "Fixture Business"
    assert context.retry_count == 3
    assert context.offline
    assert context.timestamp == fallback.()
  end

  test "rejects missing message ids and source jids", %{credentials: credentials} do
    assert {:error, :invalid_message_stanza} =
             Receiver.context(
               %Node{tag: "message", attrs: %{"from" => "remote@s.whatsapp.net"}},
               credentials
             )

    assert {:error, :invalid_message_stanza} =
             Receiver.context(%Node{tag: "message", attrs: %{"id" => "fixture"}}, credentials)

    assert {:error, :invalid_addressing_mode} =
             Receiver.context(
               message_node(%{
                 "from" => "remote-user@s.whatsapp.net",
                 "addressing_mode" => "future-mode"
               }),
               credentials
             )
  end

  test "builds a public complete envelope without flattening wrappers", %{
    credentials: credentials
  } do
    node =
      message_node(%{
        "from" => "remote-user@s.whatsapp.net",
        "offline" => "1",
        "t" => "1700000000"
      })

    content = %Message{
      ephemeralMessage: %Message.FutureProofMessage{
        message: %Message{conversation: "wrapped fixture"}
      }
    }

    raw = Protobuf.encode(content)
    assert {:ok, context} = Receiver.context(node, credentials)
    envelope = Receiver.envelope(context, content, raw)
    public = Client.public_message(envelope)

    assert %Baileys.Message{
             key: %Baileys.MessageKey{
               remote_jid: "remote-user@s.whatsapp.net",
               id: "fixture-message-1"
             },
             content: ^content,
             raw_content: ^raw,
             timestamp: ~U[2023-11-14 22:13:20Z],
             offline?: true
           } = public
  end

  defp message_node(attrs) do
    %Node{
      tag: "message",
      attrs: Map.merge(%{"id" => "fixture-message-1", "t" => "1"}, attrs)
    }
  end
end
