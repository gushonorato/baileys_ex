defmodule Baileys.Protocol.Payload do
  @moduledoc false

  alias Baileys.Auth.Credentials
  alias Baileys.JID
  alias Baileys.Proto.{ClientPayload, DeviceProps}

  @version [2, 3000, 1_043_857_760]

  def registration(%Credentials{} = credentials, options \\ []) do
    device_props = %DeviceProps{
      os: Keyword.get(options, :os, "Mac OS"),
      platformType: :CHROME,
      requireFullSync: false,
      version: %DeviceProps.AppVersion{primary: 10, secondary: 15, tertiary: 7},
      historySyncConfig: %DeviceProps.HistorySyncConfig{
        storageQuotaMb: 10_240,
        inlineInitialPayloadInE2EeMsg: true,
        supportCallLogHistory: false,
        supportBotUserAgentChatHistory: true,
        supportCagReactionsAndPolls: true,
        supportBizHostedMsg: true,
        supportRecentSyncChunkMessageCountTuning: true,
        supportHostedGroupMsg: true,
        supportFbidBotChatHistory: true,
        supportMessageAssociation: true,
        supportGroupHistory: false
      }
    }

    signed_pre_key = credentials.signed_pre_key

    base_payload(options)
    |> Map.merge(%{
      passive: false,
      pull: false,
      devicePairingData: %ClientPayload.DevicePairingRegistrationData{
        buildHash: :crypto.hash(:md5, Enum.join(@version, ".")),
        deviceProps: Protobuf.encode(device_props),
        eRegid: encode_big_endian(credentials.registration_id, 4),
        eKeytype: <<5>>,
        eIdent: credentials.signed_identity_key.public,
        eSkeyId: encode_big_endian(signed_pre_key.key_id, 3),
        eSkeyVal: signed_pre_key.key_pair.public,
        eSkeySig: signed_pre_key.signature
      }
    })
    |> then(&struct(ClientPayload, &1))
  end

  def login(%Credentials{me: %{id: jid}} = _credentials, options \\ []) do
    {:ok, decoded} = JID.decode(jid)

    base_payload(options)
    |> Map.merge(%{
      passive: true,
      pull: true,
      username: String.to_integer(decoded.user),
      device: decoded.device || 0,
      lidDbMigrated: false
    })
    |> then(&struct(ClientPayload, &1))
  end

  def version, do: @version

  defp base_payload(options) do
    %{
      connectType: :WIFI_UNKNOWN,
      connectReason: :USER_ACTIVATED,
      pushName: Keyword.get(options, :push_name),
      userAgent: %ClientPayload.UserAgent{
        appVersion: %ClientPayload.UserAgent.AppVersion{
          primary: Enum.at(@version, 0),
          secondary: Enum.at(@version, 1),
          tertiary: Enum.at(@version, 2)
        },
        platform: :WEB,
        releaseChannel: :RELEASE,
        osVersion: "0.1",
        device: "Desktop",
        osBuildNumber: "0.1",
        localeLanguageIso6391: "en",
        localeCountryIso31661Alpha2: Keyword.get(options, :country_code, "US"),
        mnc: "000",
        mcc: "000"
      },
      webInfo: %ClientPayload.WebInfo{webSubPlatform: :WEB_BROWSER}
    }
  end

  defp encode_big_endian(value, bytes), do: <<value::unsigned-big-integer-size(bytes)-unit(8)>>
end
