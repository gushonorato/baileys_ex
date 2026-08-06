defmodule Baileys.ProtobufTest do
  use ExUnit.Case, async: true

  alias Baileys.Proto.{HandshakeMessage, Message}

  @fixture_dir Path.expand("fixtures/protobuf", __DIR__)

  test "round trips the handshake protobuf from the full schema" do
    message = %HandshakeMessage{
      clientHello: %HandshakeMessage.ClientHello{ephemeral: :binary.copy(<<1>>, 32)}
    }

    encoded = Protobuf.encode(message)
    assert HandshakeMessage.decode(encoded) == message
  end

  test "decodes conversation and extended text context fixtures" do
    assert %Message{conversation: "fixture conversation"} = fixture("plain_conversation.bin")

    assert %Message{
             extendedTextMessage: %Message.ExtendedTextMessage{
               text: "fixture extended text",
               matchedText: "https://example.invalid",
               title: "Fixture link",
               contextInfo: context
             }
           } = fixture("extended_context.bin")

    assert context.stanzaId == "quoted-message-1"
    assert context.mentionedJid == ["fixture-user-3@s.whatsapp.net"]
    assert context.quotedMessage.conversation == "fixture conversation"
  end

  test "decodes all direct media and location fixture fields" do
    message = fixture("media.bin")

    assert message.imageMessage.caption == "image"
    assert message.videoMessage.mimetype == "video/mp4"
    assert message.audioMessage.ptt
    assert message.documentMessage.fileName == "fixture.pdf"
    assert message.stickerMessage.width == 512
    assert message.contactMessage.displayName == "Fixture Contact"
    assert message.locationMessage.degreesLatitude == 1.25
    assert message.liveLocationMessage.sequenceNumber == 1
  end

  test "decodes reaction, poll, protocol and history fixtures" do
    reaction_poll = fixture("reaction_poll.bin")
    assert reaction_poll.reactionMessage.key.id == "fixture-message-1"
    assert reaction_poll.pollCreationMessage.name == "Fixture poll"
    assert length(reaction_poll.pollCreationMessage.options) == 2
    assert reaction_poll.pollUpdateMessage.vote.encPayload == <<4, 5>>

    revoke = fixture("protocol_revoke.bin").protocolMessage
    assert revoke.type == :REVOKE
    assert revoke.key.id == "fixture-message-1"

    edit = fixture("protocol_edit.bin").protocolMessage
    assert edit.type == :MESSAGE_EDIT
    assert edit.editedMessage.conversation == "edited fixture"

    history = fixture("history_sync.bin").protocolMessage
    assert history.type == :HISTORY_SYNC_NOTIFICATION
    assert history.historySyncNotification.progress == 100
    assert history.historySyncNotification.peerDataRequestSessionId == "fixture-session"
  end

  test "decodes wrappers and linked-device content without flattening them" do
    wrappers = fixture("wrappers.bin")
    assert wrappers.ephemeralMessage.message.conversation == "fixture conversation"
    assert wrappers.viewOnceMessage.message.imageMessage.caption == "image"
    assert wrappers.documentWithCaptionMessage.message.documentMessage.caption == "document"
    assert wrappers.editedMessage.message.protocolMessage.type == :MESSAGE_EDIT

    device_sent = fixture("device_sent.bin").deviceSentMessage
    assert device_sent.destinationJid == "fixture-user-1@s.whatsapp.net"
    assert device_sent.message.extendedTextMessage.text == "fixture extended text"
  end

  test "re-encodes every sanitized full-schema fixture without field loss" do
    for path <- Path.wildcard(Path.join(@fixture_dir, "*.bin")) do
      encoded = File.read!(path)
      assert encoded |> Message.decode() |> Protobuf.encode() == encoded
    end
  end

  defp fixture(name) do
    @fixture_dir
    |> Path.join(name)
    |> File.read!()
    |> Message.decode()
  end
end
