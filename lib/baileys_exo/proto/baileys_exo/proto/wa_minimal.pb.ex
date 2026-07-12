defmodule BaileysExo.Proto.ADVEncryptionType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ADVEncryptionType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:E2EE, 0)
  field(:HOSTED, 1)
end

defmodule BaileysExo.Proto.DeviceProps.PlatformType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.DeviceProps.PlatformType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:UNKNOWN, 0)
  field(:CHROME, 1)
  field(:DESKTOP, 7)
  field(:CATALINA, 12)
  field(:ANDROID_PHONE, 16)
end

defmodule BaileysExo.Proto.ClientPayload.ConnectReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.ConnectReason",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:PUSH, 0)
  field(:USER_ACTIVATED, 1)
  field(:SCHEDULED, 2)
  field(:ERROR_RECONNECT, 3)
  field(:NETWORK_SWITCH, 4)
  field(:PING_RECONNECT, 5)
  field(:UNKNOWN, 6)
end

defmodule BaileysExo.Proto.ClientPayload.ConnectType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.ConnectType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:CELLULAR_UNKNOWN, 0)
  field(:WIFI_UNKNOWN, 1)
end

defmodule BaileysExo.Proto.ClientPayload.Product do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.Product",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:WHATSAPP, 0)
  field(:MESSENGER, 1)
  field(:INTEROP, 2)
  field(:INTEROP_MSGR, 3)
  field(:WHATSAPP_LID, 4)
end

defmodule BaileysExo.Proto.ClientPayload.UserAgent.DeviceType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.UserAgent.DeviceType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:PHONE, 0)
  field(:TABLET, 1)
  field(:DESKTOP, 2)
end

defmodule BaileysExo.Proto.ClientPayload.UserAgent.Platform do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.UserAgent.Platform",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:ANDROID, 0)
  field(:WEB, 14)
  field(:MACOS, 24)
end

defmodule BaileysExo.Proto.ClientPayload.UserAgent.ReleaseChannel do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.UserAgent.ReleaseChannel",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:RELEASE, 0)
  field(:BETA, 1)
  field(:ALPHA, 2)
  field(:DEBUG, 3)
end

defmodule BaileysExo.Proto.ClientPayload.WebInfo.WebSubPlatform do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "baileys_exo.proto.ClientPayload.WebInfo.WebSubPlatform",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:WEB_BROWSER, 0)
  field(:APP_STORE, 1)
  field(:WIN_STORE, 2)
  field(:DARWIN, 3)
  field(:WIN32, 4)
  field(:WIN_HYBRID, 5)
end

defmodule BaileysExo.Proto.ADVDeviceIdentity do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ADVDeviceIdentity",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:rawId, 1, proto3_optional: true, type: :uint32)
  field(:timestamp, 2, proto3_optional: true, type: :uint64)
  field(:keyIndex, 3, proto3_optional: true, type: :uint32)

  field(:accountType, 4,
    proto3_optional: true,
    type: BaileysExo.Proto.ADVEncryptionType,
    enum: true
  )

  field(:deviceType, 5,
    proto3_optional: true,
    type: BaileysExo.Proto.ADVEncryptionType,
    enum: true
  )
end

defmodule BaileysExo.Proto.ADVSignedDeviceIdentity do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ADVSignedDeviceIdentity",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:details, 1, proto3_optional: true, type: :bytes)
  field(:accountSignatureKey, 2, proto3_optional: true, type: :bytes)
  field(:accountSignature, 3, proto3_optional: true, type: :bytes)
  field(:deviceSignature, 4, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.ADVSignedDeviceIdentityHMAC do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ADVSignedDeviceIdentityHMAC",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:details, 1, proto3_optional: true, type: :bytes)
  field(:hmac, 2, proto3_optional: true, type: :bytes)

  field(:accountType, 3,
    proto3_optional: true,
    type: BaileysExo.Proto.ADVEncryptionType,
    enum: true
  )
end

defmodule BaileysExo.Proto.CertChain.NoiseCertificate.Details do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.CertChain.NoiseCertificate.Details",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:serial, 1, proto3_optional: true, type: :uint32)
  field(:issuerSerial, 2, proto3_optional: true, type: :uint32)
  field(:key, 3, proto3_optional: true, type: :bytes)
  field(:notBefore, 4, proto3_optional: true, type: :uint64)
  field(:notAfter, 5, proto3_optional: true, type: :uint64)
end

defmodule BaileysExo.Proto.CertChain.NoiseCertificate do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.CertChain.NoiseCertificate",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:details, 1, proto3_optional: true, type: :bytes)
  field(:signature, 2, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.CertChain do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.CertChain",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:leaf, 1, proto3_optional: true, type: BaileysExo.Proto.CertChain.NoiseCertificate)

  field(:intermediate, 2,
    proto3_optional: true,
    type: BaileysExo.Proto.CertChain.NoiseCertificate
  )
end

defmodule BaileysExo.Proto.HandshakeMessage.ClientHello do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.HandshakeMessage.ClientHello",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:ephemeral, 1, proto3_optional: true, type: :bytes)
  field(:static, 2, proto3_optional: true, type: :bytes)
  field(:payload, 3, proto3_optional: true, type: :bytes)
  field(:useExtended, 4, proto3_optional: true, type: :bool)
  field(:extendedCiphertext, 5, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.HandshakeMessage.ServerHello do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.HandshakeMessage.ServerHello",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:ephemeral, 1, proto3_optional: true, type: :bytes)
  field(:static, 2, proto3_optional: true, type: :bytes)
  field(:payload, 3, proto3_optional: true, type: :bytes)
  field(:extendedStatic, 4, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.HandshakeMessage.ClientFinish do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.HandshakeMessage.ClientFinish",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:static, 1, proto3_optional: true, type: :bytes)
  field(:payload, 2, proto3_optional: true, type: :bytes)
  field(:extendedCiphertext, 3, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.HandshakeMessage do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.HandshakeMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:clientHello, 2,
    proto3_optional: true,
    type: BaileysExo.Proto.HandshakeMessage.ClientHello
  )

  field(:serverHello, 3,
    proto3_optional: true,
    type: BaileysExo.Proto.HandshakeMessage.ServerHello
  )

  field(:clientFinish, 4,
    proto3_optional: true,
    type: BaileysExo.Proto.HandshakeMessage.ClientFinish
  )
end

defmodule BaileysExo.Proto.DeviceProps.AppVersion do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.DeviceProps.AppVersion",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:primary, 1, proto3_optional: true, type: :uint32)
  field(:secondary, 2, proto3_optional: true, type: :uint32)
  field(:tertiary, 3, proto3_optional: true, type: :uint32)
  field(:quaternary, 4, proto3_optional: true, type: :uint32)
  field(:quinary, 5, proto3_optional: true, type: :uint32)
end

defmodule BaileysExo.Proto.DeviceProps.HistorySyncConfig do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.DeviceProps.HistorySyncConfig",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:fullSyncDaysLimit, 1, proto3_optional: true, type: :uint32)
  field(:fullSyncSizeMbLimit, 2, proto3_optional: true, type: :uint32)
  field(:storageQuotaMb, 3, proto3_optional: true, type: :uint32)
  field(:inlineInitialPayloadInE2EeMsg, 4, proto3_optional: true, type: :bool)
  field(:recentSyncDaysLimit, 5, proto3_optional: true, type: :uint32)
  field(:supportCallLogHistory, 6, proto3_optional: true, type: :bool)
  field(:supportBotUserAgentChatHistory, 7, proto3_optional: true, type: :bool)
  field(:supportCagReactionsAndPolls, 8, proto3_optional: true, type: :bool)
  field(:supportBizHostedMsg, 9, proto3_optional: true, type: :bool)
  field(:supportRecentSyncChunkMessageCountTuning, 10, proto3_optional: true, type: :bool)
  field(:supportHostedGroupMsg, 11, proto3_optional: true, type: :bool)
  field(:supportFbidBotChatHistory, 12, proto3_optional: true, type: :bool)
  field(:supportMessageAssociation, 14, proto3_optional: true, type: :bool)
  field(:supportGroupHistory, 15, proto3_optional: true, type: :bool)
end

defmodule BaileysExo.Proto.DeviceProps do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.DeviceProps",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:os, 1, proto3_optional: true, type: :string)
  field(:version, 2, proto3_optional: true, type: BaileysExo.Proto.DeviceProps.AppVersion)

  field(:platformType, 3,
    proto3_optional: true,
    type: BaileysExo.Proto.DeviceProps.PlatformType,
    enum: true
  )

  field(:requireFullSync, 4, proto3_optional: true, type: :bool)

  field(:historySyncConfig, 5,
    proto3_optional: true,
    type: BaileysExo.Proto.DeviceProps.HistorySyncConfig
  )
end

defmodule BaileysExo.Proto.ClientPayload.DevicePairingRegistrationData do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ClientPayload.DevicePairingRegistrationData",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:eRegid, 1, proto3_optional: true, type: :bytes)
  field(:eKeytype, 2, proto3_optional: true, type: :bytes)
  field(:eIdent, 3, proto3_optional: true, type: :bytes)
  field(:eSkeyId, 4, proto3_optional: true, type: :bytes)
  field(:eSkeyVal, 5, proto3_optional: true, type: :bytes)
  field(:eSkeySig, 6, proto3_optional: true, type: :bytes)
  field(:buildHash, 7, proto3_optional: true, type: :bytes)
  field(:deviceProps, 8, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.ClientPayload.UserAgent.AppVersion do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ClientPayload.UserAgent.AppVersion",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:primary, 1, proto3_optional: true, type: :uint32)
  field(:secondary, 2, proto3_optional: true, type: :uint32)
  field(:tertiary, 3, proto3_optional: true, type: :uint32)
  field(:quaternary, 4, proto3_optional: true, type: :uint32)
  field(:quinary, 5, proto3_optional: true, type: :uint32)
end

defmodule BaileysExo.Proto.ClientPayload.UserAgent do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ClientPayload.UserAgent",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:platform, 1,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.UserAgent.Platform,
    enum: true
  )

  field(:appVersion, 2,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.UserAgent.AppVersion
  )

  field(:mcc, 3, proto3_optional: true, type: :string)
  field(:mnc, 4, proto3_optional: true, type: :string)
  field(:osVersion, 5, proto3_optional: true, type: :string)
  field(:manufacturer, 6, proto3_optional: true, type: :string)
  field(:device, 7, proto3_optional: true, type: :string)
  field(:osBuildNumber, 8, proto3_optional: true, type: :string)
  field(:phoneId, 9, proto3_optional: true, type: :string)

  field(:releaseChannel, 10,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.UserAgent.ReleaseChannel,
    enum: true
  )

  field(:localeLanguageIso6391, 11, proto3_optional: true, type: :string)
  field(:localeCountryIso31661Alpha2, 12, proto3_optional: true, type: :string)

  field(:deviceType, 15,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.UserAgent.DeviceType,
    enum: true
  )
end

defmodule BaileysExo.Proto.ClientPayload.WebInfo do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ClientPayload.WebInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:refToken, 1, proto3_optional: true, type: :string)
  field(:version, 2, proto3_optional: true, type: :string)

  field(:webSubPlatform, 4,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.WebInfo.WebSubPlatform,
    enum: true
  )
end

defmodule BaileysExo.Proto.ClientPayload do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.ClientPayload",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:username, 1, proto3_optional: true, type: :uint64)
  field(:passive, 3, proto3_optional: true, type: :bool)
  field(:userAgent, 5, proto3_optional: true, type: BaileysExo.Proto.ClientPayload.UserAgent)
  field(:webInfo, 6, proto3_optional: true, type: BaileysExo.Proto.ClientPayload.WebInfo)
  field(:pushName, 7, proto3_optional: true, type: :string)
  field(:sessionId, 9, proto3_optional: true, type: :sfixed32)
  field(:shortConnect, 10, proto3_optional: true, type: :bool)

  field(:connectType, 12,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.ConnectType,
    enum: true
  )

  field(:connectReason, 13,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.ConnectReason,
    enum: true
  )

  field(:connectAttemptCount, 16, proto3_optional: true, type: :uint32)
  field(:device, 18, proto3_optional: true, type: :uint32)

  field(:devicePairingData, 19,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.DevicePairingRegistrationData
  )

  field(:product, 20,
    proto3_optional: true,
    type: BaileysExo.Proto.ClientPayload.Product,
    enum: true
  )

  field(:pull, 33, proto3_optional: true, type: :bool)
  field(:lidDbMigrated, 41, proto3_optional: true, type: :bool)
end

defmodule BaileysExo.Proto.Message.ExtendedTextMessage do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.Message.ExtendedTextMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:text, 1, proto3_optional: true, type: :string)
end

defmodule BaileysExo.Proto.Message.DeviceSentMessage do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.Message.DeviceSentMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:destinationJid, 1, proto3_optional: true, type: :string)
  field(:message, 2, proto3_optional: true, type: BaileysExo.Proto.Message)
  field(:phash, 3, proto3_optional: true, type: :string)
end

defmodule BaileysExo.Proto.Message.FutureProofMessage do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.Message.FutureProofMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:message, 1, proto3_optional: true, type: BaileysExo.Proto.Message)
end

defmodule BaileysExo.Proto.Message do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.Message",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:conversation, 1, proto3_optional: true, type: :string)

  field(:extendedTextMessage, 6,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.ExtendedTextMessage
  )

  field(:deviceSentMessage, 31,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.DeviceSentMessage
  )

  field(:viewOnceMessage, 37,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:ephemeralMessage, 40,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:documentWithCaptionMessage, 53,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:viewOnceMessageV2, 55,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:editedMessage, 58,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:viewOnceMessageV2Extension, 59,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:associatedChildMessage, 91,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:groupStatusMessage, 96,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )

  field(:groupStatusMessageV2, 103,
    proto3_optional: true,
    type: BaileysExo.Proto.Message.FutureProofMessage
  )
end

defmodule BaileysExo.Proto.SignalMessage do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.SignalMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:ratchetKey, 1, proto3_optional: true, type: :bytes)
  field(:counter, 2, proto3_optional: true, type: :uint32)
  field(:previousCounter, 3, proto3_optional: true, type: :uint32)
  field(:ciphertext, 4, proto3_optional: true, type: :bytes)
end

defmodule BaileysExo.Proto.PreKeySignalMessage do
  @moduledoc false

  use Protobuf,
    full_name: "baileys_exo.proto.PreKeySignalMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:preKeyId, 1, proto3_optional: true, type: :uint32)
  field(:baseKey, 2, proto3_optional: true, type: :bytes)
  field(:identityKey, 3, proto3_optional: true, type: :bytes)
  field(:message, 4, proto3_optional: true, type: :bytes)
  field(:registrationId, 5, proto3_optional: true, type: :uint32)
  field(:signedPreKeyId, 6, proto3_optional: true, type: :uint32)
end
