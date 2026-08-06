defmodule Baileys.Protocol.PayloadTest do
  use ExUnit.Case, async: true

  alias Baileys.Auth.Credentials
  alias Baileys.Protocol.Payload
  alias Baileys.Proto.{ClientPayload, DeviceProps}
  alias Baileys.Proto.ClientPayload.UserAgent.AppVersion

  @version [2, 3000, 1_043_857_760]

  test "uses the current WhatsApp Web version throughout registration" do
    payload = Payload.registration(Credentials.new())

    assert Payload.version() == @version

    assert payload.userAgent.appVersion == %AppVersion{
             primary: 2,
             secondary: 3000,
             tertiary: 1_043_857_760
           }

    assert payload.devicePairingData.buildHash ==
             :crypto.hash(:md5, Enum.join(@version, "."))
  end

  test "uses the current WhatsApp Web version for login" do
    credentials = %{Credentials.new() | me: %{id: "5511000000000:2@s.whatsapp.net"}}
    payload = Payload.login(credentials)

    assert payload.userAgent.appVersion == %AppVersion{
             primary: 2,
             secondary: 3000,
             tertiary: 1_043_857_760
           }
  end

  test "uses the web browser profile by default" do
    payload = Payload.registration(Credentials.new())
    device_props = DeviceProps.decode(payload.devicePairingData.deviceProps)

    assert payload.webInfo == %ClientPayload.WebInfo{webSubPlatform: :WEB_BROWSER}
    assert device_props.os == "Mac OS"
    assert device_props.platformType == :CHROME
    assert device_props.requireFullSync == false
  end

  test "advertises Windows hybrid and requests full history for the desktop profile" do
    options = [browser: :windows_desktop, sync_full_history: true]
    registration = Payload.registration(Credentials.new(), options)
    device_props = DeviceProps.decode(registration.devicePairingData.deviceProps)

    assert registration.webInfo == %ClientPayload.WebInfo{webSubPlatform: :WIN_HYBRID}
    assert device_props.os == "Windows"
    assert device_props.platformType == :DESKTOP
    assert device_props.requireFullSync == true

    credentials = %{Credentials.new() | me: %{id: "5511000000000:2@s.whatsapp.net"}}
    login = Payload.login(credentials, options)
    assert login.webInfo == %ClientPayload.WebInfo{webSubPlatform: :WIN_HYBRID}
  end

  test "does not request full history for the Windows desktop profile alone" do
    registration = Payload.registration(Credentials.new(), browser: :windows_desktop)
    device_props = DeviceProps.decode(registration.devicePairingData.deviceProps)

    assert registration.webInfo == %ClientPayload.WebInfo{webSubPlatform: :WEB_BROWSER}
    assert device_props.platformType == :DESKTOP
    assert device_props.requireFullSync == false
  end
end
