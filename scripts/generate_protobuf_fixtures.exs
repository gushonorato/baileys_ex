alias Baileys.Proto.{ContextInfo, Message, MessageKey}

key = %MessageKey{
  remoteJid: "fixture-user-1@s.whatsapp.net",
  fromMe: false,
  id: "fixture-message-1",
  participant: "fixture-user-2@s.whatsapp.net"
}

text = %Message{conversation: "fixture conversation"}

extended = %Message{
  extendedTextMessage: %Message.ExtendedTextMessage{
    text: "fixture extended text",
    matchedText: "https://example.invalid",
    title: "Fixture link",
    description: "Sanitized preview",
    jpegThumbnail: <<1, 2, 3>>,
    contextInfo: %ContextInfo{
      stanzaId: "quoted-message-1",
      participant: "fixture-user-2@s.whatsapp.net",
      remoteJid: "fixture-user-1@s.whatsapp.net",
      mentionedJid: ["fixture-user-3@s.whatsapp.net"],
      quotedMessage: text
    }
  }
}

media = %Message{
  imageMessage: %Message.ImageMessage{mimetype: "image/jpeg", caption: "image", width: 640},
  videoMessage: %Message.VideoMessage{mimetype: "video/mp4", caption: "video", seconds: 2},
  audioMessage: %Message.AudioMessage{mimetype: "audio/ogg", seconds: 3, ptt: true},
  documentMessage: %Message.DocumentMessage{
    mimetype: "application/pdf",
    fileName: "fixture.pdf",
    caption: "document"
  },
  stickerMessage: %Message.StickerMessage{mimetype: "image/webp", width: 512, height: 512},
  contactMessage: %Message.ContactMessage{
    displayName: "Fixture Contact",
    vcard: "BEGIN:VCARD\nFN:Fixture Contact\nEND:VCARD"
  },
  locationMessage: %Message.LocationMessage{
    degreesLatitude: 1.25,
    degreesLongitude: -2.5,
    name: "Fixture Place"
  },
  liveLocationMessage: %Message.LiveLocationMessage{
    degreesLatitude: 3.5,
    degreesLongitude: -4.75,
    sequenceNumber: 1
  }
}

reaction_poll = %Message{
  reactionMessage: %Message.ReactionMessage{
    key: key,
    text: "+1",
    senderTimestampMs: 1_700_000_000_000
  },
  pollCreationMessage: %Message.PollCreationMessage{
    name: "Fixture poll",
    options: [
      %Message.PollCreationMessage.Option{optionName: "One"},
      %Message.PollCreationMessage.Option{optionName: "Two"}
    ],
    selectableOptionsCount: 1
  },
  pollUpdateMessage: %Message.PollUpdateMessage{
    pollCreationMessageKey: key,
    vote: %Message.PollEncValue{encPayload: <<4, 5>>, encIv: <<6, 7>>},
    senderTimestampMs: 1_700_000_000_001
  }
}

protocol_revoke = %Message{
  protocolMessage: %Message.ProtocolMessage{key: key, type: :REVOKE}
}

protocol_edit = %Message{
  protocolMessage: %Message.ProtocolMessage{
    key: key,
    type: :MESSAGE_EDIT,
    editedMessage: %Message{conversation: "edited fixture"},
    timestampMs: 1_700_000_000_002
  }
}

history = %Message{
  protocolMessage: %Message.ProtocolMessage{
    type: :HISTORY_SYNC_NOTIFICATION,
    historySyncNotification: %Message.HistorySyncNotification{
      fileSha256: <<8, 9>>,
      fileLength: 2,
      directPath: "/fixture/history",
      chunkOrder: 1,
      progress: 100,
      peerDataRequestSessionId: "fixture-session"
    }
  }
}

wrappers = %Message{
  ephemeralMessage: %Message.FutureProofMessage{message: text},
  viewOnceMessage: %Message.FutureProofMessage{message: media},
  documentWithCaptionMessage: %Message.FutureProofMessage{
    message: %Message{documentMessage: media.documentMessage}
  },
  editedMessage: %Message.FutureProofMessage{message: protocol_edit}
}

device_sent = %Message{
  deviceSentMessage: %Message.DeviceSentMessage{
    destinationJid: "fixture-user-1@s.whatsapp.net",
    message: extended,
    phash: "fixture-hash"
  }
}

fixtures = %{
  "plain_conversation.bin" => text,
  "extended_context.bin" => extended,
  "media.bin" => media,
  "reaction_poll.bin" => reaction_poll,
  "protocol_revoke.bin" => protocol_revoke,
  "protocol_edit.bin" => protocol_edit,
  "history_sync.bin" => history,
  "wrappers.bin" => wrappers,
  "device_sent.bin" => device_sent
}

target = Path.expand("../test/fixtures/protobuf", __DIR__)
File.mkdir_p!(target)

Enum.each(fixtures, fn {name, message} ->
  File.write!(Path.join(target, name), Protobuf.encode(message))
end)
